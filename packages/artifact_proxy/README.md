# Artifact Proxy

This is a tool for proxying Flutter artifacts from a derived Flutter engine
revision back to the base Flutter engine revision. This is useful for
when you need to modify _some_ of the Flutter artifacts but not all of them.

This is a development tool which maps requests to configurable artifact origins.
By default, Flutter artifacts are redirected to the public Flutter storage
origin and Shorebird-specific artifacts are redirected to the local open mirror
root at `http://localhost:8080/artifacts`.

## Usage

Uses `config.dart` to configure recognized artifact URL patterns. Runtime
origins are configured with environment variables:

- `SHOREBIRD_ARTIFACT_BASE_URL`: root for open Shorebird manifests and
  artifacts, defaulting to `http://localhost:8080/artifacts`
- `ARTIFACT_PROXY_FLUTTER_BASE_URL`: root for upstream Flutter artifacts,
  defaulting to `https://storage.googleapis.com`

```bash
# Run locally with hot-reload enabled.
PORT=8081 DEV=true dart --enable-vm-service run bin/server.dart
```

And then in a separate terminal:

```
FLUTTER_STORAGE_BASE_URL=http://localhost:8081 flutter precache -a
```

You should use a separate checkout of Flutter when running this, so you don't
poison the cache of your main Flutter checkout.

## Updating config.dart

If you run into 404s when fetching artifacts, ensure that the expected manifest
exists at:

```text
$SHOREBIRD_ARTIFACT_BASE_URL/shorebird/$engineRevision/artifacts_manifest.yaml
```

If it does, you may need to update the artifact list in `config.dart` and, if
the artifact is one we're providing, add it in
`../../../scripts/write_artifact_manifest.py`.

To do so, point Flutter at this proxy with `FLUTTER_STORAGE_BASE_URL`, run a
Shorebird/Flutter command that downloads the missing artifact, then add the
observed URL pattern to `packages/artifact_proxy/lib/config.dart`.

If you changed Flutter tool code while debugging, remove the flutter_tools
snapshot:

  ```bash
  cd bin/cache/flutter/bin/cache
  rm flutter_tools.s*
  ```

- Run a Shorebird command (`shorebird run` works well).
- For each artifact that 404s, add a line to
  `packages/artifact_proxy/lib/config.dart`, following the conventions for
  capturing engine revisions and escaping relevant characters.

## Generating an `artifacts_manifest.yaml`

To generate a new `artifacts_manifest.yaml` for a specific Flutter engine
revision, use the workspace helper:

```
../../../scripts/write_artifact_manifest.py \
  --flutter-engine-revision <flutter_engine_revision> \
  --output artifacts_manifest.yaml
```

`--flutter-engine-revision` is the upstream Flutter engine revision used for
unchanged artifacts. Upload the generated file under the custom Shorebird engine
revision path shown below.

Then upload the `artifacts_manifest.yaml` to:

```text
$SHOREBIRD_ARTIFACT_BASE_URL/shorebird/<shorebird_engine_revision>/artifacts_manifest.yaml
```

The GitHub CI engine artifacts include a `mirror/` subtree for the override
files listed by this manifest. Copy the contents of that subtree to
`$SHOREBIRD_ARTIFACT_BASE_URL` alongside the manifest and `patch-*.zip`
artifacts.

Host `font-subset.zip` archives must also come from the custom engine mirror.
They contain `const_finder.dart.snapshot`, which reads the app's kernel and must
match the custom Dart SDK. The proxy rejects missing overrides for these tools
instead of redirecting to an incompatible upstream snapshot. Static font assets
can continue to use the upstream Flutter origin.
