# Flutter Versions

This workspace builds against the open Flutter fork configured in
`SHOREBIRD_FLUTTER_GIT_URL`, which defaults to:

```text
https://github.com/tony-cloud/flutter.git
```

Use `shorebird flutter versions list` to inspect versions known to the local
artifact mirror. Prefer passing `--flutter-version` explicitly to release
commands so releases and patches resolve the same engine artifacts.

## Supported Flutter Versions

Supported versions are the versions for which this workspace has built and
published matching engine artifacts into the configured artifact mirror. The
default mirror is:

```text
http://localhost:8080/artifacts
```

If a version is missing, build the matching custom engine artifacts in CI and
publish the generated mirror metadata before creating releases for that
version.
