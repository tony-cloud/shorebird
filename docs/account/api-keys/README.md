# API Keys

This open Shorebird workspace is configured for a self-hosted server by
default. Create and manage API keys in that server's console, then pass the
token to the CLI with the `SHOREBIRD_TOKEN` environment variable.

Default local services:

- API: `http://localhost:8080`
- Auth: `http://localhost:8080/auth`
- Console: `http://localhost:8080`

The CLI also accepts `SHOREBIRD_HOSTED_URL`, `SHOREBIRD_AUTH_URL`, and
`SHOREBIRD_TOKEN` overrides for non-local deployments.
