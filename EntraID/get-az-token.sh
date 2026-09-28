#!/bin/bash
# get-az-token.sh — apiKeyHelper for Claude Code CLI
#
# Outputs an EntraID access token to stdout; Claude Code sends it as the
# Authorization: Bearer token to the AIGW gateway.
#
# Installation:
#   cp get-az-token.sh ~/.claude/get-az-token.sh
#   chmod +x ~/.claude/get-az-token.sh
#
# Required variables (in Claude Code settings.json env block, shell env,
# or via AIGW_ENV_FILE pointing at the repo's .env):
#   ENTRAID_CLIENT_ID  — App (client) ID of the EntraID app registration
#   ENTRAID_TENANT_ID  — Entra tenant ID
#
# Optional:
#   ENTRAID_RESOURCE_URI — App ID URI to request a token for
#                          (defaults to api://<ENTRAID_CLIENT_ID>)
#                          The app registration must expose an API with this URI.
#   AIGW_ENV_FILE        — absolute path to a .env file to load vars from
#                          (defaults to .env in the same directory as this script)

set -euo pipefail

# ── Resolve env file ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AIGW_ENV_FILE:-${SCRIPT_DIR}/.env}"

# ── Load ENTRAID vars from env or .env ────────────────────────────────────────
ENTRAID_CLIENT_ID_VALUE="${ENTRAID_CLIENT_ID:-}"
ENTRAID_TENANT_ID_VALUE="${ENTRAID_TENANT_ID:-}"

if [ -z "$ENTRAID_CLIENT_ID_VALUE" ] || [ -z "$ENTRAID_TENANT_ID_VALUE" ]; then
    if [ -f "$ENV_FILE" ]; then
        if [ -z "$ENTRAID_CLIENT_ID_VALUE" ]; then
            ENTRAID_CLIENT_ID_VALUE=$(grep "^ENTRAID_CLIENT_ID=" "$ENV_FILE" 2>/dev/null \
                | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
        fi
        if [ -z "$ENTRAID_TENANT_ID_VALUE" ]; then
            ENTRAID_TENANT_ID_VALUE=$(grep "^ENTRAID_TENANT_ID=" "$ENV_FILE" 2>/dev/null \
                | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
        fi
    fi
fi

if [ -z "$ENTRAID_CLIENT_ID_VALUE" ]; then
    echo "Error: ENTRAID_CLIENT_ID not set. Add it to .env, export it, or set AIGW_ENV_FILE." >&2
    exit 1
fi
if [ -z "$ENTRAID_TENANT_ID_VALUE" ]; then
    echo "Error: ENTRAID_TENANT_ID not set. Add it to .env, export it, or set AIGW_ENV_FILE." >&2
    exit 1
fi

# ── Resolve resource URI ───────────────────────────────────────────────────────
# Use the bare client GUID (not api://<client-id>): acceptMappedClaims requires
# the audience to match the application GUID (AADSTS501461 otherwise).
# The app registration must expose an API and pre-authorize the Azure CLI app
# (04b07795-8ddb-461a-bbee-02f9e1bf7b46) on all scopes — see the setup guide.
RESOURCE_URI="${ENTRAID_RESOURCE_URI:-${ENTRAID_CLIENT_ID_VALUE}}"

# ── Try to get a token silently from the Azure CLI cache ──────────────────────
JWT_TOKEN=$(az account get-access-token \
    --resource "$RESOURCE_URI" \
    --tenant  "$ENTRAID_TENANT_ID_VALUE" \
    --query   "accessToken" \
    -o tsv 2>/dev/null) || JWT_TOKEN=""

# ── If expired or not logged in, trigger interactive browser login ─────────────
if [ -z "$JWT_TOKEN" ]; then
    echo "EntraID session expired or not logged in. Launching browser for login..." >/dev/tty
    # Include the resource scope so the consent prompt fires if not already granted
    az login \
        --tenant "$ENTRAID_TENANT_ID_VALUE" \
        --scope "${RESOURCE_URI}/.default" \
        --allow-no-subscriptions >/dev/tty 2>&1

    JWT_TOKEN=$(az account get-access-token \
        --resource "$RESOURCE_URI" \
        --tenant  "$ENTRAID_TENANT_ID_VALUE" \
        --query   "accessToken" \
        -o tsv 2>/dev/null) || JWT_TOKEN=""
fi

if [ -z "$JWT_TOKEN" ]; then
    echo "Error: Failed to obtain a token from Microsoft EntraID." >&2
    exit 1
fi

# Output ONLY the token — Claude Code reads this as the bearer token
echo "$JWT_TOKEN"
