# Claude Code CLI — EntraID JWT Authentication via AIGW

Configures the Claude Code CLI to send requests through this self-hosted AIGW gateway, authenticated using a Microsoft EntraID JWT bearer token obtained automatically from the local Azure CLI session.

## How it works

Claude Code CLI supports an `apiKeyHelper` — a script it calls on each session start whose stdout becomes the bearer token sent to the gateway. `get-az-token.sh` in this repo fills that role: it fetches an EntraID access token from the local Azure CLI cache, triggering an interactive browser login if the session has expired.

```
Claude Code CLI
    │
    ├── calls get-az-token.sh → outputs EntraID access token
    │
    └── sends requests to AIGW gateway (http://localhost:8787)
            Authorization: Bearer <token>
            │
            └── gateway validates JWT, maps claims → Portkey workspace
```

## Prerequisites

- The gateway stack running 
- The EntraID app registration configured for this gateway — see [entraid-jwt-auth guide](aigw-entraid-claude-jwt-auth.md) or run `Setup-EntraID-App.sh`
- `ENTRAID_CLIENT_ID` and `ENTRAID_TENANT_ID` available — set them in the `env` block of `settings.json` (step 2), or let `Setup-EntraID-App.sh` write them for you
- Azure CLI installed (`brew install azure-cli`) and logged in at least once

## 1. Install the token helper script

Copy `get-az-token.sh` from this repo to your Claude config directory:

```sh
cp get-az-token.sh ~/.claude/get-az-token.sh
chmod +x ~/.claude/get-az-token.sh
```

The script reads `ENTRAID_CLIENT_ID` and `ENTRAID_TENANT_ID` from the environment. Supply them via the `env` block in Claude Code's settings (step 2) — that is the recommended approach and no other configuration file is needed.

## 2. Configure Claude Code CLI

Edit (or create) `~/.claude/settings.json`:

```json
{
  "apiKeyHelper": "/Users/<you>/.claude/get-az-token.sh",
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8787",
    "ENTRAID_CLIENT_ID": "<your-app-client-id>",
    "ENTRAID_TENANT_ID": "<your-tenant-id>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "anthropic.claude-sonnet-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "anthropic.claude-opus-4-8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "anthropic.claude-haiku-4-5-20251001",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "3000000"
  }
}
```

| Field | Value |
|---|---|
| `apiKeyHelper` | Absolute path to `get-az-token.sh` |
| `ANTHROPIC_BASE_URL` | Your gateway URL — use `http://localhost:8787` for local Docker |
| `ENTRAID_CLIENT_ID` | The Application (client) ID from the EntraID app registration |
| `ENTRAID_TENANT_ID` | Your Entra tenant ID |
| `ENTRAID_RESOURCE_URI` | *(optional)* App ID URI to request a token for — defaults to `api://<ENTRAID_CLIENT_ID>`. Override only if your app registration uses a custom URI. |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Model ID Claude Code uses for Sonnet requests — must include the `anthropic.` prefix when routing via Vertex AI |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Model ID for Opus requests — same prefix requirement |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Model ID for Haiku requests — same prefix requirement |
| `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` | How long (ms) Claude Code caches the token from `apiKeyHelper` — set to `3000000` (~50 min) to match the Azure CLI token lifetime and avoid unnecessary re-fetches |

> **Tip:** If you have `ENTRAID_CLIENT_ID` and `ENTRAID_TENANT_ID` in your shell environment already (e.g. via `direnv`), you can omit those two from the `env` block and the script will pick them up directly. The model vars should always be set explicitly when using this config.

### Project-level config (recommended when mixing auth methods)

If you use a different Claude Code config for other repos (e.g. a direct Portkey cloud setup), put the gateway settings in a **project-level** `.claude/settings.json` at the root of this repo instead of the global `~/.claude/settings.json`. Claude Code merges the two — project settings override global ones for the same keys — so your global config stays intact for everything else:

```sh
mkdir -p .claude
# create .claude/settings.json with only the gateway-specific overrides
```

```json
{
  "apiKeyHelper": "/Users/<you>/.claude/get-az-token.sh",
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8787",
    "ENTRAID_CLIENT_ID": "<your-app-client-id>",
    "ENTRAID_TENANT_ID": "<your-tenant-id>",
    "ANTHROPIC_CUSTOM_HEADERS": "x-portkey-config: <your-config-id>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "anthropic.claude-sonnet-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "anthropic.claude-opus-4-8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "anthropic.claude-haiku-4-5-20251001",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "3000000"
  }
}
```

Theme, permissions, and any other global settings are inherited automatically.

## 3. Set the Portkey config header (optional)

If your gateway requires an explicit routing config (the `x-portkey-config` header), the recommended approach is to configure a **default config** in the AIGW control plane for your workspace — the gateway then applies it to all requests that don't carry the header explicitly.

Alternatively, you can set it per-project in `.claude/settings.json` at the repo level if Claude Code CLI adds support for custom request headers in your version.

## 4. Verify with curl

Before starting Claude Code, confirm the token and gateway are working end-to-end:

```sh
TOKEN=$(./get-az-token.sh) && \
curl http://127.0.0.1:8787/v1/messages \
  -H "x-portkey-config: <your-config-id>" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model": "anthropic.claude-sonnet-5", "max_tokens": 250, "messages": [{"role": "user", "content": "hi"}]}'
```

> **Model prefix**: when routing via Vertex AI, model names must be prefixed with `anthropic.` (e.g. `anthropic.claude-sonnet-5`). Without the prefix the gateway returns `messages is not supported by vertex-ai`.

If the request succeeds, inspect the token claims to verify the gateway claims are correct:

```sh
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Check that `portkey_oid`, `email_id`, and `uid` are present and match your deployment's `ORGANISATIONS_TO_SYNC` value.

## 5. Start Claude Code

```sh
claude
```

On the first run (or after your Azure CLI session expires) a browser window opens to sign in to EntraID. After authentication the session is cached by the Azure CLI — subsequent invocations are silent until the token expires.

To confirm requests are landing in the gateway, check the control plane logs or AIGW analytics for your workspace.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AADSTS650057: Invalid resource` | App not exposed as an API, or Azure CLI not pre-authorized | Run the fix commands below, or re-run `Setup-EntraID-App.sh` on the existing app |
| `AADSTS501461: AcceptMappedClaims...` | Resource was requested as `api://<id>` instead of bare GUID | `ENTRAID_RESOURCE_URI` must be the bare client GUID, not the `api://` URI — check the `env` block in `settings.json` |
| `AADSTS65001: consent required` | Azure CLI not pre-authorized on the resource app | Pre-authorize Azure CLI (see fix commands below) |
| `ENTRAID_CLIENT_ID not set` | Variable not in the `env` block | Add it to the `env` block in `settings.json` |
| `messages is not supported by vertex-ai` | Model name missing `anthropic.` prefix | Use `anthropic.claude-sonnet-5` not `claude-sonnet-5` when targeting Vertex AI |
| API errors after copying entra config to global `settings.json` | Model env vars absent — Claude Code defaults to bare model names without the `anthropic.` prefix | Add `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, and `ANTHROPIC_DEFAULT_HAIKU_MODEL` with the `anthropic.` prefix to the `env` block |
| `401 Unauthorized` from gateway | JWT invalid or missing claims | Decode the token (see below) and verify `portkey_oid` and `email_id` are present |
| `Invalid API Key (Error Code: 03)` | Bearer token is a literal string, not an actual token | Use `$(./get-az-token.sh)` not `{./get-az-token.sh}` for command substitution |
| Browser opens on every run | Azure CLI token cache expired | Normal — sign in; the cache is then reused for the token lifetime (~1 h) |
| `az: command not found` | Azure CLI not installed | `brew install azure-cli` |
| Gateway returns `502` / no route | No Portkey config header and no default config set | Set a default config in the AIGW control plane for your workspace |

**Decode the token to inspect claims:**

```sh
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

### Fixing AADSTS650057 on an existing app registration

If the app was created before the CLI token flow was needed, expose the API manually:

```sh
APP_OBJECT_ID=$(az ad app show --id "$ENTRAID_CLIENT_ID" --query "id" -o tsv)
SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())")

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"identifierUris\": [\"api://$ENTRAID_CLIENT_ID\"],
    \"api\": {
      \"oauth2PermissionScopes\": [{
        \"id\": \"$SCOPE_ID\",
        \"adminConsentDescription\": \"Access the AIGW gateway\",
        \"adminConsentDisplayName\": \"Access AIGW gateway\",
        \"isEnabled\": true,
        \"type\": \"User\",
        \"value\": \"user_impersonation\"
      }]
    }
  }"
```

After running this, `az account get-access-token --resource "api://$ENTRAID_CLIENT_ID"` will succeed.

## Updating credentials

If you rotate the EntraID app registration or move to a different tenant, update `ENTRAID_CLIENT_ID` / `ENTRAID_TENANT_ID` in:

1. `~/.claude/settings.json` (`env` block) — or the project-level `.claude/settings.json` if you used that approach
2. Re-run `az login --tenant <new-tenant-id>` to refresh the CLI session
