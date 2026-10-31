# Open AOT Patch Design

This package produces compact, flavor-aware patch artifacts without relying on
`DART_DYNAMIC_MODULES`. Native AOT artifacts are still useful for host,
Android, macOS, Linux, Windows, and development-device iOS validation. The iOS
App Store candidate route uses the no-DDM interpreter runtime mode; App Store
acceptance remains a separate distribution gate.

The public-source boundary is documented in
`../../../OPEN_SOURCE_REPLACEMENTS.md`. The Shorebird runtime updater itself is
public at `shorebirdtech/updater`; the closed replacement work in this checkout
targets the hosted management/auth/console services and the independent compact
AOT patch generation flow.

## Runtime Model

The artifact metadata names the runtime mode required by the patch payload:

- `native-aot`: patched isolate snapshot data/instructions are selected before
  isolate startup, matching Flutter's existing snapshot mapping flow. VM data
  and VM instructions remain from the base runtime.
- `dart-bytecode-interpreter`: iOS candidate payloads are data consumed by
  already-reviewed VM interpreter code. This is not `DART_DYNAMIC_MODULES`, and
  the VM must reject dynamic-module payloads for this project.

This keeps the design compatible with iOS constraints:

- no JIT dependency
- no writable executable memory requirement for App Store payloads
- no downloaded native snapshot text in App Store payloads
- no `DART_DYNAMIC_MODULES`
- patch metadata must bind the artifact to platform, architecture, SDK hash,
  app build id, flavor/license id, base snapshot hash, patch snapshot hash, and
  obfuscation map hash when obfuscation is used

## Delivery Security

AES-256-GCM protects the encrypted delivery artifact. Its metadata is
authenticated as AAD, and the decrypted compact payload is hash-checked. Native
reconstruction writes a plaintext executable to the installed patch cache, so
this envelope does not protect that native cache at rest. The iOS interpreter
path retains the encrypted artifact and passes decrypted bytecode as data to the
VM. When a base snapshot is supplied, `verify --base=<file>` also
reconstructs the patch snapshot and checks it against the metadata
`patch_snapshot_hash`.

AES does not replace the compatibility or publisher-authentication checks.
The production iOS interpreter route requires managed artifact signing,
`patch_verification: strict` and `patch_response_verification: required`, including
authenticated patch offers and rollback responses. Unsigned, customer-signed or
`install_only` interpreter release configurations are rejected. Verifiers also
enforce app id, build id, flavor id, license type, SDK hash, base snapshot hash,
target OS and architecture.
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

For native-AOT artifacts, `link` chooses the smallest v1 payload
representation by default:

- `empty` when base and patch snapshots are identical
- `binary-diff-v1` when changed byte ranges are smaller than the full patch
- `full-snapshot` when a diff would be larger

For native-AOT runtime handoff tests and simple embedders, pass
`link --full-snapshot=true`. This forces the encrypted payload to decrypt to a
directly loadable `.vmcode` file. That file can be supplied as the first
application library path and mapped by the engine patch cache before isolate
startup on platforms where native patch execution is allowed. Do not use this
native-AOT handoff for iOS App Store delivery.

For `dart-bytecode-interpreter` artifacts, the linker always emits
`full-snapshot` payloads. The current open runtime has no compact-diff
reconstruction bridge inside the VM, so interpreter patches must decrypt to
bytecode data. The default profile replaces bodies of existing functions. An
explicit structural release profile additionally supports additive declarations
and fields within the contract below. Compact interpreter reconstruction remains
unimplemented; a patch delta produced with `--patch-base` is still packaged as a
`full-snapshot` interpreter payload rather than `binary-diff-v1`.

The binary diff format is deterministic and reconstructs the full patched
snapshot from the base snapshot before runtime loading. Future SDK-integrated
linkers can replace this with changed isolate code/data sections while keeping
the same metadata and encryption envelope.

`dump-blobs --key-hex=<key> --base=<base.vmcode> --output=<patch.vmcode>` is
the native-AOT updater handoff: it decrypts the delivery artifact, reconstructs
the loadable VM-code payload, verifies the reconstructed hash against metadata,
and writes the file that the engine patch cache can map before isolate startup.

The host proof app is `testapps/license_flavor_patch_test`. Run:

```powershell
dart-sdk\tools\sdks\dart-sdk\bin\dart.exe testapps\license_flavor_patch_test\tool\verify_aot_patch.dart
```

It compiles a `free` base AOT snapshot and a `pro` patch snapshot, reuses the
base obfuscation map for the patch build, encrypts the patch artifact, verifies
wrong-key and wrong-flavor failures, reconstructs the patched `.vmcode`, and
runs it to confirm `license:pro` and `pro-feature:enabled`.

## Structural Interpreter Profile

`aot_patch_structural_updates: true` opts the native release, full baseline
bytecode and patch compiler into the same structural profile. Flutter forwards
`--no-tfa --shorebird-structural-patching` to the AOT frontend and the structural
flag to the snapshot and bytecode compilers. Patches compile with `--patch-base`
against the private release supplement's `baseline.bytecode`. Its `baseline.json`
records the immutable capability and identity; a patch cannot enable the profile
for a body-only release. Both profiles prohibit interpreter obfuscation.

The profile supports new libraries, generic classes, functions, methods,
constructors and static fields. Existing function bodies can change while their
signatures remain fixed. Added instance fields on existing ordinary mutable
classes use GC-traced VM extension storage, preserving old object layout and
field values. Declaration initializers run lazily for existing objects; new
constructors initialize new objects normally. Added fields need a declaration
initializer, nullable default or `late`; constructor-only nonnullable
initialization cannot replay construction for existing objects.

Removed declarations, changed existing signatures/initializers/fields,
inheritance, interfaces and type parameters are rejected. Existing const, deeply
immutable and native-wrapper classes cannot gain instance fields. New
native/external functions and replacement `dart:` libraries are unsupported.
This is additive structural support, not unrestricted replacement parity.

Installation occurs once in a fresh single-isolate group before it becomes
runnable. Once declaration registration starts, failure poisons the group; the
embedder must destroy it and recreate a fresh baseline group. Host development
and PRODUCT runtime tests cover interface dispatch, added fields, compacting GC,
weak cycles, isolate copies and the real encrypted API. See the
[SDK protocol](../../../../dart-sdk/docs/shorebird-structural-patching.md) for the
complete compiler/runtime contract and acceptance commands.

## iOS App Store Handoff

`DART_DYNAMIC_MODULES` must not be enabled for this project. It adds the dynamic
module interpreter surface and can package code that should not ship in the
target app.

The native Mach-O `.vmcode` path is development-only on iOS. It proves the base
snapshot metadata, updater state machine, and flavor/license transition, but it
still maps downloaded native snapshot text as executable memory. A physical
device accepts that only when the payload is signed appropriately, and that is
not the App Store patch route.

The App Store route follows Shorebird's public architecture shape: the updater
selects a patch before Dart starts, then the Dart SDK installs a payload that is
interpreted by VM code already present in the app. The payload runtime mode is
`dart-bytecode-interpreter`; it is explicitly separate from
`DART_DYNAMIC_MODULES`.

For native development-device checks, build the patch snapshot on macOS with the
iOS `gen_snapshot` that matches the app's Flutter/Dart SDK:

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
  --runtime-mode=native-aot \
  --obfuscation-map-hash=<sha256-of-base-obfuscation-map> \
  --offline-expires-at=2030-01-01T00:00:00Z \
  --full-snapshot=true
```

For the iOS interpreter candidate route, the linker uses:

```sh
dart run open_aot_patch_tools link \
  --base=build/base.interp \
  --patch=build/patch.interp \
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
  --runtime-mode=dart-bytecode-interpreter \
  --offline-expires-at=2030-01-01T00:00:00Z
```

`--full-snapshot=true` is not needed for `dart-bytecode-interpreter`; it is
forced by the linker and enforced by `Dart_InstallAotPatch`.

The encrypted artifact is delivered the same way as the host proof: `encrypt`
wraps it with AES-256-GCM, and the app-owned updater/key callback must validate
metadata before decrypting. `Dart_InstallAotPatch` rejects iOS native-AOT
artifacts, rejects any dynamic-modules runtime mode, and rejects compact
interpreter payloads before payload installation.

The open CLI now follows that route for `shorebird patch ios`. By default, iOS
patch builds compile the patch target to Dart bytecode with `dart2bytecode`,
write `build/ios_interpreter_patch.bytecode`, wrap that payload as
`open-aot-vmcode-encrypted-v1`, and upload the encrypted interpreter artifact.
Before baseline compilation, the CLI regenerates Flutter version metadata with
the pinned tool. It captures the exact resolved Dart defines once, passes those
values to the baseline compiler, and stores them with their hash in
`baseline.json`. Patches retain the six recorded Flutter version/revision/Dart
SDK defines, while user application defines and `FLUTTER_APP_FLAVOR` may change.
Legacy manifests without captured defines retain the old resolution behavior;
a release whose bytecode and manifest disagreed needs a fresh baseline.
The bytecode compile also mirrors Flutter's
`FLUTTER_ENABLED_FEATURE_FLAGS` define for enabled runtime-id features. User
attempts to override those reserved Flutter defines are rejected.
`aot_patch_bytecode_path` and `SHOREBIRD_IOS_INTERPRETER_PATCH_PATH` are local
override hooks for experiments. The native iOS AOT patch branch is kept only for
development-device validation and requires `SHOREBIRD_IOS_NATIVE_AOT_PATCH=1`.

The open Flutter engine bridge can now pass the encrypted artifact selected by
the updater into `Dart_InstallAotPatch`, then hand the decrypted bytecode to
`Dart_ReloadBytecodePatch`. This bridge is intentionally no-DDM and never adds
interpreter patches to native `application_library_paths`. In product iOS AOT,
`Dart_ReloadBytecodePatch` uses the no-DDM bytecode replacement mapper instead
of stock VM reload: it reads the bytecode component as data, resolves existing
libraries/classes/functions from the signed base snapshot, and switches matched
functions to the VM's signed `InterpretCall` stub with attached bytecode. This
does not enable `DART_DYNAMIC_MODULES` and does not map downloaded executable
memory.

For local encrypted interpreter tests, `shorebird.yaml` may provide expected
metadata:

```yaml
aot_patch_runtime_mode: dart-bytecode-interpreter
patch_verification: strict
patch_response_verification: required
aot_patch_structural_updates: false # true only for an opted-in release baseline
aot_patch_key_id: test-key
aot_patch_app_build_id: 1.2.3+4
aot_patch_base_flavor_id: free
aot_patch_base_license_type: free
aot_patch_flavor_id: pro
aot_patch_license_type: pro
aot_patch_sdk_hash: <flutter-engine-or-dart-sdk-hash>
aot_patch_base_snapshot_hash: <sha256-of-base-bytecode-snapshot>
```

Add `aot_patch_bytecode_path: build/patch.interp` only when overriding the
generated bytecode payload.

Set `SHOREBIRD_AOT_PATCH_KEY_HEX` when running the CLI so the key is not bundled
with the reviewed app. Embedding `aot_patch_key_hex` in `shorebird.yaml` remains
a development bridge only; strict iOS route checks reject it. The implemented
`FlutterDartProject.shorebirdAotPatchKeyProvider` supplies the runtime AES key from
an app-owned source. Native encrypted delivery has the equivalent
`shorebird_set_patch_decryption_key_provider` callback. Provisioning from an
authenticated app service remains the application's responsibility; never derive
a secret from a public device identifier.

The Flutter engine patch cache is prepared for this handoff:

- `dart_enable_aot_patching` is enabled for iOS without enabling
  `dart_dynamic_modules`.
- `shorebird_use_interpreter` is enabled for iOS and the native
  `shorebird_enable_aot_patching` snapshot loader is disabled.
- Interpreter patch paths are not inserted into `application_library_paths`;
  that list is reserved for native snapshot symbol lookup.
- Encrypted interpreter artifacts are decrypted to data and handed to the VM
  patch API; no downloaded native text is mapped executable.
- Product iOS includes no-DDM body replacement and the explicit additive
  structural profile. Compact interpreter reconstruction remains future work.
- VM snapshot symbols continue to resolve from the signed base App.framework.

Current acceptance evidence is recorded in the workspace
[platform testing record](../../../../docs/PLATFORM_TESTING.md). Host development
and PRODUCT runtime tests cover the implemented structural profile and encrypted
C API. On October 29, a distribution-signed structural release displayed
`license:free` on a physical iPad without a debugger. That establishes baseline
startup only. Patch compilation exposed nullable FFI reader and Flutter metadata
consistency defects; their fixes require a new release and the complete
publish/download/install/restart test. No current device structural patch success
is claimed. Historical June seeded proofs do not validate the current merged
profile. TestFlight/App Store distribution and size/performance measurements
remain outstanding.

The supported native CI matrix runs by default; web is an experimental manual
build only. Run
[40803323899](https://github.com/tony-cloud/shorebird-workspace/actions/runs/40803323899)
completed with 27 passed, 2 failed and 5 skipped jobs, including Windows SDK
configuration and engine-packaging failures. Follow-up verification remains
pending; the available artifacts do not yet establish complete all-platform
acceptance.

## Obfuscation

Interpreter release and patch builds must not use `--obfuscate`, including the
structural profile. The mapper requires stable Dart declaration identities, and
the CLI rejects obfuscated interpreter releases and patches.

For supported native-AOT builds that use name obfuscation, reuse the release
obfuscation map with `gen_snapshot --load-obfuscation-map=<file>` so existing
symbols retain their release names. Bind its hash in artifact metadata. This
native-AOT flow does not enable obfuscation for interpreter patches.

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
