# Ollaya (Local Decision Models) behind AIGW via Caddy TLS

Routes TypeSafe decision requests through this self-hosted AIGW gateway to a local
[Ollaya](https://ollaya.dev) daemon serving open decision models (`winnow`, `decider`, `laya`, …).
Caddy runs in front of Ollaya so the gateway reaches it over HTTPS at
`https://aigw.internal.example:8443`.

The three pieces live in separate compose projects:

| Component | Location | Port |
|---|---|---|
| AIGW gateway | [docker/docker-compose.yml](../docker/docker-compose.yml) | 8787 |
| Ollaya daemon | `<Your Path>/aigw-ollaya/docker-compose.yml` | 11435 |
| Caddy reverse proxy | `<Your Path>/caddy/docker-compose.yml` + `Caddyfile` | 8443 |

## How it works

Ollaya is "Ollama for decision models". Instead of generating text, it answers **typed questions**
(`choice`, `score`, `noul`) about a `state`, and returns calibrated probabilities. Its `/v1/*`
endpoints are wire-identical to the **TypeSafe** API. AIGW has a matching `typesafe` provider,
so an AIGW integration of that type can point at Ollaya as a custom host.

```
Client
  │  POST http://127.0.0.1:8787/v1/decisions
  │  Authorization: Bearer <EntraID JWT>
  │  model: "@ollaya/winnow:e4b"
  ▼
aigw-gateway (container)
  │  provider "typesafe", custom_host https://aigw.internal.example:8443
  │  guardrails / hooks, logging, analytics
  │  aigw.internal.example → host-gateway   (extra_hosts)
  │  trusts Caddy's local CA          (NODE_EXTRA_CA_CERTS)
  ▼
caddy_proxy :8443  (tls internal)
  │  reverse_proxy host.docker.internal:11435
  ▼
ollaya :11435  →  POST /v1/decisions
```

Caddy is needed for two reasons:

- **Ollaya does not terminate TLS.** Its API contract says to put a reverse proxy in front of it
  for remote access.
- **`aigw.internal.example` is not a real DNS name.** Caddy's `tls internal` issues a certificate for it
  from Caddy's own local CA. The gateway resolves the name through a Docker `extra_hosts` alias.

## Prerequisites

- The AIGW stack is running and JWT auth works. For example, the flow in
  [claude-code-cli-entra-auth-default-az-login.md](claude-code-cli-entra-auth-default-az-login.md).
- The `aigw-net` Docker network exists. The main stack creates it, and Caddy joins it as an
  external network.
- The `airs` CLI is installed and authenticated against the tenant (`airs doctor`).
- On a corporate network with TLS inspection, the corporate CA bundle is available to put into
  the Ollaya image (see step 1).

## 1. Run Ollaya

`<Your Path>/aigw-ollaya/` holds:

| File | Purpose |
|---|---|
| `Dockerfile` | Thin layer over `ghcr.io/ollaya-dev/ollaya` that appends `certs/corporate-ca.crt` to the image trust store. Without it, a corporate TLS-inspecting proxy breaks model pulls from `ollaya.dev` / `huggingface.co` with `UnknownIssuer`. |
| `.dockerignore` | Deny-by-default, so the multi-GB `ollaya_data/` and `*.tar` model exports never go into the build context. |
| `ollaya.env.example` | Template for `.env`: `OLLAYA_PORT`, `OLLAYA_MODEL`, `OLLAYA_IMAGE_TAG`, `OLLAYA_KEEP_ALIVE`, `OLLAYA_DEVICE`, `OLLAYA_LOG`. |
| `docker-compose.yml` | `ollaya` daemon plus a one-shot `ollaya-pull-model` job. |

```sh
cd <Your Path>/aigw-ollaya
cp ollaya.env.example .env          # adjust OLLAYA_MODEL etc.
docker compose up -d --build
```

Compose details:

- `ollaya` binds `0.0.0.0:11435` inside the container, publishes it on host port `11435`, and
  persists models in `./ollaya_data`.
- The image ships `/usr/local/bin/ollaya-healthcheck` but doesn't register it, so the compose
  declares the healthcheck explicitly.
- `ollaya-pull-model` waits for `service_healthy`, then runs `ollaya pull ${OLLAYA_MODEL:-winnow:e4b}`
  and exits. Re-running it is a no-op once the model is local.
- `OLLAYA_DEVICE=cpu`, because Docker/Podman on macOS has no GPU passthrough.

Verify directly against the daemon:

```sh
curl http://localhost:11435/                 # → Ollaya is running
curl -s http://localhost:11435/v1/models | python3 -m json.tool
```

> Ollaya has **no text-generation endpoints**. `/v1/chat/completions`, `/api/chat` and
> `/api/generate` all return `404`. The only inference endpoints are `POST /v1/systemone` and
> its alias `/v1/decisions`. Through the gateway, use `/v1/decisions` (see step 5).

## 2. Run Caddy with an internal CA

`<Your Path>/caddy/Caddyfile`:

```caddyfile
localhost:8443, caddy_proxy:8443, aigw.internal.example:8443 {
	tls internal
	reverse_proxy host.docker.internal:11435
}
```

- `tls internal` makes Caddy act as its own CA (`Caddy Local Authority`). It issues a leaf
  certificate for each site address listed.
- `reverse_proxy host.docker.internal:11435` forwards to Ollaya's published port on the Mac.

`<Your Path>/caddy/docker-compose.yml` publishes `8443`, maps `host.docker.internal` to
`host-gateway`, persists `/data` (which contains the CA keys) in the `caddy_data` volume, and joins
the external `aigw-net` network.

```sh
cd <Your Path>/caddy
docker compose up -d
```

## 3. Export Caddy's root CA and trust it in the gateway

The gateway must trust Caddy's local CA or the TLS handshake fails. Export the root from the
Caddy container:

```sh
mkdir -p <Your Path>/caddy/caddy-ca
docker cp caddy_proxy:/data/caddy/pki/authorities/local/root.crt         <Your Path>/caddy/caddy-ca/root.crt
docker cp caddy_proxy:/data/caddy/pki/authorities/local/intermediate.crt <Your Path>/caddy/caddy-ca/intermediate.crt
```

Append the root to the CA bundle the gateway already mounts, `~/ca.crt`, which also holds the
corporate TLS-inspection CA chain:

```sh
cat <Your Path>/caddy/caddy-ca/root.crt >> ~/ca.crt
```

[docker/docker-compose.yml](../docker/docker-compose.yml) mounts that file and points Node and
OpenSSL at it:

```yaml
volumes:
  - ${HOME}/ca.crt:/etc/ssl/certs/corporate-ca.crt:ro
environment:
  NODE_EXTRA_CA_CERTS: /etc/ssl/certs/corporate-ca.crt
  SSL_CERT_FILE: /etc/ssl/certs/corporate-ca.crt
```

> **Only the root is needed.** Caddy rotates the intermediate about every 7 days. Trusting the
> root (valid ~10 years) means rotation doesn't break anything. The root only changes if the
> `caddy_data` volume is deleted. If that happens, re-export it and replace the old root in
> `~/ca.crt`.

## 4. Point the gateway at `aigw.internal.example`

Two changes to the `aigw-gateway` service in [docker/docker-compose.yml](../docker/docker-compose.yml):

```yaml
extra_hosts:
  # aigw.internal.example isn't a real DNS name — alias it to the host so the
  # gateway can reach Caddy/Ollaya running on the Mac via that hostname
  - "aigw.internal.example:host-gateway"
environment:
  TRUSTED_CUSTOM_HOSTS: "localhost,127.0.0.1,::1,minio,otel-collector,aigw-redis,host.docker.internal,aigw.internal.example"
```

- `extra_hosts` resolves `aigw.internal.example` to the Docker host, where Caddy publishes `8443`.
- `TRUSTED_CUSTOM_HOSTS` allows the gateway to call that hostname as a provider custom host.

Recreate the gateway so the new hosts entry and CA bundle take effect:

```sh
cd docker && docker compose up -d aigw-gateway
```

Verify from inside the gateway container, using Node's trust store the same way the gateway does:

```sh
docker exec aigw-gateway getent hosts aigw.internal.example
docker exec aigw-gateway node -e \
  'fetch("https://aigw.internal.example:8443/v1/models").then(r=>r.text()).then(console.log).catch(e=>console.log(e.cause||e))'
```

A JSON model list means DNS, TLS trust and the Caddy → Ollaya hop all work. A
`SELF_SIGNED_CERT_IN_CHAIN` or `UNABLE_TO_GET_ISSUER_CERT` error means step 3 hasn't taken effect.

> Caddy is also on `aigw-net`, and the Caddyfile lists `caddy_proxy:8443` as a site. So
> `https://caddy_proxy:8443` would work as a custom host without `extra_hosts` (add
> `caddy_proxy` to `TRUSTED_CUSTOM_HOSTS`). The `aigw.internal.example` name is used so the same URL
> could later point at a real DNS record.

## 5. Create the AIGW integration

The integration uses the **TypeSafe** provider from the AIGW catalog (provider slug `typesafe`),
with Ollaya as the custom host. It can be created in the UI or with the `airs` CLI.

**Important: set `custom_host` to the bare origin, with no `/v1`, and call the gateway on
`/v1/decisions`.** The gateway treats the two TypeSafe paths differently:

| Gateway path | How the gateway handles it | Path sent to Ollaya | Guardrails / hooks |
|---|---|---|---|
| `/v1/decisions` | Native `typesafe` route: the provider builds the upstream URL itself | `custom_host` + `/v1/decisions` | Yes: `hook_results` in the response |
| `/v1/systemone` | Not a native route. Falls through to generic pass-through, which strips `/v1` | `custom_host` + `/systemone` | No |

With `custom_host: https://aigw.internal.example:8443`, `/v1/decisions` works and `/v1/systemone`
fails with Ollaya's `{"error":"/systemone not found","code":"NOT_FOUND"}`. Adding `/v1` to
`custom_host` flips it: `/v1/systemone` then works but `/v1/decisions` breaks
(`/v1/v1/decisions` → `typesafe error: Unknown error`). Pass-through also skips the workspace
guardrails. So keep the bare origin and use `/v1/decisions`. Point TypeSafe SDK clients at it too;
the two paths are aliases on the Ollaya side.

Create the integration with the CLI:

```sh
airs aigateway integrations create \
  --name ollaya --slug ollaya \
  --ai-provider-id ba8c412d-b847-11f1-8539-12b17e22b051 \
  --configurations '{"custom_host":"https://aigw.internal.example:8443"}' \
  --key local
```

To change an existing integration's host:

```sh
airs aigateway integrations update <integration-id> \
  --configurations '{"custom_host":"https://aigw.internal.example:8443"}'
```

- `ba8c412d-…` is the catalog ID of the TypeSafe provider. Confirm it with
  `airs aigateway integrations get <id> --output json` on an existing TypeSafe integration.
- `--key local` is a placeholder. The TypeSafe client needs a non-empty key, and Ollaya ignores
  `Authorization` unless `OLLAYA_API_KEY` is set (see [Hardening](#hardening)).

Give workspaces access to the integration in the UI, or with
`airs aigateway integrations workspaces set`. Each grant auto-creates a workspace provider with
slug `ollaya`. That provider is what clients reference as `@ollaya`:

```sh
airs aigateway integrations workspaces list <integration-id> --output json
airs aigateway providers list --workspace <workspace-uuid> --output json   # look for slug "ollaya", ai_provider_slug "typesafe"
```

The integration uses `allow_all_models: true`, so any model Ollaya has locally can be requested
by name.

## 6. Test end to end

```sh
TOKEN=$(az account get-access-token --query accessToken -o tsv)

curl http://127.0.0.1:8787/v1/decisions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "@ollaya/winnow:e4b",
    "state": {"subject": "Invoice", "message": "Can I get an invoice for last month?"},
    "questions": {
      "intent": {
        "type": "choice",
        "instructions": "What does the customer want?",
        "criteria": {
          "invoice": "Needs an invoice or receipt",
          "refund":  "Wants money back",
          "other":   "Anything else"
        }
      },
      "billing": {"type": "noul", "instructions": "Is this message about billing?"}
    }
  }'
```

- The `@ollaya/` model prefix selects the workspace provider. Alternatively, send
  `-H "x-portkey-provider: @ollaya"` and a bare `"model": "winnow:e4b"`.
- To authenticate with an AIGW API key instead of a JWT, send
  `-H "x-portkey-api-key: $PORTKEY_API_KEY"`.

Expected response (on CPU the first call takes ~10s while the model loads). The gateway also adds
`provider` and `hook_results` (the guardrail verdicts):

```json
{
  "model": "winnow:e4b",
  "answers": {
    "intent": {"type": "choice", "choice": "invoice", "confidence": 0.9818,
               "probabilities": {"invoice": 0.9879, "refund": 0.0035, "other": 0.0086}},
    "billing": {"type": "noul", "noul": 0.9664}
  },
  "usage": {"input_tokens": 235, "output_tokens": 0},
  "provider": "typesafe",
  "hook_results": { "before_request_hooks": [ ... ], ... }
}
```

Gateway logs show the routing:

```sh
docker logs --since 5m aigw-gateway 2>&1 | grep typesafe
# ... {"model":"winnow:e4b","provider":"typesafe"}
```

To test a candidate custom host before changing the integration, override it for one request:

```sh
  -H "x-portkey-custom-host: https://<host>:<port>"    # bare origin, no /v1; host must be in TRUSTED_CUSTOM_HOSTS
```

## Question types quick reference

| `type` | `criteria` | Answer fields |
|---|---|---|
| `choice` | object `label → description` (2–255 labels) | `choice`, `confidence`, `probabilities` |
| `score` | array of level descriptions, level 0 first (2–10) | `score` (expected level), `confidence`, `legend`, `probabilities` |
| `noul` | optional `{ "true": …, "false": … }` | `noul` (probability the statement holds) |

A request can have up to 256 questions. `state` can be any JSON string, object or array, up to
65,536 tokens. If `instructions` is omitted, the model reads the question id instead, so use
descriptive ids like `is_spam` or `urgency`. Full contract:
[ollaya docs/api.md](https://github.com/ollaya-dev/ollaya/blob/main/docs/api.md).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `{"error":"/systemone not found","code":"NOT_FOUND"}` | Client called gateway `/v1/systemone`, which the gateway passes through as `/systemone` | Call `/v1/decisions` instead (step 5) |
| `typesafe error: Unknown error` on `/v1/decisions` | `custom_host` ends in `/v1`, so Ollaya receives `/v1/v1/decisions` | Set `custom_host` to `https://aigw.internal.example:8443` |
| Old behaviour persists right after changing the integration | The gateway syncs integration config from the control plane periodically | Wait a short while and retry; `airs aigateway integrations get <id>` shows the control-plane value, not what the gateway has cached |
| `{"error":"/v1/chat/completions not found"}` | Client sent a chat request to Ollaya | Ollaya only serves decisions. Call `/v1/decisions` |
| `fetch failed` / `SELF_SIGNED_CERT_IN_CHAIN` in gateway logs | Gateway doesn't trust Caddy's root CA | Re-export `root.crt`, append to `~/ca.crt`, recreate `aigw-gateway` |
| `ENOTFOUND aigw.internal.example` | `extra_hosts` entry missing, or container not recreated | Add the `extra_hosts` entry and run `docker compose up -d aigw-gateway` |
| Custom host rejected / not allowed | Host missing from `TRUSTED_CUSTOM_HOSTS` | Add `aigw.internal.example` and recreate the gateway |
| `502` from Caddy | Ollaya not running or not on host port 11435 | `docker ps` / `curl http://localhost:11435/` |
| `404 MODEL_NOT_FOUND` | Model not pulled locally | `curl http://localhost:11435/v1/models`. Pull with `OLLAYA_MODEL=<name> docker compose up ollaya-pull-model` |
| `422 STATE_TRUNCATED` | `state` exceeds the model's context on `/v1/*` | Shorten `state`, or use a model with a larger context |
| Ollaya pulls fail with `UnknownIssuer` | Corporate TLS inspection | Rebuild the Ollaya image with `certs/corporate-ca.crt` (step 1) |
| `curl https://aigw.internal.example:8443` fails on the Mac itself | No host DNS entry (only the container has the alias) | `curl --resolve aigw.internal.example:8443:127.0.0.1 --cacert <Your Path>/caddy/caddy-ca/root.crt …` |

## Hardening

This setup is a local POC. Before sharing the host:

- **Set `OLLAYA_API_KEY`.** Ollaya binds `0.0.0.0:11435` and is published on all host interfaces
  with no auth. Anyone who can reach the port can run decisions and also pull, delete or create
  models. Set `OLLAYA_API_KEY` in the Ollaya compose, then set the same value as the integration
  key (`airs aigateway integrations update <id> --key …`, or preferably `--secret-mappings`).
- **Restrict published ports.** Bind Ollaya to loopback (`"127.0.0.1:11435:11435"`) since Caddy
  reaches it via the host gateway. Or put Ollaya on `aigw-net` and have Caddy proxy to
  `ollaya:11435` with no host port at all.
- **Use a real certificate** (ACME or corporate PKI) if `aigw.internal.example` gets a real DNS record,
  and drop the internal CA from `~/ca.crt`.
