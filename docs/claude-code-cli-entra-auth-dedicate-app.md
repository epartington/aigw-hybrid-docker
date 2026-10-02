# Claude Code CLI — EntraID JWT Authentication via AIGW

> **Version 2.** This guide supersedes the previous revision of this document. If you configured the app registration against an earlier version of this guide, work through the setup steps below in full before retrying — the claims configuration surface has changed and the two approaches should not be mixed.

Configures the Claude Code CLI to send requests through this self-hosted AIGW gateway (although this process works with the SaaS AIGW offering too), authenticated using a Microsoft EntraID JWT bearer token obtained automatically from the local Azure CLI session. User and workspace assignment is driven entirely by **Entra security groups**, so adding or moving a user is a group-membership change — no per-user policy edits.

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

Unlike an interactive OIDC flow, the Azure CLI requests an **access token for a resource**, not an ID token — which means the app registration must additionally expose an API and pre-authorize the Azure CLI as a client (steps 6–7 below).

## Prerequisites

- This repo's `docker-compose.yml` stack running
  - `JWT_ENABLED: ON`
- An EntraID tenant with permissions to register applications and manage Enterprise Application properties (Application Administrator or Cloud Application Administrator)
- `openssl` installed locally (for generating the token-signing certificate in step 2)
- Azure CLI installed (`brew install azure-cli`) and logged in at least once

## 1. Register the application

In the [Entra Admin Center](https://entra.microsoft.com), go to **App registrations → New registration**.

![App registrations](./images/1.%20Azure%20EntraID%20App%20Registration.png)

- **Name**: something identifiable, e.g. `aigw-jwt-app`
- **Supported account types**: Single tenant
- **Redirect URI**: not required for the CLI token flow — leave blank unless you also plan to use this app registration for an interactive OIDC client

<img src="./images/2%20New%20App.png" alt="Register an application" width="600">

Note the **Application (client) ID** and **Directory (tenant) ID** from the app's Overview page — both are needed throughout this guide.

## 2. Generate and upload a token-signing certificate

Customizing claims on this app (step 5) requires a certificate — Entra signs tokens with a custom key once you add custom claims, instead of the default Microsoft key. Generate a self-signed certificate and upload the public half:

```sh
openssl req -x509 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -days 365 -nodes \
  -subj "/CN=PortkeyTokenSigningKey"
```

In **App registrations → your app → Certificates & secrets → Certificates → Upload certificate**, upload `cert.pem` (the public key only — never upload or share `key.pem`).

![Upload certificate](./images/4%20Upload%20Certificate.png)

![Certificate added](./images/5%20Certificate%20Added.png)

Keep `key.pem` safe — treat it like any other private key material. It is not consumed by the gateway or by Claude; it only needs to exist so the certificate it backs is valid.

## 3. Patch the manifest

In the app's **Manifest** tab, set two fields under `"api"`:

```json
"api": {
  "acceptMappedClaims": true,
  "requestedAccessTokenVersion": 2,
  ...
}
```

![acceptMappedClaims](./images/6%20Manifest%20Change%20acceptedMappedClaims.png)

![requestedAccessTokenVersion](./images/7%20Manifest%20Change%20reqeuestedAccessTokenVersion.png)

- `requestedAccessTokenVersion: 2` — without this, EntraID issues v1.0 tokens, which `acceptMappedClaims` and the audience checks below do not expect.
- `acceptMappedClaims: true` — required for the app to emit the custom claims configured in step 5.

Click **Save**.

## 4. Restrict and assign access via the Enterprise Application

In the [Entra Admin Center](https://entra.microsoft.com), go to **Enterprise applications → All applications** and search for your app by name — the App Registration above automatically has a matching Enterprise Application (service principal).

![Enterprise App - Choose App](./images/11%20Enterprise%20App%20-%20Choose%20App.png)

### 4a. Require assignment

Under **Properties**, set **Assignment required?** to **Yes**. This is what makes group membership meaningful — without it, any user in the tenant can sign in and get a token regardless of group assignment below.

![Assignment Required](./images/21%20Assignment%20Required.png)

### 4b. Assign the groups that should have access

Under **Users and groups → Add user/group**, assign the security group(s) whose members should be able to use this gateway (e.g. `AIRS Group`). Only members of an assigned group can sign in once assignment is required.

![Users and groups](./images/12%20Users%20and%20Groups.png)

![Add Group](./images/13%20Add%20Group.png)

> **Onboarding a new user**: add them to the appropriate Entra group. No app registration change, no policy edit, no restart — their next token pulls access and claims automatically. This is the mechanism for allocating users "on the fly."

## 5. Configure claims

Still on the Enterprise Application, go to **Single sign-on → OIDC-based Sign-on → Attributes & Claims → Edit**.

![Attributes and Claims](./images/14%20Attributes%20and%20Claims.png)

Add the claims the gateway needs as **Additional claims** (use **+ Add new claim**, source = typed constant value, not an attribute):

| Claim name | Value | Purpose |
|---|---|---|
| `portkey_oid` | Your deployment's `ORGANISATIONS_TO_SYNC` UUID | Org routing — the gateway rejects tokens missing this |
| `portkey_workspace` | A workspace slug, e.g. `ws-main-a-997260` | Workspace routing |
| `scopes` | e.g. `completions.write` | Overrides `JWT_LOCAL_AUTH_DEFAULT_SCOPES` explicitly |

![Add Required Claims](./images/16%20Add%20Required%20Claims.png)

**NOTE:** You can choose to leave out `portkey_workspace` and leverage SCIM group assignment to allocate the workspace instead. Upon authentication the gateway will scan for valid users based on the UPN or email and assign them to the appropriate workspace.

### Group-based claim values (multi-team / multi-workspace)

If different teams need different values — different workspaces, or extra metadata — don't hardcode a single value. Instead, add **claim conditions** scoped to a group, with a distinct value per group. For example, a `metadata` claim that varies by team:

![Group Mapping](./images/17%20Group%20Mapping.png)

With this in place, the same claim resolves differently depending on which group signs in — this is how `portkey_workspace` itself can also be made group-dependent for a multi-workspace deployment: add one claim condition row per group, each with its own value, instead of a single static value in the table above.

Click **Save**.

## 6. Expose an API

The Azure CLI requests a token *for* this app as a resource, which requires the app to expose an API. In **App registrations → your app → Expose an API**, set the **Application ID URI** to the default suggested value (`api://<client-id>`):

![Expose an API](./images/8%20Expose%20an%20API%20-%20add.png)

Add a scope:

| Field | Value |
|---|---|
| Scope name | `user_impersonation` |
| Who can consent | Admins and users |
| Admin consent display name | `Access AIGW gateway` |
| Admin consent description | `Access the AIGW gateway on behalf of the signed-in user.` |
| User consent display name | `Access AIGW gateway` |
| User consent description | `Access the AIGW gateway on your behalf.` |
| State | Enabled |

![Add user_impersonation Scope](./images/9%20Add%20user_impersonation%20Scope.png)

## 7. Pre-authorize the Azure CLI

Still on **Expose an API**, under **Authorized client applications → Add a client application**, add the Azure CLI's well-known client ID (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) and check the `user_impersonation` scope:

![Add Client Application](./images/10%20Add%20Client%20Application.png)

Without this step, `az account get-access-token`/`az login --scope` fails with `AADSTS650057` (if the API isn't exposed yet) or `AADSTS65001` (if the Azure CLI isn't pre-authorized).

> **Note on audience:** `acceptMappedClaims` requires the token audience to be the bare application GUID. Always use the client ID (e.g. `c5490456-...`) as the resource when calling `az account get-access-token` — not the `api://` URI form. Using the URI form triggers `AADSTS501461`.

## 8. Get the Application (client) ID

From either the App Registration's Overview or the Enterprise Application's Overview — they share the same **Application ID**.

![Client ID](./images/18%20Client%20ID.png)

## 9. Install the token helper script

Copy `get-az-token.sh` from this repo to your Claude config directory:

```sh
cp get-az-token.sh ~/.claude/get-az-token.sh
chmod +x ~/.claude/get-az-token.sh
```

The script reads `ENTRAID_CLIENT_ID` and `ENTRAID_TENANT_ID` from the environment. Supply them via the `env` block in Claude Code's settings (step 10) — that is the recommended approach and no other configuration file is needed.

## 10. Configure Claude Code CLI

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
| `ENTRAID_RESOURCE_URI` | *(optional)* Resource to request a token for — defaults to the bare `ENTRAID_CLIENT_ID` GUID. Override only if you have a reason to deviate; do not set it to the `api://` URI form (see the audience note above). |
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

## 11. Set the Portkey config header (optional)

If your gateway requires an explicit routing config (the `x-portkey-config` header), the recommended approach is to configure a **default config** in the AIGW control plane for your workspace — the gateway then applies it to all requests that don't carry the header explicitly.

Alternatively, you can set it per-project in `.claude/settings.json` at the repo level if Claude Code CLI adds support for custom request headers in your version.

## 12. Verify with curl

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

Check that `portkey_oid`, `portkey_workspace` (if used), and `scopes` are present and match what you configured in step 5. For reference, here's a decoded token showing these claims, alongside a second user in a different group picking up different values automatically:

![JWT Decoded](./images/19%20JWT%20Decoded.png)

![JWT from a different group](./images/20%20JWT%20Alternative%20Login.png)

## 13. Start Claude Code

```sh
claude
```

On the first run (or after your Azure CLI session expires) a browser window opens to sign in to EntraID. After authentication the session is cached by the Azure CLI — subsequent invocations are silent until the token expires.

To confirm requests are landing in the gateway, check the control plane logs or AIGW analytics for your workspace.

## Onboarding a new user

Add them to the Entra group assigned to the app's Enterprise Application (step 4b). No change is needed here — their next `get-az-token.sh` run picks up membership, access, and the correct claims automatically.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AADSTS650057: Invalid resource` | App not exposed as an API | Complete step 6 — "Expose an API" |
| `AADSTS65001: consent required` | Azure CLI not pre-authorized on the resource app | Complete step 7 — "Pre-authorize the Azure CLI" |
| `AADSTS501461: AcceptMappedClaims...` | Resource was requested as `api://<id>` instead of the bare GUID | `ENTRAID_RESOURCE_URI` must be the bare client GUID, not the `api://` URI — check the `env` block in `settings.json` |
| Token has no `portkey_workspace` / wrong workspace | User isn't in a group matched by a claim condition | Add the user to the right group (step 4b / step 5) |
| User can't sign in at all | **Assignment required?** is `Yes` but the user isn't in an assigned group | Assign their group under Enterprise Application → Users and groups (step 4) |
| Claims don't appear in the token | Claims added under the App Registration's **Token configuration** tab instead of the Enterprise Application | Configure claims under **Enterprise Applications → your app → Single sign-on → Attributes & Claims** (step 5) — only this system supports the group-conditioned values used here |
| `ENTRAID_CLIENT_ID not set` | Variable not in the `env` block | Add it to the `env` block in `settings.json` |
| `messages is not supported by vertex-ai` | Model name missing `anthropic.` prefix | Use `anthropic.claude-sonnet-5` not `claude-sonnet-5` when targeting Vertex AI |
| API errors after copying entra config to global `settings.json` | Model env vars absent — Claude Code defaults to bare model names without the `anthropic.` prefix | Add `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, and `ANTHROPIC_DEFAULT_HAIKU_MODEL` with the `anthropic.` prefix to the `env` block |
| `401 Unauthorized` from gateway | JWT invalid or missing claims | Decode the token (see below) and verify `portkey_oid` and `scopes` are present |
| `Invalid API Key (Error Code: 03)` | Bearer token is a literal string, not an actual token | Use `$(./get-az-token.sh)` not `{./get-az-token.sh}` for command substitution |
| Browser opens on every run | Azure CLI token cache expired | Normal — sign in; the cache is then reused for the token lifetime (~1 h) |
| `az: command not found` | Azure CLI not installed | `brew install azure-cli` |
| Gateway returns `502` / no route | No Portkey config header and no default config set | Set a default config in the AIGW control plane for your workspace |

**Decode the token to inspect claims:**

```sh
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

## Updating credentials

If you rotate the EntraID app registration or move to a different tenant, update `ENTRAID_CLIENT_ID` / `ENTRAID_TENANT_ID` in:

1. `~/.claude/settings.json` (`env` block) — or the project-level `.claude/settings.json` if you used that approach
2. Re-run `az login --tenant <new-tenant-id>` to refresh the CLI session
