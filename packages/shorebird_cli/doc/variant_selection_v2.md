# Publishing signed variant selections

Protocol 2 is an explicit new native release capability. Add
`selection_protocol: 2` to the application's source `shorebird.yaml`, retain the
interpreter verification/key-provider policy, and set `aot_patch_app_build_id`
to the exact release version including its build number (for example
`1.0.0+1`). The version must match the built application's version. This field
is required before building because the immutable scope is sealed into the
native package. Existing releases and an omitted protocol remain v1.

This producer supports native AOT on Android ARMv7/ARM64/x64 and native
Linux/Windows x64/ARM64, plus iOS interpreter body, structural and full
replacement profiles and macOS full replacement on ARM64 or x64. macOS requires
an explicit single `--target-platform=darwin-arm64` or
`--target-platform=darwin-x64` build option and a matching verified local
interpreter engine. Linux/Windows builds run on the matching native OS and Dart
SDK architecture; cross compilation is unsupported. Other publication profiles fail closed.
Runtime execution and platform acceptance must be validated separately.

Use managed release signing. Customer public-key options and unsigned releases
cannot bootstrap v2. The compiled YAML explicitly contains protocol 2, strict
artifact verification, required signed responses, and the pinned managed public
key. Each package contains exactly the seven public runtime identity fields in
`shorebird_release_scope_<platform>_<arch>.json` (`aarch64` or macOS
`x86_64`). Body/structural profiles bundle
`shorebird_interpreter_base.bytecode`; full replacement retains
`shorebird_replacement_base.sbr`. Private paths and encryption keys are not
compiled into those assets.

Release publication creates a protocol-2 release, uploads its archives and
original-baseline supplement, retrieves and hashes the stored files, and
independently verifies their compiled scope and original baseline. It then
registers immutable provenance and activates exactly the built single Apple
architecture. Published v2
platforms cannot be drafted/rebuilt. A conflicting v2 upload must match both the
registered file hash and freshly retrieved stored bytes; a conflict alone is
never considered successful. Namespace or baseline changes require a new
release version.

Publish a paid target with `shorebird patch ios --variant=pro` (or
`shorebird patch macos --variant=enterprise`). `--variant` is independent of
Flutter `--flavor`, which still chooses the build-time app ID. The variant sets
the encrypted artifact's target flavor; `aot_patch_license_type` and
`aot_patch_key_id` supply its authenticated license and key policy. V2 permits
different target keys while preserving the original baseline and SDK binding;
v1 retains its original key-equality check. An authenticated envelope expiry is
forwarded without whole-second rounding as `offline_expires_at` on upload.

The CLI maps the completed content through the authenticated variants API.
Promotion alone does not assign an installation. An authorized backend can use
`CodePushClient.putReleaseVariant` for an explicit free-base mapping and
`CodePushClient.assignReleaseSelection` for CAS/idempotent installation
assignment. It must authenticate entitlement before a paid assignment. The
assignment request carries the server contract's expected epoch, idempotency
key, entitlement revision, activation time and nullable offline lease; the
server allocates the new epoch. No device/client identifier grants entitlement.


## Native AOT releases and patches

Native v2 source YAML requires `selection_protocol: 2` and
`aot_patch_app_build_id` equal to the exact built release version. Omit
`aot_patch_runtime_mode` or set it to `native-aot`. Use managed signing; strict
verification and required signed responses are compiled into the host. An
explicit `native_patch_max_bytes` remains immutable and must match the packaged
policy on release, patch, and finalization. Omission preserves the runtime's
supported default budget.

Publication performs two Flutter builds. The first remains protocol 2 with no
public scopes and cannot be uploaded. The CLI measures the actual packaged AOT
libraries, writes private original baselines and the complete scope set to
`SHOREBIRD_NATIVE_SELECTION_MANIFEST`, then builds a sealed package. Every final
packaged AOT hash must match the measurement before any upload. Android always
uses `base/lib/<ABI>/libapp.so` in the final AAB after AGP stripping; missing or
invalid AABs never fall back to intermediates. Separate Android AOT uploads must
match those same AAB bytes. Public assets contain only the seven scope fields.

A normal native v2 release publishes its complete built architecture set. To
combine desktop architecture packages, run the same release/version on each
native machine with `--stage-only`; each invocation uploads, downloads, verifies
and registers its package while retaining draft status. Then run from the
project with its unchanged policy:

```sh
shorebird release-finalize --platform linux --release-version 1.0.0+1 --arch x86_64,aarch64
```

Use `--platform windows` for Windows. Finalization independently downloads every
staged package and optional supplement, checks recorded hashes/sizes, compiled
policy and original AOT identity, and compares every registration before
activating exactly the explicitly requested set. A partial set fails. Published
architecture sets remain immutable; a new architecture after activation needs a
new release version.

For native patches, pass `--release-version` (or `latest`) noninteractively so
the CLI can fetch and verify the original release before building. Add a
canonical `aot_patch_license_type` such as `pro` to source YAML and use
`--variant pro`; Flutter `--flavor` remains independent app-ID routing. Optional
`aot_patch_offline_expires_at` must be a future UTC timestamp and is forwarded
unchanged as the immutable uploaded content cap. Native source license/expiry
metadata is omitted from compiled runtime policy. Native target mappings use
`kind: patch`, `transport-aes-256-gcm`, and `artifact_key_id: null`. The CLI
uploads the existing ordinary native diff; the server owns per-installation
transport encryption. Original scope, managed key and budget mismatches cannot
be overridden by native/asset difference flags. Native plugin/archive comparison
continues to run through the existing diff path.

These CLI checks are build/publication validation. Actual runtime acceptance is
required separately for every platform and architecture.


The macOS x64 full profile uses `macos_x64` native-assets provenance, an
architecture-specific frozen host ABI, x64 PRODUCT SDK inputs and interpreter
envelope metadata, and wire architecture `x86_64`. iOS remains physical ARM64.
macOS body-only, structural, implicit and universal builds fail closed; combining
both macOS architectures in one package is not implemented. Native x64 runtime
acceptance still requires strict Intel CI evidence; these source and tool tests
do not establish app startup or executed patch replacement on Intel hardware.
