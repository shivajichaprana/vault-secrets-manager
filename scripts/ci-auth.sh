#\!/usr/bin/env bash
# ci-auth.sh — CI/CD pipeline Vault authentication via AppRole
# Authenticates to Vault using AppRole credentials, retrieves secrets,
# and exports them as environment variables for use in CI pipelines
# (GitHub Actions, Jenkins, GitLab CI, etc.)

set -euo pipefail

# ─── Color output helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Configuration ────────────────────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_ROLE_ID="${VAULT_ROLE_ID:-}"
VAULT_SECRET_ID="${VAULT_SECRET_ID:-}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
SECRET_PATHS="${SECRET_PATHS:-}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-env}"     # env | github | json | gitlab
KV_MOUNT="${KV_MOUNT:-secret}"
MASK_VALUES="${MASK_VALUES:-true}"        # mask values in CI logs

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Authenticate to Vault via AppRole and export secrets as environment variables.

Options:
  -a, --addr ADDR         Vault address (default: \$VAULT_ADDR)
  -r, --role-id ID        AppRole Role ID (default: \$VAULT_ROLE_ID)
  -s, --secret-id ID      AppRole Secret ID (default: \$VAULT_SECRET_ID)
  -p, --paths PATHS       Comma-separated KV secret paths to retrieve
  -m, --mount MOUNT       KV v2 mount path (default: secret)
  -f, --format FORMAT     Output format: env, github, json, gitlab (default: env)
  --no-mask               Don't mask secret values in CI logs
  -h, --help              Show this help message

Output Formats:
  env       Export as shell environment variables (eval-friendly)
  github    Write to \$GITHUB_OUTPUT and mask values (GitHub Actions)
  json      Output as JSON object
  gitlab    Write dotenv file for GitLab CI artifacts

Environment Variables:
  VAULT_ADDR              Vault server address
  VAULT_ROLE_ID           AppRole Role ID
  VAULT_SECRET_ID         AppRole Secret ID
  SECRET_PATHS            Comma-separated list of secret paths
  GITHUB_OUTPUT           GitHub Actions output file (auto-detected)

Examples:
  # GitHub Actions — secrets available as step outputs
  $(basename "$0") --format github --paths "apps/web/database,apps/web/api-key"

  # Shell — eval to export variables
  eval \$($(basename "$0") --format env --paths "apps/web/database")

  # GitLab CI — generates dotenv artifact
  $(basename "$0") --format gitlab --paths "apps/web/database"
EOF
    exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--addr)      VAULT_ADDR="$2";      shift 2 ;;
        -r|--role-id)   VAULT_ROLE_ID="$2";   shift 2 ;;
        -s|--secret-id) VAULT_SECRET_ID="$2"; shift 2 ;;
        -p|--paths)     SECRET_PATHS="$2";    shift 2 ;;
        -m|--mount)     KV_MOUNT="$2";        shift 2 ;;
        -f|--format)    OUTPUT_FORMAT="$2";   shift 2 ;;
        --no-mask)      MASK_VALUES="false";  shift ;;
        -h|--help)      usage ;;
        *) log_err "Unknown option: $1"; usage ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────────
if [[ -z "$VAULT_ROLE_ID" ]]; then
    log_err "VAULT_ROLE_ID is required (use --role-id or \$VAULT_ROLE_ID)"
    exit 1
fi

if [[ -z "$VAULT_SECRET_ID" ]]; then
    log_err "VAULT_SECRET_ID is required (use --secret-id or \$VAULT_SECRET_ID)"
    exit 1
fi

if [[ -z "$SECRET_PATHS" ]]; then
    log_err "SECRET_PATHS is required (use --paths or \$SECRET_PATHS)"
    exit 1
fi

case "$OUTPUT_FORMAT" in
    env|github|json|gitlab) ;;
    *) log_err "Invalid output format: $OUTPUT_FORMAT (must be env, github, json, or gitlab)"; exit 1 ;;
esac

# Check for required tools
for cmd in curl jq; do
    if \! command -v "$cmd" &>/dev/null; then
        log_err "$cmd is required but not found in PATH"
        exit 1
    fi
done

# ─── Helper functions ─────────────────────────────────────────────────────────

# Authenticate to Vault via AppRole and return a client token
vault_approle_login() {
    local login_response
    local namespace_header=""

    if [[ -n "$VAULT_NAMESPACE" ]]; then
        namespace_header="-H X-Vault-Namespace: ${VAULT_NAMESPACE}"
    fi

    log_info "Authenticating to Vault at ${VAULT_ADDR} via AppRole..."

    login_response="$(curl -s --fail --max-time 10 \
        ${namespace_header} \
        --request POST \
        --data "{\"role_id\":\"${VAULT_ROLE_ID}\",\"secret_id\":\"${VAULT_SECRET_ID}\"}" \
        "${VAULT_ADDR}/v1/auth/approle/login" 2>/dev/null)" || {
        log_err "AppRole authentication failed. Check VAULT_ADDR, ROLE_ID, and SECRET_ID."
        exit 1
    }

    local token
    token="$(echo "$login_response" | jq -r '.auth.client_token // empty')"

    if [[ -z "$token" ]]; then
        local errors
        errors="$(echo "$login_response" | jq -r '.errors[]? // "unknown error"')"
        log_err "Authentication failed: ${errors}"
        exit 1
    fi

    local lease_duration
    lease_duration="$(echo "$login_response" | jq -r '.auth.lease_duration // "unknown"')"
    log_ok "Authenticated successfully (token TTL: ${lease_duration}s)"

    echo "$token"
}

# Read a KV v2 secret from Vault
read_kv_secret() {
    local token="$1"
    local path="$2"
    local namespace_header=""

    if [[ -n "$VAULT_NAMESPACE" ]]; then
        namespace_header="-H X-Vault-Namespace: ${VAULT_NAMESPACE}"
    fi

    local response
    response="$(curl -s --fail --max-time 10 \
        -H "X-Vault-Token: ${token}" \
        ${namespace_header} \
        "${VAULT_ADDR}/v1/${KV_MOUNT}/data/${path}" 2>/dev/null)" || {
        log_err "Failed to read secret at ${KV_MOUNT}/data/${path}"
        return 1
    }

    # Extract the data.data payload (KV v2 wraps data in an extra layer)
    echo "$response" | jq -r '.data.data // empty'
}

# Convert a secret key to a valid environment variable name
# e.g., "database-password" -> "DATABASE_PASSWORD"
normalize_env_key() {
    local key="$1"
    echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_' | tr '.' '_' | sed 's/[^A-Z0-9_]/_/g'
}

# Mask a value in GitHub Actions logs
mask_github_value() {
    local value="$1"
    if [[ "$MASK_VALUES" == "true" ]] && [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::${value}"
    fi
}

# ─── Output formatters ───────────────────────────────────────────────────────

output_env() {
    local prefix="$1"
    local key="$2"
    local value="$3"
    local env_key
    env_key="$(normalize_env_key "${prefix}_${key}")"
    echo "export ${env_key}='${value}'"
}

output_github() {
    local prefix="$1"
    local key="$2"
    local value="$3"
    local env_key
    env_key="$(normalize_env_key "${prefix}_${key}")"

    # Mask value in CI logs
    mask_github_value "$value"

    # Write to GITHUB_OUTPUT for step outputs
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${env_key}=${value}" >> "$GITHUB_OUTPUT"
    fi

    # Also write to GITHUB_ENV for subsequent steps
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "${env_key}=${value}" >> "$GITHUB_ENV"
    fi
}

output_gitlab() {
    local prefix="$1"
    local key="$2"
    local value="$3"
    local env_key
    env_key="$(normalize_env_key "${prefix}_${key}")"
    echo "${env_key}=${value}" >> "${GITLAB_DOTENV_FILE:-vault-secrets.env}"
}

# ─── Main execution ──────────────────────────────────────────────────────────
main() {
    # Authenticate via AppRole
    local vault_token
    vault_token="$(vault_approle_login)"

    local json_output="{}"
    local secrets_count=0

    # Split comma-separated paths
    IFS=',' read -ra paths <<< "$SECRET_PATHS"

    for path in "${paths[@]}"; do
        path="$(echo "$path" | xargs)"  # trim whitespace
        log_info "Reading secret: ${KV_MOUNT}/${path}"

        local secret_data
        secret_data="$(read_kv_secret "$vault_token" "$path")" || continue

        if [[ -z "$secret_data" ]] || [[ "$secret_data" == "null" ]]; then
            log_warn "No data found at ${KV_MOUNT}/${path}, skipping"
            continue
        fi

        # Derive a prefix from the path for env var naming
        # e.g., "apps/web/database" -> "APPS_WEB_DATABASE"
        local prefix
        prefix="$(echo "$path" | tr '/' '_')"

        # Iterate over each key-value pair in the secret
        while IFS= read -r key; do
            local value
            value="$(echo "$secret_data" | jq -r --arg k "$key" '.[$k] // empty')"

            case "$OUTPUT_FORMAT" in
                env)    output_env "$prefix" "$key" "$value" ;;
                github) output_github "$prefix" "$key" "$value" ;;
                gitlab) output_gitlab "$prefix" "$key" "$value" ;;
                json)
                    local env_key
                    env_key="$(normalize_env_key "${prefix}_${key}")"
                    json_output="$(echo "$json_output" | jq --arg k "$env_key" --arg v "$value" '. + {($k): $v}')"
                    ;;
            esac

            secrets_count=$((secrets_count + 1))
        done < <(echo "$secret_data" | jq -r 'keys[]')

        log_ok "  Retrieved $(echo "$secret_data" | jq 'keys | length') keys from ${path}"
    done

    # Output JSON format
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo "$json_output" | jq .
    fi

    # GitLab format summary
    if [[ "$OUTPUT_FORMAT" == "gitlab" ]]; then
        log_ok "Wrote ${secrets_count} variables to ${GITLAB_DOTENV_FILE:-vault-secrets.env}"
    fi

    log_info "Total secrets exported: ${secrets_count}" >&2

    # Revoke the token after use (least-privilege: don't leave active tokens)
    curl -s --request POST \
        -H "X-Vault-Token: ${vault_token}" \
        "${VAULT_ADDR}/v1/auth/token/revoke-self" &>/dev/null || true
    log_ok "Vault token revoked (cleanup complete)" >&2
}

main
