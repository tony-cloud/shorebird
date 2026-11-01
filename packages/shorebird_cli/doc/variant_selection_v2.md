# Publishing interpreter variants

Protocol 2 is an explicit new native release capability. Add
`selection_protocol: 2` to the application's source `shorebird.yaml`, retain the
interpreter verification/key-provider policy, and set `aot_patch_app_build_id`
to the exact release version including its build number (for example
`1.0.0+1`). The version must match the built application's version. This field
is required before building because the immutable scope is sealed into the
native package. Existing releases and an omitted protocol remain v1.

This producer currently supports iOS interpreter body, structural and full
replacement profiles, and macOS full replacement on ARM64. macOS requires the
existing `--target-platform=darwin-arm64` build option. It rejects native-AOT v2
and other publication platforms rather than producing an incomplete scope.
Runtime execution and platform acceptance must be validated separately.

Use managed release signing. Customer public-key options and unsigned releases
cannot bootstrap v2. The compiled YAML explicitly contains protocol 2, strict
artifact verification, required signed responses, and the pinned managed public
key. Each package contains exactly the seven public runtime identity fields in
`shorebird_release_scope_<platform>_aarch64.json`. Body/structural profiles bundle
`shorebird_interpreter_base.bytecode`; full replacement retains
`shorebird_replacement_base.sbr`. Private paths and encryption keys are not
compiled into those assets.

Release publication creates a protocol-2 release, uploads its archives and
original-baseline supplement, retrieves and hashes the stored files, and
independently verifies their compiled scope and original baseline. It then
registers immutable provenance and activates exactly `aarch64`. Published v2
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
