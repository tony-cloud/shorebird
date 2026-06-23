# Open Source Replacement Audit

Last verified: 2026-06-22.

This workspace is intended to build and operate without depending on
closed-source Shorebird components. The audit below distinguishes public
upstream Shorebird code from hosted Shorebird services that still need local
open replacements.

## Verified Public Shorebird Components

The public GitHub organization at `https://github.com/shorebirdtech` lists the
following relevant repositories:

- `shorebirdtech/shorebird`: public CLI, CodePush client, protocol models,
  artifact proxy, and related tooling.
- `shorebirdtech/updater`: public Rust updater library and patch tooling. The
  repository describes `library` as the runtime library linked into Flutter
  Engine and `patch` as the developer patch packaging tool.
- `shorebirdtech/flutter`: public Flutter fork.
- `shorebirdtech/engine` and `shorebirdtech/buildroot`: public archived engine
  build repositories.

Conclusion: the runtime updater is not a closed-source component. The correct
open-source path is to use the public `shorebirdtech/updater` repository at the
engine location expected by the GN build:

```text
../flutter/engine/src/flutter/third_party/updater
```

Run from this directory:

```powershell
.\sync_open_sources.ps1
```

or manually from the workspace root:

```powershell
git clone https://github.com/shorebirdtech/updater.git `
  flutter\engine\src\flutter\third_party\updater
```

## Components Replaced In This Checkout

| Shorebird surface | Public upstream status | Open replacement in this checkout |
| --- | --- | --- |
| Runtime updater linked into Flutter engine | Public: `shorebirdtech/updater` | Use public updater via `sync_open_sources.ps1`; engine wrapper remains at `../flutter/engine/src/flutter/shell/common/shorebird` |
| Patch artifact generator | Public upstream has `shorebirdtech/updater/patch`; this checkout also needs compact encrypted AOT tooling | `packages/open_aot_patch_tools` |
| Hosted CodePush API (`api.shorebird.dev`) | Hosted service, no public server implementation found in the public org audit | `../shorebird-server` |
| Hosted auth service (`auth.shorebird.dev`) | Hosted service | `../shorebird-server` `/auth/*` endpoints |
| Hosted web console (`console.shorebird.dev`) | Hosted service | `../shorebird-server/web` dashboard |
| Artifact proxy for Flutter artifacts | Public in `shorebirdtech/shorebird` | `packages/artifact_proxy` |
| CLI and CodePush protocol/client | Public in `shorebirdtech/shorebird` | `packages/shorebird_cli`, `shorebird_code_push_client`, and `shorebird_code_push_protocol` |

## Self-Hosted Operation

Start the open server:

```powershell
cd ..\shorebird-server
go run ./cmd/server
```

Point the CLI at it:

```powershell
$env:SHOREBIRD_HOSTED_URL = "http://localhost:8080"
$env:AUTH_SERVICE_URL = "http://localhost:8080/auth"
$env:SHOREBIRD_TOKEN = "<jwt-token-from-local-server>"
```

Point devices at it through `shorebird.yaml`:

```yaml
app_id: <app-uuid>
base_url: http://localhost:8080
auto_update: true
```

The local server implements the Shorebird-compatible management and device
patch-check surfaces, including limited offline-license expiry metadata.

## Security Boundary

The public updater, local server, and open patch tools must still enforce:

- patch metadata compatibility: app id, release/build id, platform, arch,
  SDK hash, base snapshot hash, flavor id, and license type
- cryptographic integrity: hash pinning or signing
- AES-GCM delivery confidentiality and tamper detection
- limited offline-license expiry through `offline_expires_at`

Do not replace public upstream source with a new implementation unless the
public repository becomes unavailable or its license changes. Replacing a
public runtime updater with an incompatible clone increases risk and makes iOS
and Android behavior diverge from the engine integration expected by Shorebird.
