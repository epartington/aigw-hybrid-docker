# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A deployment configuration for running the **Portkey Gateway Enterprise** self-hosted container alongside Redis. Two deployment targets are covered:

- **Docker Compose** (`docker-compose.yml`) — local or VM-based deployment
- **Helm/Kubernetes** (`values.yml`) — Kubernetes deployment via Portkey's Helm chart

An optional file (`docker-compose.otel.yml`) adds an observability stack (Prometheus, OpenTelemetry Collector, Jaeger) that attaches to the main stack via a shared external network. Its service configs live in `otel/`.

A helper script (`Setup-EntraID-App.sh`) automates EntraID app registration, Claims Mapping Policy creation, and token configuration for OIDC/JWT authentication. See `docs/entraid-jwt-auth.md` for the full setup guide.

## Common commands

```sh
# Pull latest images and start services
docker compose pull && docker compose up -d

# View logs
docker compose logs -f aigw-gateway

# Stop services
docker compose down

# Restart gateway only (e.g. after env changes)
docker compose restart aigw-gateway

# Start observability stack (after the main stack is up)
docker compose -f docker-compose.otel.yml up -d
```

## Architecture

```
aigw-gateway (port 8787)
    └── depends on aigw-redis (port 6379, healthcheck gated)

aigw-net (external Docker network, shared with the OTEL stack)
```

The gateway is stateless; Redis is used solely as a cache (`CACHE_STORE: redis`). Analytics and logs are shipped to Portkey's control plane (`control_plane`) — nothing is stored locally.

The gateway calls out to three Portkey endpoints:

| Env var | Purpose |
|---|---|
| `ALBUS_BASEPATH` | Management plane (AIRS/Strata) |
| `CONTROL_PLANE_BASEPATH` | AI gateway API |
| `CONFIG_READER_PATH` | Model config sync |

### Observability stack (optional)

`docker-compose.otel.yml` starts three services on the shared `aigw-net` network:

| Service | Port | Purpose |
|---|---|---|
| `otel-collector` | 4317 (gRPC), 4318 (HTTP) | Receives OTLP traces from the gateway and forwards to Jaeger |
| `jaeger` | 16686 (UI) | Trace storage and visualisation |
| `prometheus` | 9090 (UI) | Metrics scraping |

The collector config is at `otel/otel-collector-config.yaml`; Prometheus scrape config is at `otel/prometheus.yml`.

The gateway pushes traces when `OTEL_PUSH_ENABLED: true` and `OTEL_ENDPOINT` point at the collector — both are already set in `docker-compose.yml`. The OTEL stack must be started separately after the main stack.

## Environment variables

Required at runtime — supply via `.env` (see `.env.example`) or shell export:

| Variable | Description |
|---|---|
| `PORTKEY_CLIENT_AUTH` | Client auth token issued by Portkey |
| `ORGANISATIONS_TO_SYNC` | Organisation UUID to sync from the control plane |
| `SERVICE_NAME` | Identifier for this gateway instance |
| `PORTKEY_REGISTRY_USERNAME` | Registry username for pulling the enterprise image |
| `PORTKEY_REGISTRY_PASSWORD` | Registry password / token |

Notable env vars already hardcoded in `docker-compose.yml` (no `.env` entry needed):

| Variable | Value | Purpose |
|---|---|---|
| `JWT_ENABLED` | `ON` | Enables JWT/OIDC bearer-token auth |
| `JWT_LOCAL_AUTH_DEFAULT_SCOPES` | `completions.write,mcp.invoke` | Default scopes injected when EntraID omits them |
| `OTEL_PUSH_ENABLED` | `true` | Enables OTLP trace export |
| `DEBUG_ENABLED` | `true` | Verbose gateway logging |
| `TRUSTED_CUSTOM_HOSTS` | `localhost,127.0.0.1,…` | Hosts the gateway is allowed to call |

`values.yml` duplicates the required variables for Kubernetes — keep secret values out of version control (use a secrets manager or `.gitignore` the file).

## Testing the gateway

Smoke-test the token and gateway end-to-end (requires `./get-az-token.sh` configured):

```sh
TOKEN=$(./get-az-token.sh) && \
curl http://127.0.0.1:8787/v1/messages \
  -H "x-portkey-config: <config-id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model": "anthropic.claude-sonnet-5", "max_tokens": 250, "messages": [{"role": "user", "content": "hi"}]}'
```

> **Model prefix**: Vertex AI routing requires the `anthropic.` prefix on model names (e.g. `anthropic.claude-sonnet-5`). Without it the gateway returns `messages is not supported by vertex-ai`.

Decode the JWT to inspect claims:

```sh
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

## Docs

| File | Purpose |
|---|---|
| `docs/aigw-entraid-claude-jwt-auth.md` | End-to-end guide for EntraID OIDC/JWT auth with Claude Desktop |
| `docs/claude-code-cli-entra-auth-dedicate-app.md` | Guide for Claude Code CLI with EntraID JWT auth via a dedicated app registration and `get-az-token.sh` |
| `docs/claude-code-cli-entra-auth-default-az-login.md` | Simpler EntraID auth for Claude Code CLI using a plain `az account get-access-token` — no app registration or claims policy needed |
| `docs/claude-code-cli-vertex-adc-auth.md` | Guide for Claude Code CLI routing to Vertex AI (Anthropic Claude) through AIGW using Google ADC tokens |
| `docs/gemini-cli-vertex-adc-auth.md` | Guide for Gemini CLI routing to Vertex AI (Gemini) through AIGW's `/v1/proxy` pass-through using Google ADC — native Vertex mode |
| `docs/ollaya-typesafe-caddy-tls.md` | Routing TypeSafe System One decision requests through AIGW to a local Ollaya daemon, fronted by Caddy (`tls internal`) at `https://aigw.sase-au.io:8443` |
| `docs/jwt-auth-resolution-logic.md` | Walkthrough of how the gateway resolves org/workspace/scopes from a JWT bearer token (reference when JWT auth resolves to an unexpected workspace or a downstream provider/config lookup fails); flowchart in `docs/images/jwt-auth-flow.excalidraw` |
| `docs/aigw-start-hooks.md` | Writeup of the `start_hooks` guardrail stage (undocumented upstream as of image v2.25.0) — config shape, sync/async execution, header injection, and denial behavior |
| `Setup-EntraID-App.sh` | Interactive script that automates EntraID app registration and claims policy |
| `get-az-token.sh` | `apiKeyHelper` script for Claude Code CLI — fetches EntraID access token via Azure CLI |
