# Preparing an iOS interpreter baseline

Interpreter releases currently use **managed patch signing**. The self-hosted
server holds the managed RSA key and signs both artifact hashes and nonce-bound
patch-check responses. Customer signing with `--public-key-path` or
`--public-key-cmd` cannot authenticate those responses and is rejected for this
mode. Customer signing remains available for native AOT releases when source YAML
explicitly sets `patch_response_verification: optional`. Their artifact
signatures remain verified. A default or explicit `required` response policy is
rejected for customer signing because the server cannot produce those
responses. Managed native signing keeps authenticated responses by default.

Before the first release, the app must install its app-owned AES key provider.
Choose a key id that the provider recognizes. Provision the corresponding key
through the app's own trusted mechanism; do not bundle `aot_patch_key_hex` in the
app. The key id is public and does not supply the key itself.

The signed baseline must identify its current flavor/license, SDK compatibility
id, and baseline Dart bytecode hash. The CLI resolves the app id from the chosen
flavor. The engine obtains the app build id from the actual release version
unless an explicit `aot_patch_app_build_id` is provided. Target flavor/license
restrictions are optional: omit them when an authenticated patch may change
`free` to `pro`.

## Automatic release and patch preparation

`shorebird release ios` and `shorebird release ios-framework` compile full
baseline bytecode with the pinned public SDK before sealing the app. The measured
SHA-256 is injected into the compiled policy without changing source YAML.
When no SDK id is configured, the pinned Shorebird engine revision is used.
The bytecode and an identity manifest are uploaded only in the private
`ios_supplement` or `ios_framework_supplement`; they are not app bundle assets.

Use `shorebird patch ios --release-version=latest` (or a concrete version)
so the baseline and pinned signing key are selected before compilation.
For a patch, the CLI downloads that exact release supplement, verifies its
app/release/build/SDK/flavor/license/key identity, and compiles with
`dart2bytecode --patch-base=<baseline.bytecode>`. The compiler emits changed
function bodies and rejects declaration/layout/initializer changes. The
resulting delta is AES encrypted, while the native app build used for diff
checks keeps the released baseline policy. Both native builds disable TFA for
explicit iOS interpreter mode; switching the mode invalidates cached kernel.

Interpreter releases and patches reject `--obfuscate`: native obfuscation changes
the symbol and library names used to locate interpreted method bodies.

The source YAML still requires explicit runtime mode, base flavor/license, and
an app-owned key id. `aot_patch_sdk_hash` and `aot_patch_base_snapshot_hash` may
be omitted. An explicit baseline hash must match the measured bytecode.

## Manually measure or audit the baseline bytecode

Use the **same pinned SDK, Flutter product platform, entrypoint, package lock,
defines, flavor, experiments, and feature flags** that the release and later
`shorebird patch ios` use. A native `App.framework/App` hash is not a bytecode
hash. Keep the bytecode and build inputs with the release artifacts.

The public compiler invocation used by the CLI is:

```bash
# Run from the app directory after resolving its dependencies with the pinned SDK.
FLUTTER_DIR=/absolute/path/to/pinned/flutter
DARTAOTRUNTIME="$FLUTTER_DIR/bin/cache/dart-sdk/bin/dartaotruntime"
DART2BYTECODE="$FLUTTER_DIR/bin/cache/dart-sdk/bin/snapshots/dart2bytecode.dart.snapshot"
PLATFORM_DILL="$FLUTTER_DIR/engine/src/out/ios_release/flutter_patched_sdk/platform_strong.dill"
if [[ ! -f "$PLATFORM_DILL" ]]; then
  PLATFORM_DILL="$FLUTTER_DIR/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill"
fi
mkdir -p build

# Include each resolved --dart-define / --dart-define-from-file entry, and
# FLUTTER_APP_FLAVOR when --flavor is used. This example has no flavor.
BYTECODE_DEFINES=('-DLICENSE_TYPE=free')

# Add the same generated Flutter version defines as the CLI. Never replace
# these with the host's system Flutter version.
while IFS= read -r define; do
  BYTECODE_DEFINES+=("-D$define")
done < <(python3 - "$FLUTTER_DIR/bin/cache/flutter.version.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    version = json.load(source)
for output, field, short in [
    ('FLUTTER_VERSION', 'frameworkVersion', False),
    ('FLUTTER_CHANNEL', 'channel', False),
    ('FLUTTER_GIT_URL', 'repositoryUrl', False),
    ('FLUTTER_FRAMEWORK_REVISION', 'frameworkRevision', True),
    ('FLUTTER_ENGINE_REVISION', 'engineRevision', True),
    ('FLUTTER_DART_VERSION', 'dartSdkVersion', False),
]:
    value = version.get(field)
    if isinstance(value, str) and value:
        print(output + '=' + (value[:10] if short else value))
PY
)

# For development channels also include the resolved
# -DFLUTTER_ENABLED_FEATURE_FLAGS=... when windowing or accessibility evaluations
# are enabled, matching the release's Flutter config/environment.
# Add each --enable-experiment=... used by that release to this array.
BYTECODE_EXPERIMENTS=()
"$DARTAOTRUNTIME" "$DART2BYTECODE" \
  --platform="$PLATFORM_DILL" --target=flutter \
  --packages=.dart_tool/package_config.json \
  "${BYTECODE_DEFINES[@]}" -Ddart.vm.profile=false -Ddart.vm.product=true \
  "${BYTECODE_EXPERIMENTS[@]}" \
  -o build/ios_baseline.bytecode lib/main.dart
python3 - <<'PY'
import hashlib
with open('build/ios_baseline.bytecode', 'rb') as baseline:
    print(hashlib.sha256(baseline.read()).hexdigest())
PY
```

For `--local-engine` builds, use that local host's `dartaotruntime` and
`dart-sdk/bin/snapshots/dart2bytecode.dart.snapshot`, and the selected device
engine's `flutter_patched_sdk/platform_strong.dill`, matching the CLI artifact
selection. Do not mix the downloaded SDK with a different local engine SDK.

Use this source configuration; the SDK id and bytecode hash are optional measured overrides:

```yaml
app_id: <the app id created by the server>
aot_patch_runtime_mode: dart-bytecode-interpreter
aot_patch_base_flavor_id: free
aot_patch_base_license_type: free
# aot_patch_sdk_hash: <override for the pinned engine revision id>
# aot_patch_base_snapshot_hash: <optional measured lowercase SHA-256>
aot_patch_key_id: <id recognized by the app-owned AES key provider>
patch_verification: strict
patch_response_verification: required
```

`aot_patch_sdk_hash` is currently an exact compatibility identifier pinned by the
signed baseline, not an automatically measured binary digest. A pinned SDK/engine
revision can serve as that identifier. Use precisely the same identifier in each
patch envelope. The base bytecode hash is an actual SHA-256 digest.

Run `shorebird release ios` or `shorebird release ios-framework` with managed
signing enabled and the same build inputs. The Flutter asset compiler forces
strict artifact and response verification for interpreter baselines. It copies
only public policy fields, excluding the AES key and patch-only bytecode path.
The CLI rejects missing app-owned policy before building or publishing.

To prepare a patch, compile its full bytecode with the same SDK and intended
target defines. Supply the AES encryption key through
`SHOREBIRD_AOT_PATCH_KEY_HEX` and set the target flavor/license in patch
configuration or the documented patch environment overrides. The patch's base
snapshot hash continues to name the immutable released baseline.

This recipe prepares policy and bytecode; executing it does not establish that
an IPA successfully applies a patch. Validate a release→patch→restart cycle on
the intended no-JIT runtime before publishing that release.
