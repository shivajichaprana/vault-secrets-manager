#\!/usr/bin/env bash
# rotate-secrets.sh — Rotate KV secrets in HashiCorp Vault
# Generates new secret values, writes them as new KV versions,
# and logs each rotation event for audit purposes.

set -euo pipefail

# ─── Color output helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ─── Configuration defaults ───────────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
KV_MOUNT="${KV_MOUNT:-secret}"
LOG_FILE="${ROTATION_LOG:-/var/log/vault-rotation.log}"
SECRET_LENGTH="${SECRET_LENGTH:-32}"
DRY_RUN="${DRY_RUN:-false}"

# Secrets to rotate — override with ROTATE_PATHS env var (comma-separated)
DEFAULT_PATHS="apps/web/database,apps/web/api-key,apps/worker/credentials"
ROTATE_PATHS="${ROTATE_PATHS:-$DEFAULT_PATHS}"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Rotate KV v2 secrets in HashiCorp Vault.

Options:
  -a, --addr ADDR         Vault address (default: \$VAULT_ADDR or http://127.0.0.1:8200)
  -t, --token TOKEN       Vault token (default: \$VAULT_TOKEN)
  -m, --mount MOUNT       KV v2 mount path (default: secret)
  -p, --paths PATHS       Comma-separated secret paths to rotate
  -l, --log FILE          Log file path (default: /var/log/vault-rotation.log)
  -n, --dry-run           Show what would be rotated without making changes
  -h, --help              Show this help message

Environment Variables:
  VAULT_ADDR              Vault server address
  VAULT_TOKEN             Vault authentication token
  KV_MOUNT                KV secrets engine mount path
  ROTATE_PATHS            Comma-separated list of secret paths
  SECRET_LENGTH           Length of generated secrets (default: 32)
  DRY_RUN                 Set to 'true' for dry-run mode

Examples:
  $(basename "$0") --paths "apps/web/database,apps/api/key"
  $(basename "$0") --dry-run --mount kv
  ROTATE_PATHS="apps/web/db" $(basename "$0")
EOF
    exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--addr)   VAULT_ADDR="$2";   shift 2 ;;
        -t|--token)  VAULT_TOKEN="$2";  shift 2 ;;
        -m|--mount)  KV_MOUNT="$2";     shift 2 ;;
        -p|--paths)  ROTATE_PATHS="$2"; shift 2 ;;
        -l|--log)    LOG_FILE="$2";     shift 2 ;;
        -n|--dry-run) DRY_RUN="true";   shift ;;
        -h|--help)   usage ;;
        *) log_err "Unknown option: $1"; usage ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────────
if [[ -z "$VAULT_TOKEN" ]]; then
    log_err "VAULT_TOKEN is required (use --token or \$VAULT_TOKEN)"
    exit 1
fi

if \! command -v vault &>/dev/null; then
    log_err "vault CLI not found in PATH"
    exit 1
fi

export VAULT_ADDR VAULT_TOKEN

# Verify Vault connectivity
if \! vault status &>/dev/null; then
    log_err "Cannot connect to Vault at ${VAULT_ADDR}"
    exit 1
fi

# ─── Helper functions ─────────────────────────────────────────────────────────

# Generate a cryptographically random secret value
generate_secret() {
    local length="${1:-$SECRET_LENGTH}"
    openssl rand -base64 "$length" | tr -d '\n' | head -c "$length"
}

# Generate a random password with mixed character classes
generate_password() {
    local length="${1:-$SECRET_LENGTH}"
    LC_ALL=C tr -dc 'A-Za-z0-9\!@#%^&*()_+-=' < /dev/urandom | head -c "$length"
}

# Log rotation event to file and stdout
log_rotation_event() {
    local path="$1"
    local version="$2"
    local status="$3"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local log_entry="${timestamp} | path=${path} | version=${version} | status=${status}"
    log_info "$log_entry"

    # Append to log file if writable
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        echo "$log_entry" >> "$LOG_FILE"
    fi
}

# Read current secret metadata to get the version number
get_current_version() {
    local path="$1"
    vault kv metadata get -mount="$KV_MOUNT" -format=json "$path" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['current_version'])" 2>/dev/null \
        || echo "0"
}

# Rotate a single secret path
rotate_secret() {
    local path="$1"
    local current_version
    local new_password
    local new_api_key

    log_info "Processing: ${KV_MOUNT}/${path}"

    # Get current version for audit trail
    current_version="$(get_current_version "$path")"
    log_info "  Current version: ${current_version}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "  [DRY RUN] Would rotate ${KV_MOUNT}/${path} (v${current_version} -> v$((current_version + 1)))"
        return 0
    fi

    # Generate new credentials
    new_password="$(generate_password 24)"
    new_api_key="$(generate_secret 40)"

    # Read existing secret to preserve non-rotated fields
    local existing_data
    existing_data="$(vault kv get -mount="$KV_MOUNT" -format=json "$path" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']['data']
for k, v in d.items():
    print(f'{k}={v}')
" 2>/dev/null)" || true

    # Build the update — rotate password and api_key fields, preserve others
    local kv_args=()
    if [[ -n "$existing_data" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                password|passwd|secret)
                    kv_args+=("${key}=${new_password}") ;;
                api_key|api_secret|token)
                    kv_args+=("${key}=${new_api_key}") ;;
                *)
                    kv_args+=("${key}=${value}") ;;
            esac
        done <<< "$existing_data"

        # Add rotation metadata
        kv_args+=("rotated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
        kv_args+=("rotated_by=rotate-secrets.sh")
    else
        # Secret doesn't exist yet — create with default fields
        kv_args=(
            "password=${new_password}"
            "api_key=${new_api_key}"
            "rotated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            "rotated_by=rotate-secrets.sh"
        )
    fi

    # Write the new version
    if vault kv put -mount="$KV_MOUNT" "$path" "${kv_args[@]}" &>/dev/null; then
        local new_version
        new_version="$(get_current_version "$path")"
        log_ok "  Rotated: v${current_version} -> v${new_version}"
        log_rotation_event "$path" "$new_version" "SUCCESS"
    else
        log_err "  Failed to rotate ${path}"
        log_rotation_event "$path" "$current_version" "FAILED"
        return 1
    fi
}

# ─── Main execution ──────────────────────────────────────────────────────────
main() {
    log_info "======================================================="
    log_info "Vault Secret Rotation — $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "======================================================="
    log_info "Vault:   ${VAULT_ADDR}"
    log_info "Mount:   ${KV_MOUNT}"
    log_info "Dry Run: ${DRY_RUN}"
    echo

    local success_count=0
    local fail_count=0
    local total=0

    # Split comma-separated paths
    IFS=',' read -ra paths <<< "$ROTATE_PATHS"

    for path in "${paths[@]}"; do
        path="$(echo "$path" | xargs)"  # trim whitespace
        total=$((total + 1))

        if rotate_secret "$path"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
        echo
    done

    # Summary
    log_info "======================================================="
    log_info "Rotation Summary"
    log_info "======================================================="
    log_ok   "Succeeded: ${success_count}/${total}"
    [[ "$fail_count" -gt 0 ]] && log_err "Failed:    ${fail_count}/${total}"

    [[ "$fail_count" -gt 0 ]] && exit 1
    exit 0
}

main
