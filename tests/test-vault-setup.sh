#\!/usr/bin/env bash
# test-vault-setup.sh — Integration tests for the Vault deployment
# Verifies the full lifecycle: initialization, Terraform provisioning,
# secrets access via AppRole, KV operations, and database engine readiness.
# Requires a running Vault instance (use `make up && make init-vault` first).

set -euo pipefail

# ─── Color output helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Configuration ────────────────────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
KV_MOUNT="${KV_MOUNT:-secret}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# ─── Test framework helpers ───────────────────────────────────────────────────
test_start() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${CYAN}[TEST ${TESTS_RUN}]${NC} $1"
}

test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC} $1"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC} $1"
}

test_skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    echo -e "  ${YELLOW}SKIP${NC} $1"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        test_pass "$msg"
        return 0
    else
        test_fail "$msg (expected: '${expected}', got: '${actual}')"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-}"

    if [[ -n "$value" ]]; then
        test_pass "$msg"
        return 0
    else
        test_fail "$msg (value is empty)"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if echo "$haystack" | grep -q "$needle"; then
        test_pass "$msg"
        return 0
    else
        test_fail "$msg (expected to contain: '${needle}')"
        return 1
    fi
}

assert_http_status() {
    local url="$1"
    local expected_status="$2"
    local msg="${3:-}"
    local headers="${4:-}"

    local actual_status
    if [[ -n "$headers" ]]; then
        actual_status="$(curl -s -o /dev/null -w "%{http_code}" -H "$headers" "$url" 2>/dev/null)"
    else
        actual_status="$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)"
    fi

    assert_eq "$expected_status" "$actual_status" "$msg"
}

# ─── Prerequisite checks ─────────────────────────────────────────────────────
check_prerequisites() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN} Vault Integration Tests${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "Vault Address: ${VAULT_ADDR}"
    echo

    # Check required tools
    for cmd in curl jq; do
        if \! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}[FATAL]${NC} Required tool not found: ${cmd}"
            exit 1
        fi
    done

    # Check Vault connectivity
    if \! curl -s --max-time 5 "${VAULT_ADDR}/v1/sys/health" &>/dev/null; then
        echo -e "${RED}[FATAL]${NC} Cannot connect to Vault at ${VAULT_ADDR}"
        echo -e "Start Vault first: ${CYAN}make up && make init-vault${NC}"
        exit 1
    fi

    # Check for token
    if [[ -z "$VAULT_TOKEN" ]]; then
        echo -e "${YELLOW}[WARN]${NC} VAULT_TOKEN not set — some tests will be skipped"
    fi
}

# ─── Test: Vault Health ───────────────────────────────────────────────────────
test_vault_health() {
    test_start "Vault server is healthy and initialized"

    local health
    health="$(curl -s "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)"

    local initialized
    initialized="$(echo "$health" | jq -r '.initialized')"
    assert_eq "true" "$initialized" "Vault is initialized"

    local sealed
    sealed="$(echo "$health" | jq -r '.sealed')"
    assert_eq "false" "$sealed" "Vault is unsealed"

    local standby
    standby="$(echo "$health" | jq -r '.standby')"
    assert_eq "false" "$standby" "Vault is active (not standby)"
}

# ─── Test: Vault API is responsive ───────────────────────────────────────────
test_vault_api() {
    test_start "Vault API endpoints are accessible"

    assert_http_status "${VAULT_ADDR}/v1/sys/health" "200" \
        "Health endpoint returns 200"

    assert_http_status "${VAULT_ADDR}/v1/sys/seal-status" "200" \
        "Seal status endpoint returns 200"
}

# ─── Test: KV Secrets Engine ─────────────────────────────────────────────────
test_kv_engine() {
    test_start "KV v2 secrets engine is mounted and operational"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    # Check that KV engine is mounted
    local mounts
    mounts="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/mounts" 2>/dev/null)"

    assert_contains "$mounts" "${KV_MOUNT}/" \
        "KV secrets engine is mounted at '${KV_MOUNT}/'"

    # Write a test secret
    local test_path="test/integration-$(date +%s)"
    local write_response
    write_response="$(curl -s -o /dev/null -w "%{http_code}" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --request POST \
        --data '{"data":{"test_key":"test_value","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}}' \
        "${VAULT_ADDR}/v1/${KV_MOUNT}/data/${test_path}" 2>/dev/null)"

    assert_eq "200" "$write_response" "Can write to KV engine"

    # Read it back
    local read_data
    read_data="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/${KV_MOUNT}/data/${test_path}" 2>/dev/null \
        | jq -r '.data.data.test_key')"

    assert_eq "test_value" "$read_data" "Can read back written secret"

    # Clean up test secret
    curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --request DELETE \
        "${VAULT_ADDR}/v1/${KV_MOUNT}/metadata/${test_path}" &>/dev/null
}

# ─── Test: AppRole Auth Method ────────────────────────────────────────────────
test_approle_auth() {
    test_start "AppRole authentication method is enabled"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    # Check auth methods
    local auth_methods
    auth_methods="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/auth" 2>/dev/null)"

    assert_contains "$auth_methods" "approle/" \
        "AppRole auth method is enabled"

    # Verify AppRole endpoint is accessible
    assert_http_status "${VAULT_ADDR}/v1/auth/approle/role" "200" \
        "AppRole role list endpoint is accessible" \
        "X-Vault-Token: ${VAULT_TOKEN}"
}

# ─── Test: Vault Policies ────────────────────────────────────────────────────
test_policies() {
    test_start "Required Vault policies exist"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    local policies
    policies="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/policies/acl" 2>/dev/null \
        | jq -r '.data.keys[]' 2>/dev/null)"

    # Check for expected policies (created by Terraform)
    for policy_name in "ci-cd" "application" "admin"; do
        if echo "$policies" | grep -q "$policy_name"; then
            test_pass "Policy '${policy_name}' exists"
        else
            test_fail "Policy '${policy_name}' not found"
        fi
    done
}

# ─── Test: Database Secrets Engine ────────────────────────────────────────────
test_database_engine() {
    test_start "Database secrets engine configuration"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    # Check if database engine is mounted
    local mounts
    mounts="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/mounts" 2>/dev/null)"

    if echo "$mounts" | jq -r 'keys[]' 2>/dev/null | grep -q "database/"; then
        test_pass "Database secrets engine is mounted"

        # Check for configured roles
        local roles
        roles="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
            "${VAULT_ADDR}/v1/database/roles" 2>/dev/null \
            | jq -r '.data.keys[]' 2>/dev/null)" || true

        if [[ -n "$roles" ]]; then
            for role in "app-readonly" "app-readwrite" "migration"; do
                if echo "$roles" | grep -q "$role"; then
                    test_pass "Database role '${role}' exists"
                else
                    test_skip "Database role '${role}' not configured (requires PostgreSQL)"
                fi
            done
        else
            test_skip "No database roles configured (requires PostgreSQL connection)"
        fi
    else
        test_skip "Database secrets engine not mounted (provisioned by Terraform)"
    fi
}

# ─── Test: Kubernetes Auth ────────────────────────────────────────────────────
test_kubernetes_auth() {
    test_start "Kubernetes auth method configuration"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    local auth_methods
    auth_methods="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/auth" 2>/dev/null)"

    if echo "$auth_methods" | jq -r 'keys[]' 2>/dev/null | grep -q "kubernetes/"; then
        test_pass "Kubernetes auth method is enabled"
    else
        test_skip "Kubernetes auth not enabled (requires K8s cluster)"
    fi
}

# ─── Test: Audit Logging ─────────────────────────────────────────────────────
test_audit_config() {
    test_start "Audit device configuration"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    local audit_devices
    audit_devices="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/sys/audit" 2>/dev/null)"

    local device_count
    device_count="$(echo "$audit_devices" | jq 'keys | length' 2>/dev/null || echo 0)"

    if [[ "$device_count" -gt 0 ]]; then
        test_pass "Audit logging is enabled (${device_count} device(s))"
    else
        test_skip "No audit devices configured (recommended for production)"
    fi
}

# ─── Test: Token Self-Lookup ─────────────────────────────────────────────────
test_token_info() {
    test_start "Token authentication and self-lookup"

    if [[ -z "$VAULT_TOKEN" ]]; then
        test_skip "VAULT_TOKEN required"
        return
    fi

    local token_info
    token_info="$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/auth/token/lookup-self" 2>/dev/null)"

    local display_name
    display_name="$(echo "$token_info" | jq -r '.data.display_name // empty')"
    assert_not_empty "$display_name" "Token has a display name: ${display_name}"

    local policies
    policies="$(echo "$token_info" | jq -r '.data.policies | join(", ")' 2>/dev/null)"
    assert_contains "$policies" "root" \
        "Token has root policy (expected for integration tests)"
}

# ─── Test Summary ─────────────────────────────────────────────────────────────
print_summary() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN} Test Summary${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "  Total:   ${TESTS_RUN}"
    echo -e "  ${GREEN}Passed:  ${TESTS_PASSED}${NC}"
    [[ "$TESTS_FAILED" -gt 0 ]]  && echo -e "  ${RED}Failed:  ${TESTS_FAILED}${NC}"
    [[ "$TESTS_SKIPPED" -gt 0 ]] && echo -e "  ${YELLOW}Skipped: ${TESTS_SKIPPED}${NC}"
    echo

    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        echo -e "${RED}RESULT: FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}RESULT: PASSED${NC}"
        return 0
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    check_prerequisites

    echo
    test_vault_health
    echo
    test_vault_api
    echo
    test_kv_engine
    echo
    test_approle_auth
    echo
    test_policies
    echo
    test_database_engine
    echo
    test_kubernetes_auth
    echo
    test_audit_config
    echo
    test_token_info

    print_summary
}

main
