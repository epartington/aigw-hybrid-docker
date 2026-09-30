# `start_hooks` — Guardrail Stage

`start_hooks` is a guardrail/hook stage that runs at the very start of request processing —
before any other check, mutator, or hook. Use it for checks or header injection that need to
happen before the request is routed to a provider, rather than after the request body has
already been built and validated.

## Pipeline position

`start_hooks` is the first stage in the request pipeline:

```
start_hooks → input_guardrails → input_mutators → before_request_hooks
  → (provider call) →
output_mutators → output_guardrails → after_request_hooks
```

Because it runs before everything else, it's the right place for checks that should gate or
influence the request before any other guardrail sees it — for example, rejecting a request
type outright, or injecting a header that a later stage or the upstream provider depends on.

## Configuring it

`start_hooks` is set the same way as `before_request_hooks` / `after_request_hooks` /
`input_guardrails` — as an array on a Portkey config. It can live on:

- The per-request config (`x-portkey-config`)
- Workspace-level defaults
- Organisation-level defaults

Entries can be a guardrail slug/id, or an inline check object:

```jsonc
{
  "start_hooks": ["some-guardrail-slug"],

  // or inline:
  "start_hooks": [
    {
      "id": "start-metadata-check",
      "checks": [ /* check definitions */ ],
      "deny": true
    }
  ]
}
```

Set it as an org- or workspace-level default when you want it applied to every request in that
scope without repeating it in each individual config.

## Sync vs. async hooks

A start hook can be marked to run synchronously or asynchronously:

- **Sync** hooks block the request. They run first, before the request is routed, and can deny
  the request or mutate its headers before it goes anywhere. Use sync for checks that must gate
  the request (allow/deny decisions, required-header validation).
- **Async** hooks run in the background without adding latency to the request. They're suited to
  slower checks (e.g. an external compliance/metadata lookup) where you want the result recorded
  but don't need to block on it for every request.

Results from both are combined and returned to the caller under `hook_results.start_hooks` —
in the JSON error body on a hard deny, and as a `hook_results` event on streamed responses —
alongside `before_request_hooks` and `after_request_hooks` results.

## What a start hook can do

Start hooks run early enough to affect the outbound request itself, not just approve/deny it:

- **Deny the request.** A failing check can hard- or soft-deny the request before it's routed
  (see Denial behavior below).
- **Rewrite headers.** A start hook can modify existing request headers before the request is
  forwarded.
- **Inject headers.** A start hook can add new headers that get forwarded to the upstream
  provider — useful for stamping requests with metadata, tracing, or provider-specific headers
  that depend on a check performed at start time.

This header-injection capability is specific to `start_hooks` — it isn't available in the
`before_request_hooks` / `after_request_hooks` stages.

## Common check types

The following checks are commonly used in `start_hooks` (they're also usable in
`before_request_hooks`, with one exception noted below):

| Check | Purpose |
|---|---|
| Metadata keys check | Validates that specific keys are present (and correctly shaped) in request metadata |
| Allowed request types | Allow/deny list of request types (e.g. `chat`, `completion`, `embedding`) |
| Header check | Validates that a required set of header/value pairs is present on the request |
| Header injection/allowlist | Adds or allowlists headers to forward upstream — **only usable in `start_hooks`**, not in the other hook stages |

## Denial behavior

When a `start_hooks` check fails, the gateway responds one of two ways depending on config:

- **Hard deny**: HTTP `446`, with a JSON body:
  ```jsonc
  {
    "error": {
      "message": "The guardrail checks defined in the config failed. You can find more information in the `hook_results` object.",
      "type": "hooks_failed"
    },
    "hook_results": {
      "start_hooks": [ /* ... */ ],
      "before_request_hooks": [ /* ... */ ],
      "after_request_hooks": [ /* ... */ ]
    }
  }
  ```
- **Soft deny (200)**: for streaming requests, a synthetic assistant message is returned instead
  of an error response, with `hook_results` still attached. Use this mode when you want a
  denial to look like a normal (but flagged) completion to the calling client rather than a hard
  failure.

## How to check what's configured

There's no dedicated CLI flag or env var for `start_hooks` — it's purely config-driven. To check
whether a config already uses it:

```sh
curl -s https://api.portkey.ai/v1/configs/<config-id> \
  -H "Authorization: Bearer $PORTKEY_CLIENT_AUTH" | jq '.. | .start_hooks? // empty'
```

To confirm it's firing against this deployment, send a request with `x-portkey-config` pointing
at a config that sets `start_hooks`, then inspect the response — either the error body on a
denial, or the `hook_results.start_hooks` field on a normal response. This is the same request
pattern as the smoke test in the top-level `CLAUDE.md`; just check for `hook_results.start_hooks`
in the output.

## Notes

`start_hooks` is a newer addition to the hook pipeline and has limited coverage in Portkey's
published docs at the time of writing. Re-verify behavior (status codes, exact check
restrictions) against your deployed gateway version if it's been upgraded since this was
written.
