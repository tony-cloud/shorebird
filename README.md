## Shorebird

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE-MIT)
[![License: Apache](https://img.shields.io/badge/license-Apache-orange.svg)](./LICENSE-APACHE)

## Getting Started

This fork is wired for the open workspace CI and self-hosted services described
in [OPEN_SOURCE_REPLACEMENTS.md](OPEN_SOURCE_REPLACEMENTS.md). The root
workspace workflow, `.github/workflows/open-shorebird-ci.yml`, builds the open
CLI, server, updater patch tools, custom Dart SDK, and engine artifacts.

## Packages

This repository is a monorepo containing the following packages:

| Package                                                                         | Description                                                                             |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [shorebird_cli](packages/shorebird_cli/README.md)                               | Command-line which allows developers to interact with various Shorebird services        |
| [shorebird_code_push_client](packages/shorebird_code_push_client/README.md)     | Dart library which allows Dart applications to interact with the Shorebird CodePush API |
| [shorebird_code_push_protocol](packages/shorebird_code_push_protocol/README.md) | Dart library which contains common interfaces used by Shorebird CodePush                |
| [artifact_proxy](packages/artifact_proxy/README.md)                             | Dart server which supports intercepting and proxying Flutter artifact requests          |
| [discord_gcp_alerts](packages/discord_gcp_alerts/README.md)                     | Dart server which forwards GCP alerts to Discord                                        |
| [flutter_version_resolver](packages/flutter_version_resolver/README.md)         | Command-line utility that determines which Flutter version should be used for a project |
| [jwt](packages/jwt/README.md)                                                   | Dart library for verifying JSON Web Tokens                                              |
| [redis_client](packages/redis_client/README.md)                                 | Dart library for interacting with Redis                                                 |
| [scoped_deps](packages/scoped_deps/README.md)                                   | A simple dependency injection library built on Zones                                    |
| [stripe_api](packages/stripe_api/README.md)                                     | Dart library for interacting with Stripe                                                |

For more information, please refer to the documentation for each package.

## Contributing

If you're interested in contributing, use this fork's issue tracker or the root
workspace documentation.

### Environment setup

Working on Shorebird requires Dart.

`./scripts/bootstrap.sh` will run `pub get` all packages in the repository.

### Running tests

We don't yet have a script to run tests locally. For now, we recommend using
`very_good test -r` in the packages directory to run all shorebird tests.

(If you run it in the root, it will find packages in bin/cache/flutter and try
to run tests there, some of which will fail.)

To generate a coverage report install `lcov`:

```
brew install lcov
```

Then run tests with the `--coverage` flag:

```
very_good test -r --coverage
genhtml coverage/lcov.info -o coverage
```

You can view the generated coverage report via:

```
open coverage/index.html
```

### Tracking coverage

The following command will generate a coverage report for the Dart packages:

```bash
dart test --coverage=coverage && dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --packages=.dart_tool/package_config.json --check-ignore
```

Coverage reports are generated locally under `coverage/`. Configure upload for
your own mirror or CI account when publishing this fork.

## License

Shorebird projects are licensed for use under either Apache License, Version 2.0
(LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0) MIT license
(LICENSE-MIT or http://opensource.org/licenses/MIT) at your option.

See the Apache and MIT license files in this repository for the license terms.
