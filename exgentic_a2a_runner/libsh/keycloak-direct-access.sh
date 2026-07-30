#!/bin/bash
# Enable Keycloak "Direct Access Grants" (the OAuth password grant) for a client.
# deploy-agent.sh, deploy-benchmark.sh and delete-all-deployments.sh authenticate
# with grant_type=password against the rossoctl client (the default); analyze-run.sh
# does the same against the mlflow client. The password grant only works when the
# client has directAccessGrantsEnabled=true, so this helper flips that flag via the
# Keycloak admin API before the token request runs.
#
# Usage: enable_direct_access_grants [CLIENT_ID]   (CLIENT_ID defaults to "rossoctl")
#
# Must be sourced after KEYCLOAK_API is set. Master-realm admin credentials are
# resolved in priority order:
#   1. KEYCLOAK_ADMIN_USERNAME / KEYCLOAK_ADMIN_PASSWORD env vars
#   2. the keycloak-initial-admin secret (RHBK operator)
#   3. admin / admin defaults
#
# On any failure (unreachable admin API, missing client, rejected PUT) it prints a
# diagnostic and exits 1 — the password grant is a hard prerequisite for every caller.
enable_direct_access_grants() {
    local target_client="${1:-rossoctl}"
    echo "Enabling Direct Access Grants for ${target_client} client..."

    # Resolve master-realm admin credentials: prefer env vars, fall back to the
    # keycloak-initial-admin secret (RHBK operator), then defaults.
    local admin_user="${KEYCLOAK_ADMIN_USERNAME:-}"
    local admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
    if [ -z "$admin_user" ] || [ -z "$admin_pass" ]; then
        local kc_admin_user kc_admin_pass
        kc_admin_user=$("$KUBECTL_BIN" get secret keycloak-initial-admin -n keycloak \
            -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
        kc_admin_pass=$("$KUBECTL_BIN" get secret keycloak-initial-admin -n keycloak \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        admin_user="${admin_user:-${kc_admin_user:-admin}}"
        admin_pass="${admin_pass:-${kc_admin_pass:-admin}}"
    fi

    # Get master-realm admin token.
    local admin_token_response admin_token
    admin_token_response=$(curl -s -X POST "$KEYCLOAK_API/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>/dev/null) || true

    admin_token=$(echo "$admin_token_response" | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"\([^"]*\)"/\1/')
    if [ -z "$admin_token" ]; then
        echo "Error: Could not obtain master-realm admin token from Keycloak" >&2
        echo "  Response: $admin_token_response" >&2
        echo "  Set KEYCLOAK_ADMIN_PASSWORD in your .env if the master realm admin password is not 'admin'." >&2
        exit 1
    fi

    # Look up the target client's internal id.
    local client_config client_id
    client_config=$(curl -s "$KEYCLOAK_API/admin/realms/rossoctl/clients?clientId=${target_client}" \
        -H "Authorization: Bearer $admin_token" 2>/dev/null)
    client_id=$(echo "$client_config" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"\([^"]*\)"/\1/')
    if [ -z "$client_id" ]; then
        echo "Error: Could not find ${target_client} client ID in Keycloak" >&2
        echo "  Response: $client_config" >&2
        exit 1
    fi

    # Enable direct access grants (the password grant).
    local put_code
    put_code=$(curl -s -o /tmp/kc_put_response.txt -w "%{http_code}" \
        -X PUT "$KEYCLOAK_API/admin/realms/rossoctl/clients/$client_id" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d '{"directAccessGrantsEnabled": true}' 2>/dev/null) || put_code="000"
    if [ "$put_code" != "204" ] && [ "$put_code" != "200" ]; then
        echo "Error: Failed to enable direct access grants for ${target_client} client (HTTP $put_code)" >&2
        echo "  Response: $(cat /tmp/kc_put_response.txt 2>/dev/null)" >&2
        exit 1
    fi
    echo "✓ Direct access grants enabled for ${target_client} client"
}
