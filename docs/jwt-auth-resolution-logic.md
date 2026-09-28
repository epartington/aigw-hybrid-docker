# JWT Local Auth — Gateway Resolution Logic

This documents exactly what the `aigw-gateway` container does when a request arrives with
`Authorization: Bearer <JWT>` instead of `x-portkey-api-key`. 

See [jwt-auth-flow.excalidraw](images/jwt-auth-flow.excalidraw) for a flowchart of the same logic —
open it at [excalidraw.com](https://excalidraw.com) (File → Open) or with the Excalidraw VS Code
extension. A rendered version is below:

![JWT auth resolution flowchart](images/jwt-auth-flow.svg)

## When JWT local auth kicks in

The auth middleware picks a bearer token from `x-portkey-api-key` first, falling back to
`Authorization: Bearer <token>`. It then checks the token's *shape*, not its claims: if it's a
three-part, base64url-looking string (`header.payload.signature`), it's treated as a JWT and
routed through local JWT auth. Otherwise it's looked up as a plain API key. This is why a real
API key and a JWT can both be sent as `Authorization: Bearer ...` and still be handled
correctly — the gateway is sniffing the format, not the header name.

If `JWT_ENABLED` is not `"ON"`, JWT local auth is skipped entirely and the token falls through
to (and fails) normal API-key lookup.

## Step-by-step resolution

1. **Extract identity claims** via a helper that reads, in priority order:
   `email_id → email → preferred_username → upn → unique_name`. The result is lowercased and
   must look like an email address (`user@domain`) or it's discarded. A `uniqueId` is derived
   from the local part of that email, or falls back to `sub`/`uid` if no email-shaped claim was
   found.

2. **Resolve the organisation.** Org id comes from `portkey_oid` or `organisation_id` in the
   token. If neither is present, the gateway falls back to `ORGANISATIONS_TO_SYNC` **only if**
   it contains exactly one org (comma-split length 1) — with multiple orgs configured, a token
   missing `portkey_oid` is rejected outright:
   `401 "Organisation ID not found in token (portkey_oid / organisation_id) and no single
   ORGANISATIONS_TO_SYNC configured"`.
   If an org id *is* found, it's still checked against `ORGANISATIONS_TO_SYNC` (comma-separated
   allowlist) — a mismatch is `403 "JWT org <id> not allowed for this gateway"`.

3. **Fetch org details** (via for Management plane) to get  JWKS URL or JSON . Missing both → `403 "No JWKS configured for this org"`. 

4. **Cryptographically verify the JWT** against that org's JWKS. This is the first point real
   signature/issuer validation happens — everything before this only read claims off an
   unverified token. A token signed by the wrong tenant, or a JWKS URL pointing at the wrong
   tenant, fails here with `401 "JWT verification failed: ..."`.

5. **Re-extract claims from the *verified* payload**: `workspace_slug`, `portkey_workspace`,
   `sub`, `exp`, `scope`/`scopes`, `usage_limits`, `rate_limits`, `defaults`, and the
   email/uniqueId pair again (step 2, but from the trusted payload this time).

6. **Resolve the workspace slug**, in priority order:
   - `portkey_workspace` claim, else
   - `workspace_slug` claim, else
   - the `x-portkey-workspace` header — **but only if** the token resolved an email *and*
     neither of the above claims was present. A workspace claim on the token always wins over
     the header hint.
   - if still unresolved, falls through to the org's `default_workspace.slug` (step 9).

7. **Apply deployment-level restrictions.** The gateway fetches this self-hosted deployment's
   registration and enforces, if configured:
   - `jwt_subs_allowed` — an allowlist of `sub` claims; a token with a `sub` not on the list is
     rejected (`403`).
   - `jwt_sub_workspace_mapping` — maps specific `sub` values to a workspace slug, used only if
     no workspace was already resolved in step 7.
   - if the deployment does **not** `allow_all_workspaces`, it must declare a `workspaces` list;
     if no workspace was resolved yet, the *first* entry in that list becomes the default.

8. **Membership check by email (this is the part the user asked about).** If step 1/5 resolved
   an email address, the gateway calls SCM Managment
   - If a workspace was already resolved (from claims/header/deployment mapping) and this user
     is **not** a member of it → `403 "User is not a member of the resolved workspace <slug>"`.
   - Otherwise, the workspace slug returned by this lookup **overrides** whatever was resolved
     so far — i.e., for a token that carries an email but no explicit `portkey_workspace`
     claim, the user's actual workspace membership (as recorded in SCM via SCIM) is what ultimately
     decides the workspace, not the `x-portkey-workspace` hint or deployment defaults.
   - If no email was resolved at all, this step is skipped and the request is authenticated as
     a **workspace-service** identity rather than a **workspace-user** identity (see step 10).

9. **No workspace resolved anywhere?** Falls back to the org's own `default_workspace.slug`,
    then re-fetches workspace details for whatever slug won. If that also fails to resolve →
    `403 "No workspace could be resolved for this token"`. If the deployment restricts
    workspaces and the final slug isn't in its allowed list → `403 "Workspace access forbidden
    for this deployment"`.

10. **Build the effective identity.** Scopes are the **union** of the token's own
    `scope`/`scopes` claim and `JWT_LOCAL_AUTH_DEFAULT_SCOPES` (not a replacement — both apply).
    Empty scopes after the union → `403 "No valid scopes in JWT token"`. The resulting synthetic
    "API key" identity is typed `WORKSPACE_USER` (email resolved to a member) or
    `WORKSPACE_SERVICE` (no email resolvable), tagged `auth_type: "JWT"`, and carries
    `config_id`/`config_slug` from the token's `defaults` claim or the workspace's
    `defaults.user_api_key_config` if the token didn't specify one. This identity is cached
    (up to 7 days, capped by the token's `exp`) so subsequent requests with the same token skip
    steps 3–10.

## Practical takeaways

- **`email_id` (or `email`/`upn`/`preferred_username`) is the load-bearing claim for
  per-user workspace resolution**, exactly as observed: the gateway looks the email up via
  `/v2/users/details`, and if that user is a member of a workspace, that membership wins over
  everything else once no explicit `portkey_workspace` claim is present. This matches
  `docs/aigw-entraid-claude-jwt-auth.md`'s claims-mapping guidance.
- **`JWT_LOCAL_AUTH_DEFAULT_WORKSPACE` and `JWT_LOCAL_AUTH_WORKSPACE_ALLOWLIST`, as set in
  [docker-compose.yml](../docker-compose.yml), are not referenced anywhere in this gateway
  build.** They were grepped for directly in the bundled source and don't appear — only
  `JWT_LOCAL_AUTH_DEFAULT_SCOPES` is real. Treat those two env vars as inert on this image
  version; don't rely on them to pin a workspace. If you need a fixed workspace regardless of
  membership, use `x-portkey-workspace` (works only when the token has no `portkey_workspace`/
  `workspace_slug` claim of its own and does resolve an email) or set the workspace via the
  Claims Mapping Policy (`portkey_workspace`) instead, per
  `docs/aigw-entraid-claude-jwt-auth.md`.
- **A token missing `email_id`/`upn`/etc. entirely** (e.g. a bare `az account get-access-token`
  ARM token) still authenticates as a `WORKSPACE_SERVICE` identity as long as `portkey_oid` (or
  a single `ORGANISATIONS_TO_SYNC`) and a resolvable workspace are present — it just never goes
  through the per-user membership check in step 9, so `x-portkey-workspace` and deployment
  defaults are what decide its workspace, not email membership. Downstream provider/config
  errors like `Following keys are not valid: vertex` happen *after* this resolution succeeds —
  they mean the identity landed in a workspace/org context that doesn't have that provider
  bound, not that JWT auth itself failed.
- **Provider/JWKS tenant mismatches surface late.** Steps 1–4 only read claims off the
  unverified token, so a token from the wrong tenant will get all the way to step 5 (signature
  verification against the org's configured `jwks_url`) before failing — check
  `airs aigateway organisations auth-settings get --tsg-id <tsg>` against the token's `tid`/
  `iss` if you see `JWT verification failed`.
