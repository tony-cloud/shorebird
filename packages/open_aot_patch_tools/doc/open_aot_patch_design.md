# Open AOT Patch Design

This package produces compact, flavor-aware AOT patch artifacts without relying
on `DART_DYNAMIC_MODULES` or the Dart bytecode interpreter.

The public-source boundary is documented in
`../../../OPEN_SOURCE_REPLACEMENTS.md`. The Shorebird runtime updater itself is
public at `shorebirdtech/updater`; the closed replacement work in this checkout
targets the hosted management/auth/console services and the independent compact
AOT patch generation flow.

## Runtime Model

Patches are AOT snapshot artifacts. The engine selects patched isolate snapshot
data and instructions before isolate startup, matching Flutter's existing
snapshot mapping flow. The VM data and VM instructions remain from the base
runtime.

This keeps the design compatible with iOS constraints:

- no JIT dependency
- no writable executable memory requirement
- no KBC interpreter dependency
- patch metadata must bind the artifact to platform, architecture, SDK hash,
  app build id, flavor/license id, base snapshot hash, patch snapshot hash, and
  obfuscation map hash when obfuscation is used

## Delivery Security

AES-256-GCM protects downloaded patch artifacts in transit and at rest. The
metadata is authenticated as AAD, and the decrypted compact payload is
hash-checked. When a base snapshot is supplied, `verify --base=<file>` also
reconstructs the patch snapshot and checks it against the metadata
`patch_snapshot_hash`.

AES is not the compatibility boundary. Apps should still pin or sign patch
metadata and enforce app id, build id, flavor id, license type, SDK hash, base
snapshot hash, target OS, and target architecture before accepting a patch.
For license upgrades, artifacts may also include `base_flavor_id` and
`base_license_type`; verifiers can require those fields to prove the patch is a
specific transition such as `free -> pro` rather than a generic pro artifact.
`verify --artifact-sha256=<hash>` adds hash pinning for the whole encrypted
delivery artifact, which should be used alongside transport security or a
separate signing layer.

Limited offline licenses should set `offline_expires_at` in the patch metadata.
That timestamp is part of the AES-GCM authenticated metadata. Devices must
refuse to install or reconstruct an expired patch, and an already-installed
patch must be removed at startup once the timestamp passes unless the server
has already supplied a newer valid patch.

The management server remains Shorebird-compatible by keeping the standard
`patch_available`, `patch`, and `rolled_back_patch_numbers` response shape.
When an installed limited-offline patch has expired and no newer valid patch is
available, the server returns `patch_available: false` and includes that patch
number in `rolled_back_patch_numbers`. The open updater can also read the
optional `remove_patch` object, which contains the same patch number,
`reason: "offline_expired"`, and `offline_expires_at`.

## Compact Payloads

By default, `link` chooses the smallest v1 payload representation:

- `empty` when base and patch snapshots are identical
- `binary-diff-v1` when changed byte ranges are smaller than the full patch
- `full-snapshot` when a diff would be larger

For runtime handoff tests and simple embedders, pass
`link --full-snapshot=true`. This forces the encrypted payload to decrypt to a
directly loadable `.vmcode` file. That file can be supplied as the first
application library path and mapped by the engine patch cache before isolate
startup.

The binary diff format is deterministic and reconstructs the full patched
snapshot from the base snapshot before runtime loading. Future SDK-integrated
linkers can replace this with changed isolate code/data sections while keeping
the same metadata and encryption envelope.

`dump-blobs --key-hex=<key> --base=<base.vmcode> --output=<patch.vmcode>` is
the open updater handoff: it decrypts the delivery artifact, reconstructs the
loadable VM-code payload, verifies the reconstructed hash against metadata, and
writes the file that the engine patch cache can map before isolate startup.

The host proof app is `testapps/license_flavor_patch_test`. Run:

```powershell
dart-sdk-new\tools\sdks\dart-sdk\bin\dart.exe testapps\license_flavor_patch_test\tool\verify_aot_patch.dart
```

It compiles a `free` base AOT snapshot and a `pro` patch snapshot, reuses the
base obfuscation map for the patch build, encrypts the patch artifact, verifies
wrong-key and wrong-flavor failures, reconstructs the patched `.vmcode`, and
runs it to confirm `license:pro` and `pro-feature:enabled`.

## iOS JIT-Disabled Handoff

iOS release/profile patch artifacts should be generated as Mach-O AOT snapshot
objects, not bytecode and not dynamic modules. Build the patch snapshot on
macOS with the iOS `gen_snapshot` that matches the app's Flutter/Dart SDK:

```sh
dart run open_aot_patch_tools compile-patch \
  --gen-snapshot=/path/to/ios/gen_snapshot_arm64 \
  --kernel=build/patch_app.dill \
  --output=build/patch.vmcode \
  --snapshot-kind=app-aot-macho-dylib \
  --macho-object=build/patch.o \
  --obfuscate=true \
  --load-obfuscation-map=build/base.obfuscation.json

dart run open_aot_patch_tools link \
  --base=build/base.vmcode \
  --patch=build/patch.vmcode \
  --output=build/patch.json \
  --app-id=com.example.licenseFlavorPatchTest \
  --app-build-id=ios-build-123 \
  --base-flavor-id=free \
  --base-license-type=free \
  --flavor-id=pro \
  --license-type=pro \
  --sdk-hash=<flutter-engine-or-dart-sdk-hash> \
  --target-os=ios \
  --target-arch=arm64 \
  --obfuscation-map-hash=<sha256-of-base-obfuscation-map> \
  --offline-expires-at=2030-01-01T00:00:00Z \
  --full-snapshot=true
```

The encrypted artifact is delivered the same way as the Windows host proof:
`encrypt` wraps it with AES-256-GCM, and the app-owned updater/key callback must
validate metadata before decrypting. After decryption, use
`dump-blobs --key-hex=<key> --base=build/base.vmcode --output=patch.vmcode` to
write the loadable patch file into the updater's next-boot patch location.

The Flutter engine patch cache is prepared for this handoff:

- `shorebird_enable_aot_patching` defaults on for iOS, while the legacy
  `SHOREBIRD_USE_INTERPRETER` path is opt-in and disabled by default.
- The first `.vmcode` application library path is treated as the patch. For iOS
  it may contain a raw Mach-O snapshot or a compact linker header followed by a
  Mach-O snapshot.
- VM snapshot symbols continue to resolve from the signed base App.framework;
  only isolate data and isolate instructions are replaced by the patch.
- The loader uses Dart's Mach-O snapshot loader on Apple platforms, so the VM
  does not need JIT, writable executable memory, KBC, or `DART_DYNAMIC_MODULES`.

The macOS device/simulator verification pass should build the same
`license_flavor_patch_test` flavor pair with `--target-os=ios` and
`--target-arch=arm64`, install the encrypted `free -> pro` patch, confirm the
status label changes to `license:pro` / `pro-feature:enabled`, and confirm
wrong-key and wrong-flavor artifacts fail before the isolate starts.

## Obfuscation

Release and patch builds should both use Dart `--obfuscate`. Patch builds should
pass the release build's obfuscation map through
`gen_snapshot --load-obfuscation-map=<file>` so existing symbols keep their
release names and new patch-only symbols receive fresh names without collisions.

## Control-Flow Obfuscation Plan

Control-flow obfuscation should be a separate compiler flag from name
obfuscation and AOT patching. The first safe milestone is an opt-in annotation
or pragma for selected functions, followed by a precompiler pass that:

- splits basic blocks at safe boundaries after AOT optimizations
- introduces opaque predicates that are stable across deterministic builds
- preserves safepoint, deoptimization, exception, and stack-map correctness
- avoids FFI callbacks, async suspension stubs, recognized intrinsics, and
  functions with patch entry points until each category has targeted tests

The pass should start disabled by default and only graduate after size,
performance, symbolication, and patch compatibility tests exist for host,
Android, and iOS AOT builds.
