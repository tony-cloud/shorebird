# Code Push Troubleshooting

The open replacement uses a self-hosted server and a local artifact mirror by
default. Check these values first when release or patch commands fail:

- `SHOREBIRD_HOSTED_URL`, default `http://localhost:8080`
- `SHOREBIRD_AUTH_URL`, default `http://localhost:8080/auth`
- `SHOREBIRD_ARTIFACT_BASE_URL`, default `http://localhost:8080/artifacts`
- `SHOREBIRD_FLUTTER_STORAGE_BASE_URL`, default `http://localhost:8080/download.flutter.io`

## Unsupported Class File Major Version 65

Use the Java version expected by the Flutter and Android Gradle Plugin version
in your project. If the Gradle build fails outside Shorebird, resolve that
plain `flutter build` failure before retrying the Shorebird command.

## Can't Run My App In VS Code

Run the app with the generated Flutter SDK and engine artifacts from this
workspace. Mixing a release built by this workspace with a stock Flutter tool
can make debug and launch behavior confusing.

## Your App Contains Asset Changes Warning When Creating A Patch

Asset changes are not part of a Dart code patch. Create a new release when
assets, native resources, icons, or bundled files change.

## Your App Contains Native Changes Warning When Creating A Patch Even Though You Haven't Changed Swiftobjective Ckotlinjava Code

Native build outputs can change when project files, plugins, build settings,
or generated native artifacts change. Compare the release and patch build
inputs, then create a new release if native outputs are expected to differ.
