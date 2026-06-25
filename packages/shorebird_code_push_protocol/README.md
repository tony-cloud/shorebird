## Shorebird CodePush Protocol

The Shorebird CodePush Protocol is a Dart library which contains common interfaces used by Shorebird CodePush.

### Regenerating from the OpenAPI spec

Everything under `lib/src/` is generated from an OpenAPI spec by
[space_gen](https://github.com/eseidel/space_gen). For this open workspace,
regenerate from the checked open spec at
`../shorebird-server/internal/api/handlers/openapi.yaml` or from the
self-hosted server's `http://localhost:8080/openapi.yaml` endpoint. Do not
regenerate from Shorebird's hosted API, or the generated protocol may drift
back toward closed service behavior.

```sh
dart run packages/shorebird_code_push_protocol/tool/gen.dart \
  -i http://localhost:8080/openapi.yaml \
  -o packages/shorebird_code_push_protocol
```

Hand-written files (`lib/extensions/`, `lib/shorebird_code_push_protocol.dart`)
are left untouched by the generator. The version of space_gen in use is
pinned in `pubspec.yaml`.
