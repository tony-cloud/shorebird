# Open Replacement Audit

Status reconciled: 2026-10-31. See the workspace
[platform testing record](../docs/PLATFORM_TESTING.md) for dated evidence and
remaining acceptance gates. The current replacement is not fully validated on
all supported platforms.

This workspace is intended to build and operate without closed Shorebird
services or closed SDK artifacts. Local forks/submodules are the source of truth:
do not clone official Shorebird infrastructure repositories as a bootstrap
default.

## Local Sources

The combined workspace provides these open replacements:

| Surface | Open replacement in this workspace |
| --- | --- |
| Shorebird CLI | `packages/shorebird_cli`, configured for the self-hosted server and open artifact mirror |
| CodePush client/protocol | `packages/shorebird_code_push_client` and `packages/shorebird_code_push_protocol` |
| CodePush API/auth/console | `../shorebird-server` |
| Artifact mirror/proxy | `packages/artifact_proxy` |
| Runtime updater library | `../updater/library`, linked into the Flutter engine by `../scripts/sync_open_sources.sh` |
| Patch artifact generator | `../updater/patch` and `packages/open_aot_patch_tools` |
| Flutter engine and Flutter tool defaults | `../flutter`, linked to `../dart-sdk` and `../updater` |
| Dart VM patch runtime | `../dart-sdk` |

Run source linking from the workspace root:

```sh
./scripts/sync_open_sources.sh
```

The script links:

```text
flutter/engine/src/flutter/third_party/dart -> dart-sdk
flutter/engine/src/flutter/third_party/updater -> updater
```

Set `UPDATER_SRC` explicitly only when testing another updater fork. The default
path must remain the local `updater` submodule.

## Hosted Surfaces

The open CLI, CodePush client, updater, artifact proxy, and Flutter tool defaults
are configured to use local/self-hosted origins when no override is supplied:

| Hosted surface | Open default |
| --- | --- |
| API/auth server | `http://localhost:8080` |
| OpenAPI contract | `http://localhost:8080/openapi.yaml` and `../shorebird-server/internal/api/handlers/openapi.yaml` |
| CLI patch-tool artifact mirror | `http://localhost:8080/artifacts` |
| Flutter engine/Dart SDK/Maven artifact mirror | `http://localhost:8080/download.flutter.io` |
| Web console | self-hosted `shorebird-server/web` dashboard |

Override these values with `SHOREBIRD_HOSTED_URL`,
`SHOREBIRD_ARTIFACT_BASE_URL`, `SHOREBIRD_FLUTTER_STORAGE_BASE_URL`, and
`SHOREBIRD_FLUTTER_GIT_URL` when pointing the CLI at a public mirror.
Full SDK CI runs upload `open-shorebird-artifact-mirror`, which is assembled
from the produced patch-tool, metadata, engine, and optional web artifacts. They also
upload `open-shorebird-release-manifest`, which validates checksum sidecars and
records provenance for the CLI, server, SDK, engine, and mirror archives. After
downloading CI artifacts manually, run the root
`scripts/assemble_artifact_mirror.sh` helper to reproduce that merge, validate
`artifacts_manifest.yaml`, verify platform `patch-*.zip` tools, and write
missing checksum sidecars before publishing the directory behind
`SHOREBIRD_ARTIFACT_BASE_URL`.

## Platform Patch Routes

| Platform | Patch route |
| --- | --- |
| iOS | Encrypted Dart bytecode interpreter artifact with `DART_DYNAMIC_MODULES=false`; does not load downloaded native executable text |
| Android | Native AOT patch runtime using the public updater `patch` binary and a patch-capable Android engine |
| macOS/Linux | Native AOT patch runtime using the public updater `patch` binary and patch-capable desktop engines |
| Windows | Public updater `patch` binary; runtime verification remains platform-runner dependent |
| Web | SDK artifact build only; not a Shorebird CodePush release platform in this CLI/protocol |

The iOS App Store candidate route is interpreter-based. Do not reintroduce
`DART_DYNAMIC_MODULES`, `aot-tools.dill` publishing, or a native-AOT iOS patch
route as the default.

## CI Contract

The root workflow `.github/workflows/open-shorebird-ci.yml` builds:

- CLI archives containing `shorebird`, `open_aot_patch_tools`, and
  `artifact_proxy`
- public updater `patch-*.zip` mirror artifacts
- self-hosted `shorebird-server` binaries
- custom Dart SDK artifacts
- the native SDK/engine matrix for Linux, Android, iOS, macOS, and Windows by
  default on pushes and pull requests; manual dispatch can disable heavy builds
  with `full_sdk_build=false`
- experimental web SDK artifacts only on manual dispatch with
  `run_unsupported_web_build=true`; web is excluded from the supported matrix

`../scripts/verify_ci_workflow.sh` is the executable contract for this audit. It
rejects closed hosted defaults, `DART_DYNAMIC_MODULES=true`, legacy
`aot-tools.dill` publishing, missing checksum sidecars, missing source tests, and
missing required artifact jobs.

## Interpreter Profiles and Evidence

The default iOS interpreter profile replaces existing function bodies. A release
can opt into `aot_patch_structural_updates: true` to support additive libraries,
classes, functions, methods, constructors, static fields, and instance fields on
existing ordinary mutable classes. Flutter forwards the structural compiler
profile with `--no-tfa`; the same profile must be present in the native release,
full bytecode baseline, and patch delta. The CLI binds this capability to the
released baseline. An old body-only release cannot gain structural capability
through a patch.

Existing signatures, initializers, inheritance and field definitions cannot
change, and declarations cannot be removed. Added fields on existing const,
deeply immutable or native-wrapper classes are unsupported. Constructor-only
nonnullable fields need a declaration initializer or `late` for existing objects.
Interpreter release and patch builds prohibit obfuscation because declaration
identities must remain stable. See the
[SDK structural protocol and limitations](../dart-sdk/docs/shorebird-structural-patching.md).

Host development and PRODUCT runtime tests cover structural dispatch, added
fields, GC, cross-isolate copies, and the actual encrypted install API. On
October 31, a distribution-signed structural release completed the real
CLI/server/updater download/install/restart lifecycle on a physical iPad without
a debugger. It rendered a new generic widget and checked a new helper and fields
on an existing mutable class before reporting `license:pro`. A deliberately wrong
AES key caused clean baseline fallback; a fresh valid patch then recovered and
persisted across another cold app launch. The server recorded the device's
canonical download/install events. This proves the additive profile; it does not
remove the structural restrictions above. See the
[current platform evidence](../docs/PLATFORM_TESTING.md).

CI run [40803323899](https://github.com/tony-cloud/shorebird-workspace/actions/runs/40803323899)
completed with 27 passed, 2 failed and 5 skipped jobs. Windows SDK configuration
and Windows engine packaging failed; the engine itself compiled. Follow-up
verification after local fixes remains pending. This run does not establish a
complete publishable all-platform artifact mirror. Size and performance impact
have not been benchmarked, and App Store/TestFlight distribution remains unproven.

## Security Boundary

The open updater, local server, CLI, and patch tools must enforce:

- patch metadata compatibility: app id, release/build id, platform, arch,
  SDK hash, base snapshot hash, flavor id, and license type
- artifact signatures and authenticated update/rollback responses for managed
  signing, with strict signature verification at boot for iOS interpreter releases
- AES-GCM confidentiality and tamper detection for encrypted interpreter payloads
  and the native encrypted delivery envelope
- limited offline-license expiry through `offline_expires_at`

The iOS interpreter route requires managed signing, `patch_verification: strict`
and `patch_response_verification: required`; unsigned releases, customer signing
and bundled `aot_patch_key_hex` values are rejected by the strict route. The
implemented `FlutterDartProject.shorebirdAotPatchKeyProvider` callback supplies
runtime AES keys from an app-owned source. The CLI takes its producer key from
`SHOREBIRD_AOT_PATCH_KEY_HEX`. Applications must provision keys through their
own authenticated service; a public device identifier is not a secret.

Native encrypted delivery uses the app-owned
`shorebird_set_patch_decryption_key_provider` callback and authenticated server
response metadata. The updater reconstructs the executable into a plaintext
installed cache. Encrypted delivery does not provide native executable at-rest
confidentiality. Native customer signing requires explicit
`patch_response_verification: optional` until a publisher supplies a response
signing service. Existing tests cover signed responses, rollback, key rejection,
restart persistence and boot identity; they do not prove resistance to complete
device-storage rollback.

Open replacement work should preserve Shorebird-compatible protocol shapes where
the CLI/updater expect them, while keeping service origins, SDK builds, and patch
tools controlled by this workspace.

## CLI authentication compatibility

The open server's `/auth/login` requires a `continue` callback. The CLI retains
that login flow for auth services mounted at `/auth`, then uses the current
OAuth token storage with `/auth/token`. Rerunning login verifies an unexpired
access token against the user API instead of forcing a refresh. Expired tokens
follow the existing refresh route; the server must accept its issued refresh
token format for renewal to succeed. Existing
`credentials.json` logins migrate to `credentials-v2.json`. Set
`SHOREBIRD_AUTH_FLOW=oauth` to select the standard OAuth authorization flow, or
`SHOREBIRD_AUTH_FLOW=legacy` for an open server mounted at another path. The open
server does not implement device authorization; follow the URL printed by
`shorebird login` instead of using `--device`.

The open macOS updater retains the whole `App.framework/App` patch diff base.
The CLI mirrors that contract even when an `analyze_snapshot` executable is
present; it never requires the private `aot_tools dump_blobs` implementation.
The official snapshot-region base contract is not enabled in this open build.
