#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# init-vault.sh
#
# Initialize and unseal a fresh Vault instance, then enable the file-based
# audit device. Persists the generated unseal keys and initial root token to
# $VAULT_INIT_OUTPUT_DIR (default: .vault/) which is listed in .gitignore.
#
# Idempotent: safely skips steps that have already completed.
#
# Usage:
#   ./scripts/init-vault.sh            # initialize + unseal + audit
#   ./scripts/init-vault.sh --unseal   # only unseal (reads existing keys)
#
# Environment:
#   VAULT_ADDR                (default: http://127.0.0.1:8200)
#   VAULT_INIT_OUTPUT_DIR     (default: .vault)
#   VAULT_INIT_KEY_SHARES     (default: 5)
#   VAULT_INIT_KEY_THRESHOLD  (default: 3)
#   VAULT_AUDIT_LOG_PATH      (default: /vault/logs/audit.log)
# ---------------------------------------------------------------------------
set -euo pipefail

# --- colors ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"
  C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_BLUE="\033[34m"
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf "%b[init-vault]%b %s\n" "${C_BLUE}" "${C_RESET}" "$*"; }
ok()   { printf "%b[init-vault]%b %s\n" "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf "%b[init-vault]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; }
err()  { printf "%b[init-vault]%b %s\n" "${C_RED}" "${C_RESET}" "$*" >&2; }

# --- defaults -------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_INIT_OUTPUT_DIR="${VAULT_INIT_OUTPUT_DIR:-.vault}"
VAULT_INIT_KEY_SHARES="${VAULT_INIT_KEY_SHARES:-5}"
VAULT_INIT_KEY_THRESHOLD="${VAULT_INIT_KEY_THRESHOLD:-3}"
VAULT_AUDIT_LOG_PATH="${VAULT_AUDIT_LOG_PATH:-/vault/logs/audit.log}"
INIT_FILE="${VAULT_INIT_OUTPUT_DIR}/init.json"

export VAULT_ADDR

# --- pre-flight -----------------------------------------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || { err "missing required command: $1"; exit 1; }
}
need curl
need jq
need vault

# --- cleanup trap ---------------------------------------------------------
TMPFILES=()
cleanup() {
  for f in "${TMPFILES[@]}"; do [[ -e "$f" ]] && rm -f "$f" || true; done
}
trap cleanup EXIT

usage() {
  sed -n '2,20p' "$0"
}

# --- helpers --------------------------------------------------------------
wait_for_vault() {
  log "waiting for Vault at ${VAULT_ADDR} ..."
  local i=0
  until curl -fsS "${VAULT_ADDR}/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true" >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ "$i" -gt 30 ]]; then
      err "Vault did not respond within 60s"
      exit 1
    fi
    sleep 2
  done
  ok "Vault is reachable"
}

vault_initialized() {
  curl -fsS "${VAULT_ADDR}/v1/sys/init" | jq -e '.initialized == true' >/dev/null
}

vault_sealed() {
  curl -fsS "${VAULT_ADDR}/v1/sys/seal-status" | jq -e '.sealed == true' >/dev/null
}

do_init() {
  if vault_initialized; then
    warn "Vault is already initialized — skipping init"
    if [[ ! -f "$INIT_FILE" ]]; then
      err "Vault is initialized but ${INIT_FILE} is missing. Cannot recover unseal keys."
      err "If this is a fresh local run, stop and remove the vault-file volume, then retry."
      exit 1
    fi
    return 0
  fi
  mkdir -p "$VAULT_INIT_OUTPUT_DIR"
  log "initializing Vault (shares=${VAULT_INIT_KEY_SHARES}, threshold=${VAULT_INIT_KEY_THRESHOLD})"
  vault operator init \
    -key-shares="${VAULT_INIT_KEY_SHARES}" \
    -key-threshold="${VAULT_INIT_KEY_THRESHOLD}" \
    -format=json >"$INIT_FILE"
  chmod 600 "$INIT_FILE"
  ok "wrote unseal keys + root token to ${INIT_FILE} (mode 0600)"
}

do_unseal() {
  if ! vault_sealed; then
    ok "Vault is already unsealed"
    return 0
  fi
  log "unsealing Vault with ${VAULT_INIT_KEY_THRESHOLD} keys"
  local i key
  for i in $(seq 0 $((VAULT_INIT_KEY_THRESHOLD - 1))); do
    key="$(jq -r ".unseal_keys_b64[$i]" "$INIT_FILE")"
    vault operator unseal "$key" >/dev/null
  done
  if vault_sealed; then
    err "Vault is still sealed after providing ${VAULT_INIT_KEY_THRESHOLD} keys"
    exit 1
  fi
  ok "Vault unsealed"
}

do_audit() {
  local token
  token="$(jq -r '.root_token' "$INIT_FILE")"
  export VAULT_TOKEN="$token"

  if vault audit list 2>/dev/null | grep -q '^file/'; then
    warn "audit device file/ already enabled — skipping"
    return 0
  fi
  log "enabling file audit device at ${VAULT_AUDIT_LOG_PATH}"
  vault audit enable file file_path="${VAULT_AUDIT_LOG_PATH}"
  ok "audit device enabled"
}

# --- dispatch -------------------------------------------------------------
case "${1:-init}" in
  -h|--help|help)
    usage; exit 0 ;;
  --unseal)
    wait_for_vault; do_unseal ;;
  init|"")
    wait_for_vault
    do_init
    do_unseal
    do_audit
    ok "initialization complete. Root token persisted to ${INIT_FILE}"
    warn "protect ${INIT_FILE}: it contains the root token and all unseal keys"
    ;;
  *)
    err "unknown argument: $1"
    usage
    exit 2
    ;;
esac
