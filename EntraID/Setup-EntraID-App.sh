#!/bin/bash
set -euo pipefail

SUMMARY_ITEMS=()
CERT_INFO_CREATED=false
EXISTING_POLICY_ID=""
UPDATE_EXISTING_POLICY=false

# ── Load ENTRAID_CLIENT_ID / ENTRAID_TENANT_ID from env or .env ───────────────
ENTRAID_CLIENT_ID_VALUE="${ENTRAID_CLIENT_ID:-}"
ENTRAID_TENANT_ID_VALUE="${ENTRAID_TENANT_ID:-}"
if [ -f ".env" ]; then
    if [ -z "$ENTRAID_CLIENT_ID_VALUE" ]; then
        ENTRAID_CLIENT_ID_VALUE=$(grep "^ENTRAID_CLIENT_ID=" ".env" 2>/dev/null \
            | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
    fi
    if [ -z "$ENTRAID_TENANT_ID_VALUE" ]; then
        ENTRAID_TENANT_ID_VALUE=$(grep "^ENTRAID_TENANT_ID=" ".env" 2>/dev/null \
            | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'") || true
    fi
fi

# ── Helper: upsert a key=value in .env ────────────────────────────────────────
upsert_env() {
    local key="$1" value="$2"
    python3 - "$key" "$value" << 'PYEOF'
import sys, os, re
key, value = sys.argv[1], sys.argv[2]
env_file = '.env'
lines = open(env_file).readlines() if os.path.exists(env_file) else []
pattern = re.compile(f'^{re.escape(key)}=')
updated = [f'{key}={value}\n' if pattern.match(l) else l for l in lines]
if not any(pattern.match(l) for l in lines):
    updated.append(f'{key}={value}\n')
with open(env_file, 'w') as f:
    f.writelines(updated)
print(f"  {key} written to .env")
PYEOF
}

echo "========================================"
echo "  Portkey EntraID Claims Policy Setup   "
echo "========================================"
echo ""

# ─── STEP 1: Azure Login ───────────────────────────────────────────────────────
echo "STEP 1: Azure Login"
echo "─────────────────────"
read -rp "Do you have an Azure subscription? [y/N]: " has_subscription

if [[ "$has_subscription" =~ ^[Yy] ]]; then
    az login
else
    az login --allow-no-subscriptions
fi

echo ""
echo "Login complete."
echo ""

# ─── STEP 2: EntraID App Registration ─────────────────────────────────────────
echo "STEP 2: EntraID App Registration"
echo "──────────────────────────────────"
read -rp "Have you already created an EntraID App registration? [y/N]: " has_existing_app

APP_CLIENT_ID=""
APP_OBJECT_ID=""
TENANT_ID=""
APP_DISPLAY_NAME=""

if [[ "$has_existing_app" =~ ^[Yy] ]]; then
    # ── Use existing app ───────────────────────────────────────────────────────
    if [ -n "$ENTRAID_CLIENT_ID_VALUE" ]; then
        read -rp "Enter the App (Client) ID [$ENTRAID_CLIENT_ID_VALUE]: " _input
        APP_CLIENT_ID="${_input:-$ENTRAID_CLIENT_ID_VALUE}"
    else
        read -rp "Enter the App (Client) ID: " APP_CLIENT_ID
    fi

    if [ -n "$ENTRAID_TENANT_ID_VALUE" ]; then
        read -rp "Enter the Tenant ID [$ENTRAID_TENANT_ID_VALUE]:       " _input
        TENANT_ID="${_input:-$ENTRAID_TENANT_ID_VALUE}"
    else
        read -rp "Enter the Tenant ID:       " TENANT_ID
    fi

    echo ""
    echo "Looking up app registration..."
    APP_OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query "id" -o tsv)
    echo "Found app object ID: $APP_OBJECT_ID"

else
    # ── Create a new app ───────────────────────────────────────────────────────
    echo ""
    read -rp "Display name for the new app:                          " APP_DISPLAY_NAME

    echo ""
    echo "What type of application is this?"
    echo "  1) API         (server-to-server / client credentials)"
    echo "  2) Web         (server-side web app with redirect URI)"
    echo "  3) Desktop     (native / mobile / public client)"
    read -rp "Enter choice [1/2/3]: " app_type_choice

    REDIRECT_URI=""
    case "$app_type_choice" in
        1)
            read -rp "Redirect URI (leave blank if not needed for API): " REDIRECT_URI ;;
        2|3)
            read -rp "Callback / redirect URI: " REDIRECT_URI ;;
        *)
            echo "Invalid choice. Exiting."; exit 1 ;;
    esac

    # Resolve tenant
    TENANT_ID=$(az account show --query "tenantId" -o tsv 2>/dev/null || \
        az rest --method GET \
            --uri "https://graph.microsoft.com/v1.0/organization" \
            --query "value[0].id" -o tsv)

    echo ""
    echo "Creating app registration: '$APP_DISPLAY_NAME' ..."

    case "$app_type_choice" in
        1)  # API — no public redirect; expose user_impersonation scope
            CREATE_RESULT=$(az ad app create \
                --display-name "$APP_DISPLAY_NAME" \
                --sign-in-audience "AzureADMyOrg" \
                -o json)
            APP_OBJECT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
            APP_CLIENT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")

            SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
            API_PATCH_BODY=$(python3 -c "
import json, sys
scope = {
    'id': '${SCOPE_ID}',
    'adminConsentDescription': 'Allow the application to access ${APP_DISPLAY_NAME} on behalf of the signed-in user.',
    'adminConsentDisplayName': 'Access ${APP_DISPLAY_NAME}',
    'isEnabled': True,
    'type': 'User',
    'userConsentDescription': 'Allow the application to access ${APP_DISPLAY_NAME} on your behalf.',
    'userConsentDisplayName': 'Access ${APP_DISPLAY_NAME}',
    'value': 'user_impersonation'
}
print(json.dumps({'api': {'oauth2PermissionScopes': [scope]}}))
")
            az rest --method PATCH \
                --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
                --headers "Content-Type=application/json" \
                --body "$API_PATCH_BODY"

            if [ -n "$REDIRECT_URI" ]; then
                az rest --method PATCH \
                    --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
                    --headers "Content-Type=application/json" \
                    --body "{\"web\":{\"redirectUris\":[\"$REDIRECT_URI\"]}}"
            fi
            ;;

        2)  # Web app
            CREATE_RESULT=$(az ad app create \
                --display-name "$APP_DISPLAY_NAME" \
                --sign-in-audience "AzureADMyOrg" \
                --web-redirect-uris "$REDIRECT_URI" \
                -o json)
            APP_OBJECT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
            APP_CLIENT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")
            ;;

        3)  # Desktop / native / mobile
            CREATE_RESULT=$(az ad app create \
                --display-name "$APP_DISPLAY_NAME" \
                --sign-in-audience "AzureADMyOrg" \
                --public-client-redirect-uris "$REDIRECT_URI" \
                -o json)
            APP_OBJECT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
            APP_CLIENT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")
            ;;
    esac

    # ── Expose an API on the app (required for az account get-access-token) ───
    # Without an App ID URI and at least one scope the Azure CLI cannot request
    # an access token for this app as a resource (AADSTS650057).
    echo ""
    echo "Setting App ID URI and exposing user_impersonation scope..."
    EXPOSE_API_BODY=$(APP_CLIENT_ID="$APP_CLIENT_ID" python3 << 'PYEOF'
import json, os, uuid
client_id = os.environ['APP_CLIENT_ID']
scope = {
    'id': str(uuid.uuid4()),
    'adminConsentDescription': 'Access the AIGW gateway on behalf of the signed-in user.',
    'adminConsentDisplayName': 'Access AIGW gateway',
    'isEnabled': True,
    'type': 'User',
    'userConsentDescription': 'Access the AIGW gateway on your behalf.',
    'userConsentDisplayName': 'Access AIGW gateway',
    'value': 'user_impersonation'
}
print(json.dumps({
    'identifierUris': [f'api://{client_id}'],
    'api': {'oauth2PermissionScopes': [scope]}
}))
PYEOF
)
    az rest --method PATCH \
        --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
        --headers "Content-Type=application/json" \
        --body "$EXPOSE_API_BODY"
    echo "App ID URI set to api://$APP_CLIENT_ID"
    SUMMARY_ITEMS+=("App ID URI:       api://$APP_CLIENT_ID")

    # ── Pre-authorize Azure CLI so get-az-token.sh works without consent prompt ─
    # acceptMappedClaims requires the bare GUID as resource audience; pre-auth
    # bypasses the client-registration check that causes AADSTS650057/65001.
    echo ""
    echo "Pre-authorizing Azure CLI (04b07795-...) for all exposed scopes..."
    SCOPE_IDS=$(az rest --method GET \
        --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
        --query "api.oauth2PermissionScopes[].id" -o json)
    PREAUTH_BODY=$(echo "$SCOPE_IDS" | python3 -c "
import json, sys
ids = json.load(sys.stdin)
print(json.dumps({'api': {'preAuthorizedApplications': [{'appId': '04b07795-8ddb-461a-bbee-02f9e1bf7b46', 'delegatedPermissionIds': ids}]}}))
")
    az rest --method PATCH \
        --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
        --headers "Content-Type=application/json" \
        --body "$PREAUTH_BODY"
    echo "Azure CLI pre-authorized."
    SUMMARY_ITEMS+=("Azure CLI pre-auth: 04b07795-8ddb-461a-bbee-02f9e1bf7b46")

    echo "App created — Client ID: $APP_CLIENT_ID"
    SUMMARY_ITEMS+=("App (Client) ID:  $APP_CLIENT_ID")
    SUMMARY_ITEMS+=("App Object ID:    $APP_OBJECT_ID")
    SUMMARY_ITEMS+=("Tenant ID:        $TENANT_ID")

    # ── Create self-signed client certificate ──────────────────────────────────
    echo ""
    echo "Creating self-signed client certificate (1-year validity)..."

    CERT_SLUG="${APP_DISPLAY_NAME// /-}"
    CERT_PEM="${CERT_SLUG}.pem"
    CERT_KEY="${CERT_SLUG}.key"
    CERT_PFX="${CERT_SLUG}.pfx"

    openssl req -x509 \
        -newkey rsa:2048 \
        -keyout "$CERT_KEY" \
        -out  "$CERT_PEM" \
        -days 365 \
        -nodes \
        -subj "/CN=${APP_DISPLAY_NAME}" \
        2>/dev/null

    CERT_THUMBPRINT=$(openssl x509 -in "$CERT_PEM" -fingerprint -sha1 -noout \
        | sed 's/SHA1 Fingerprint=//' | tr -d ':')
    CERT_EXPIRY=$(openssl x509 -in "$CERT_PEM" -noout -enddate | cut -d= -f2)

    openssl pkcs12 -export \
        -out     "$CERT_PFX" \
        -inkey   "$CERT_KEY" \
        -in      "$CERT_PEM" \
        -passout pass: \
        2>/dev/null

    echo "Uploading certificate to app registration..."
    az ad app credential reset \
        --id    "$APP_CLIENT_ID" \
        --cert  "@${CERT_PEM}" \
        --append \
        --years 1 \
        --output none

    CERT_INFO_CREATED=true
    SUMMARY_ITEMS+=("Certificate PEM:  $(pwd)/${CERT_PEM}")
    SUMMARY_ITEMS+=("Certificate KEY:  $(pwd)/${CERT_KEY}  (keep secret)")
    SUMMARY_ITEMS+=("Certificate PFX:  $(pwd)/${CERT_PFX}  (empty password)")
    SUMMARY_ITEMS+=("Cert Thumbprint:  $CERT_THUMBPRINT")
    SUMMARY_ITEMS+=("Cert Expiry:      $CERT_EXPIRY")

    # ── Add optional ID-token claims to app manifest ───────────────────────────
    echo ""
    echo "Adding optional ID-token claims: upn, email, preferred_username ..."
    az rest --method PATCH \
        --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
        --headers "Content-Type=application/json" \
        --body '{
            "optionalClaims": {
                "idToken": [
                    {"name": "upn",                "essential": false},
                    {"name": "email",              "essential": false},
                    {"name": "preferred_username", "essential": false}
                ]
            }
        }'
    echo "Optional ID-token claims added."

    # ── Offer to update .env with ENTRAID_CLIENT_ID / ENTRAID_TENANT_ID ──────
    echo ""
    read -rp "Update .env with ENTRAID_CLIENT_ID and ENTRAID_TENANT_ID? [Y/n]: " _update_env
    if [[ ! "$_update_env" =~ ^[Nn] ]]; then
        upsert_env "ENTRAID_CLIENT_ID" "$APP_CLIENT_ID"
        upsert_env "ENTRAID_TENANT_ID" "$TENANT_ID"
    fi
fi

# ── Ensure service principal exists ───────────────────────────────────────────
echo ""
echo "Resolving service principal..."
SERVICE_PRINCIPAL_ID=$(az ad sp show --id "$APP_CLIENT_ID" --query "id" -o tsv 2>/dev/null) || SERVICE_PRINCIPAL_ID=""

if [ -z "$SERVICE_PRINCIPAL_ID" ]; then
    echo "No service principal found — creating one..."
    SERVICE_PRINCIPAL_ID=$(az ad sp create --id "$APP_CLIENT_ID" --query "id" -o tsv)
fi
echo "Service Principal ID: $SERVICE_PRINCIPAL_ID"

# ── Check for existing Claims Mapping Policy (existing app only) ───────────────
if [[ "$has_existing_app" =~ ^[Yy] ]]; then
    echo ""
    echo "Checking for an existing Claims Mapping Policy on this service principal..."
    EXISTING_POLICIES=$(az rest --method GET \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SERVICE_PRINCIPAL_ID/claimsMappingPolicies" \
        2>/dev/null) || EXISTING_POLICIES='{"value":[]}'

    EXISTING_POLICY_COUNT=$(echo "$EXISTING_POLICIES" | python3 -c \
        "import sys,json; print(len(json.load(sys.stdin).get('value',[])))" 2>/dev/null) || EXISTING_POLICY_COUNT=0

    if [ "$EXISTING_POLICY_COUNT" -gt 0 ]; then
        echo ""
        echo "  Found $EXISTING_POLICY_COUNT existing policy:"
        echo ""

        EXISTING_POLICIES_JSON="$EXISTING_POLICIES" python3 << 'PYEOF'
import json, os

data = json.loads(os.environ['EXISTING_POLICIES_JSON'])
for p in data.get('value', []):
    print(f"  Name : {p.get('displayName', '(unnamed)')}")
    print(f"  ID   : {p.get('id', '')}")
    try:
        defn   = json.loads(p['definition'][0])
        policy = defn.get('ClaimsMappingPolicy', {})
        print(f"  IncludeBasicClaimSet: {policy.get('IncludeBasicClaimSet', 'false')}")
        print("  Claims:")
        for c in policy.get('ClaimsSchema', []):
            jwt = c.get('JwtClaimType', '')
            src = c.get('Source', '')
            cid = c.get('ID', '')
            val = c.get('Value', '')
            if src and cid:
                print(f"    {jwt:<22} <- {src}.{cid}")
            elif val:
                print(f"    {jwt:<22} = \"{val}\"")
    except Exception as e:
        print(f"  (could not parse definition: {e})")
    print()
PYEOF

        EXISTING_POLICY_ID=$(echo "$EXISTING_POLICIES" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d['value'][0].get('id',''))" 2>/dev/null) || EXISTING_POLICY_ID=""

        read -rp "Do you want to update this policy? [y/N]: " update_existing
        if [[ "$update_existing" =~ ^[Yy] ]]; then
            UPDATE_EXISTING_POLICY=true
            echo "Will update existing policy ID: $EXISTING_POLICY_ID"
        else
            echo "No changes made to existing policy. Exiting."
            exit 0
        fi
    else
        echo "No existing Claims Mapping Policy found — a new one will be created."
    fi
fi

# ─── STEP 3: Claims Mapping Policy ────────────────────────────────────────────
echo ""
echo "STEP 3: Claims Mapping Policy"
echo "───────────────────────────────"
echo "Select which claims to include (y/n for each):"
echo ""
echo "  Base claims always included:"
echo "    uid         — onPremisesSamAccountName"
echo "    mailnickname— user's mail nickname"
echo "    scope       — 'completions.write mcp.invoke'"
echo ""
echo "  Optional claims:"

read -rp "  [ ] email_id   — user email address (from mail)? [y/N]: "    claim_email_id
read -rp "  [ ] _user      — username (from mailnickname)? [y/N]: "       claim_user
read -rp "  [ ] department — user's department? [y/N]: "                  claim_department

# Load ORGANISATIONS_TO_SYNC from environment or .env
PORTKEY_OID_VALUE="${ORGANISATIONS_TO_SYNC:-}"
if [ -z "$PORTKEY_OID_VALUE" ] && [ -f ".env" ]; then
    PORTKEY_OID_VALUE=$(grep "^ORGANISATIONS_TO_SYNC=" ".env" 2>/dev/null \
        | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'") || PORTKEY_OID_VALUE=""
fi

if [ -n "$PORTKEY_OID_VALUE" ]; then
    read -rp "  [ ] portkey_oid       — organisation ID ($PORTKEY_OID_VALUE, from ORGANISATIONS_TO_SYNC)? [y/N]: " claim_portkey_oid
else
    read -rp "  [ ] portkey_oid       — organisation ID (static value)? [y/N]: " claim_portkey_oid
    if [[ "$claim_portkey_oid" =~ ^[Yy] ]]; then
        read -rp "      Enter the portkey_oid value: " PORTKEY_OID_VALUE
    fi
fi

PORTKEY_WORKSPACE_VALUE=""
PORTKEY_WORKSPACE_EXT_ATTR=""
read -rp "  [ ] portkey_workspace — Portkey workspace slug? [y/N]: " claim_portkey_workspace
if [[ "$claim_portkey_workspace" =~ ^[Yy] ]]; then
    echo ""
    echo "      How should portkey_workspace be sourced?"
    echo "        1) Static value        — same workspace for every user"
    echo "        2) Extension attribute — per-user value stored in extensionAttribute1-15"
    echo ""
    echo "      Option 2 lets different users (or groups via AD write-back) land"
    echo "      in different workspaces. Set the workspace slug on each user's"
    echo "      extensionAttribute<N> in Entra / on-prem AD before using this option."
    echo ""
    read -rp "      Enter choice [1/2]: " workspace_source_choice
    case "$workspace_source_choice" in
        1)
            read -rp "      Workspace slug (e.g. ws-main-a-123456): " PORTKEY_WORKSPACE_VALUE
            ;;
        2)
            read -rp "      Which extensionAttribute number? [1-15]: " PORTKEY_WORKSPACE_ATTR_NUM
            PORTKEY_WORKSPACE_EXT_ATTR="extensionattribute${PORTKEY_WORKSPACE_ATTR_NUM}"
            echo "      Will source portkey_workspace from user.${PORTKEY_WORKSPACE_EXT_ATTR}"
            ;;
        *)
            echo "      Invalid choice — skipping portkey_workspace."
            claim_portkey_workspace="n"
            ;;
    esac
fi

# ── Derive a policy display name ───────────────────────────────────────────────
if [ -n "$APP_DISPLAY_NAME" ]; then
    POLICY_DISPLAY_NAME="${APP_DISPLAY_NAME// /}ClaimsMappingPolicy"
else
    # Sanitise the client ID for use as a name (strip hyphens)
    POLICY_DISPLAY_NAME="${APP_CLIENT_ID//-/}ClaimsMappingPolicy"
fi

# ── Build the policy JSON via Python ──────────────────────────────────────────
POLICY_BODY=$(CLAIM_EMAIL_ID="$claim_email_id" \
    CLAIM_USER="$claim_user" \
    CLAIM_DEPT="$claim_department" \
    CLAIM_PORTKEY_OID="$claim_portkey_oid" \
    PORTKEY_OID_VALUE="$PORTKEY_OID_VALUE" \
    CLAIM_PORTKEY_WORKSPACE="$claim_portkey_workspace" \
    PORTKEY_WORKSPACE_VALUE="$PORTKEY_WORKSPACE_VALUE" \
    PORTKEY_WORKSPACE_EXT_ATTR="$PORTKEY_WORKSPACE_EXT_ATTR" \
    POLICY_DISPLAY_NAME="$POLICY_DISPLAY_NAME" \
    python3 << 'PYEOF'
import json, os

def yn(v):
    return v.strip().lower().startswith('y')

claims = [
    {"Source": "user", "ID": "onpremisessamaccountname", "JwtClaimType": "uid"},
    {"Source": "user", "ID": "mailnickname",             "JwtClaimType": "mailnickname"},
    {"Value": "completions.write mcp.invoke",            "JwtClaimType": "scope"},
]

if yn(os.environ.get('CLAIM_EMAIL_ID', '')):
    claims.append({"Source": "user", "ID": "mail",        "JwtClaimType": "email_id"})

if yn(os.environ.get('CLAIM_USER', '')):
    claims.append({"Source": "user", "ID": "mailnickname","JwtClaimType": "_user"})

if yn(os.environ.get('CLAIM_DEPT', '')):
    claims.append({"Source": "user", "ID": "department",  "JwtClaimType": "department"})

oid_val = os.environ.get('PORTKEY_OID_VALUE', '')
if yn(os.environ.get('CLAIM_PORTKEY_OID', '')) and oid_val:
    claims.append({"Value": oid_val, "JwtClaimType": "portkey_oid"})

ws_ext  = os.environ.get('PORTKEY_WORKSPACE_EXT_ATTR', '')
ws_val  = os.environ.get('PORTKEY_WORKSPACE_VALUE', '')
if yn(os.environ.get('CLAIM_PORTKEY_WORKSPACE', '')):
    if ws_ext:
        claims.append({"Source": "user", "ID": ws_ext,  "JwtClaimType": "portkey_workspace"})
    elif ws_val:
        claims.append({"Value": ws_val,                  "JwtClaimType": "portkey_workspace"})

inner = json.dumps({
    "ClaimsMappingPolicy": {
        "Version": 1,
        "IncludeBasicClaimSet": "true",
        "ClaimsSchema": claims
    }
})

outer = {
    "definition":   [inner],
    "displayName":  os.environ.get('POLICY_DISPLAY_NAME', 'ClaimsMappingPolicy'),
    "type":         "ClaimsMappingPolicy"
}

print(json.dumps(outer))
PYEOF
)

# ── Create or update the policy ────────────────────────────────────────────────
echo ""
POLICY_ID=""

if [ "$UPDATE_EXISTING_POLICY" = true ]; then
    echo "Updating Claims Mapping Policy: '$EXISTING_POLICY_ID' ..."
    az rest --method PATCH \
        --uri "https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies/$EXISTING_POLICY_ID" \
        --headers "Content-Type=application/json" \
        --body "$POLICY_BODY"
    POLICY_ID="$EXISTING_POLICY_ID"
    echo "Policy updated — ID: $POLICY_ID"
else
    echo "Creating Claims Mapping Policy: '$POLICY_DISPLAY_NAME' ..."
    POLICY_RESPONSE=$(az rest --method POST \
        --uri "https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies" \
        --headers "Content-Type=application/json" \
        --body "$POLICY_BODY" 2>&1)

    POLICY_ID=$(echo "$POLICY_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null) || POLICY_ID=""

    if [ -z "$POLICY_ID" ]; then
        echo "Error: Failed to create the claims mapping policy."
        echo "Response: $POLICY_RESPONSE"
        exit 1
    fi
    echo "Policy created — ID: $POLICY_ID"
fi

SUMMARY_ITEMS+=("Claims Policy ID: $POLICY_ID")

# ── Enable acceptMappedClaims and set token version to v2 ─────────────────────
echo ""
echo "Enabling acceptMappedClaims and setting token version to v2..."
az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
    --headers "Content-Type=application/json" \
    --body '{"api": {"acceptMappedClaims": true, "requestedAccessTokenVersion": 2}}'
echo "acceptMappedClaims enabled; token version set to v2."

# ── Assign policy to service principal (new policies only) ────────────────────
if [ "$UPDATE_EXISTING_POLICY" = false ]; then
    echo ""
    echo "Assigning policy to service principal..."
    az rest --method POST \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SERVICE_PRINCIPAL_ID/claimsMappingPolicies/\$ref" \
        --headers "Content-Type=application/json" \
        --body "{\"@odata.id\": \"https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies/$POLICY_ID\"}"
    echo "Policy assigned."
fi

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Setup Complete"
echo "========================================"
echo "  Service Principal ID: $SERVICE_PRINCIPAL_ID"
for item in "${SUMMARY_ITEMS[@]}"; do
    echo "  $item"
done

if [ "$CERT_INFO_CREATED" = true ]; then
    echo ""
    echo "  IMPORTANT: Certificate files written to the current directory."
    echo "  Do not commit .pem / .key / .pfx files — add them to .gitignore."
fi

echo ""
echo "  To update the policy in future, run:"
echo "    az rest --method PATCH \\"
echo "        --uri \"https://graph.microsoft.com/v1.0/policies/claimsMappingPolicies/$POLICY_ID\" \\"
echo "        --headers \"Content-Type=application/json\" \\"
echo "        --body '<updated-policy-body>'"
echo ""
