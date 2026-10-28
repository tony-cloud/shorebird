# Open Replacement Audit

Last verified: 2026-06-25.

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
from the produced patch-tool, metadata, engine, and web artifacts. They also
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
- Linux, Android, web, iOS, and macOS engine/SDK artifacts on manual
  `full_sdk_build=true` runs

`../scripts/verify_ci_workflow.sh` is the executable contract for this audit. It
rejects closed hosted defaults, `DART_DYNAMIC_MODULES=true`, legacy
`aot-tools.dill` publishing, missing checksum sidecars, missing source tests, and
missing required artifact jobs.

## Security Boundary

The open updater, local server, CLI, and patch tools must enforce:

- patch metadata compatibility: app id, release/build id, platform, arch,
  SDK hash, base snapshot hash, flavor id, and license type
- cryptographic integrity through hash pinning/signing where supported
- AES-GCM delivery confidentiality and tamper detection for encrypted interpreter
  payloads
- limited offline-license expiry through `offline_expires_at`

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
