#\!/usr/bin/env bash
# validate-policies.sh — Validate Vault HCL policy syntax
# Checks all .hcl policy files for syntax errors using vault policy fmt.
# Exits non-zero if any policy file has invalid syntax.

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_DIRS=(
    "${PROJECT_ROOT}/terraform/policies"
)
CHECK_ONLY="${CHECK_ONLY:-true}"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate Vault HCL policy files for syntax errors.

Options:
  -d, --dir DIR     Additional directory to scan for .hcl files (repeatable)
  -f, --fix         Auto-format files in place (default: check only)
  -h, --help        Show this help message

Environment Variables:
  CHECK_ONLY        Set to 'false' to auto-format (default: true)

Examples:
  $(basename "$0")                          # Check all policies
  $(basename "$0") --fix                    # Auto-format in place
  $(basename "$0") -d /path/to/policies     # Check additional directory
EOF
    exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir) POLICY_DIRS+=("$2"); shift 2 ;;
        -f|--fix) CHECK_ONLY="false"; shift ;;
        -h|--help) usage ;;
        *) log_err "Unknown option: $1"; usage ;;
    esac
done

# ─── Check prerequisites ─────────────────────────────────────────────────────
if \! command -v vault &>/dev/null; then
    log_err "vault CLI not found in PATH"
    log_info "Install from: https://developer.hashicorp.com/vault/install"
    exit 1
fi

log_info "Vault version: $(vault version 2>/dev/null || echo 'unknown')"
echo

# ─── Find and validate policy files ──────────────────────────────────────────
total=0
passed=0
failed=0
formatted=0

for dir in "${POLICY_DIRS[@]}"; do
    if [[ \! -d "$dir" ]]; then
        log_warn "Directory not found: ${dir} — skipping"
        continue
    fi

    log_info "Scanning: ${dir}"

    while IFS= read -r -d '' policy_file; do
        total=$((total + 1))
        relative_path="${policy_file#"$PROJECT_ROOT"/}"

        # Use vault policy fmt to check syntax
        # vault policy fmt returns 0 if file is already formatted, 1 if it needs formatting
        if [[ "$CHECK_ONLY" == "true" ]]; then
            # Check mode: compare formatted output with original
            formatted_content="$(vault policy fmt -check "$policy_file" 2>&1)" && fmt_rc=0 || fmt_rc=$?

            if [[ $fmt_rc -eq 0 ]]; then
                log_ok "  ${relative_path}"
                passed=$((passed + 1))
            else
                # Try to determine if it's a syntax error or just formatting
                if echo "$formatted_content" | grep -qi "error\|invalid\|unexpected"; then
                    log_err "  ${relative_path} — syntax error"
                    echo "    ${formatted_content}" | head -5
                    failed=$((failed + 1))
                else
                    log_warn "  ${relative_path} — needs formatting"
                    formatted=$((formatted + 1))
                    passed=$((passed + 1))
                fi
            fi
        else
            # Fix mode: format in place
            if vault policy fmt "$policy_file" 2>/dev/null; then
                log_ok "  ${relative_path} — formatted"
                passed=$((passed + 1))
            else
                log_err "  ${relative_path} — syntax error (cannot format)"
                failed=$((failed + 1))
            fi
        fi
    done < <(find "$dir" -name "*.hcl" -type f -print0 | sort -z)
done

# ─── Also check inline HCL in Terraform files ────────────────────────────────
log_info ""
log_info "Checking Terraform policy resources for embedded HCL..."

tf_dir="${PROJECT_ROOT}/terraform"
if [[ -d "$tf_dir" ]]; then
    # Extract policy blocks from .tf files and validate them
    while IFS= read -r -d '' tf_file; do
        relative_path="${tf_file#"$PROJECT_ROOT"/}"

        # Check if file contains vault_policy resources
        if grep -q 'resource "vault_policy"' "$tf_file" 2>/dev/null; then
            log_info "  Found vault_policy in ${relative_path}"

            # Basic HCL syntax validation — check for balanced braces
            open_braces=$(grep -c '{' "$tf_file" || true)
            close_braces=$(grep -c '}' "$tf_file" || true)

            if [[ "$open_braces" -eq "$close_braces" ]]; then
                log_ok "  ${relative_path} — braces balanced (${open_braces} pairs)"
            else
                log_warn "  ${relative_path} — brace mismatch (open: ${open_braces}, close: ${close_braces})"
            fi
        fi
    done < <(find "$tf_dir" -name "*.tf" -type f -print0 | sort -z)
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
log_info "======================================================="
log_info "Policy Validation Summary"
log_info "======================================================="
log_info "Total files scanned: ${total}"
log_ok   "Passed:              ${passed}"
[[ "$formatted" -gt 0 ]] && log_warn "Needs formatting:    ${formatted}"
[[ "$failed" -gt 0 ]]    && log_err  "Failed:              ${failed}"

if [[ "$failed" -gt 0 ]]; then
    log_err "Policy validation FAILED"
    exit 1
fi

if [[ "$formatted" -gt 0 ]] && [[ "$CHECK_ONLY" == "true" ]]; then
    log_warn "Some files need formatting. Run with --fix to auto-format."
    exit 0
fi

log_ok "All policies are valid"
exit 0
