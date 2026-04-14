#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# seed-secrets.sh
#
# Populate Vault with example secrets on the KV v2 engine for local testing
# and integration demos. Reads seed values from the shell environment (see
# .env.example). Safe to re-run: writes are idempotent (same path → overwrite).
#
# Usage:
#   source .env && ./scripts/seed-secrets.sh
# ---------------------------------------------------------------------------
set -euo pipefail

C_RESET="\033[0m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_BLUE="\033[34m"; C_RED="\033[31m"
log()  { printf "%b[seed]%b %s\n"  "${C_BLUE}"  "${C_RESET}" "$*"; }
ok()   { printf "%b[seed]%b %s\n"  "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf "%b[seed]%b %s\n"  "${C_YELLOW}" "${C_RESET}" "$*"; }
err()  { printf "%b[seed]%b %s\n"  "${C_RED}"   "${C_RESET}" "$*" >&2; }

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_INIT_OUTPUT_DIR="${VAULT_INIT_OUTPUT_DIR:-.vault}"
INIT_FILE="${VAULT_INIT_OUTPUT_DIR}/init.json"

export VAULT_ADDR

command -v vault >/dev/null 2>&1 || { err "vault CLI not found"; exit 1; }
command -v jq    >/dev/null 2>&1 || { err "jq not found"; exit 1; }

# Prefer an explicitly exported VAULT_TOKEN; otherwise pull the root token from
# the init artifact written by init-vault.sh.
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if [[ ! -f "$INIT_FILE" ]]; then
    err "VAULT_TOKEN is not set and ${INIT_FILE} is missing."
    err "Run ./scripts/init-vault.sh first, or export VAULT_TOKEN explicitly."
    exit 1
  fi
  VAULT_TOKEN="$(jq -r '.root_token' "$INIT_FILE")"
  export VAULT_TOKEN
  warn "using root token from ${INIT_FILE}"
fi

# ---------------------------------------------------------------------------
# Enable KV v2 at 'secret/' if it isn't already mounted.
# ---------------------------------------------------------------------------
ensure_kv_v2() {
  local path="$1"
  if vault secrets list -format=json \
       | jq -e --arg p "${path}/" '.[$p] | select(.type=="kv" and .options.version=="2")' \
       >/dev/null 2>&1; then
    ok "kv-v2 already mounted at ${path}/"
    return 0
  fi
  log "enabling kv-v2 at ${path}/"
  vault secrets enable -path="${path}" -version=2 kv
}

ensure_kv_v2 "secret"

# ---------------------------------------------------------------------------
# Seed example secrets. These are intentionally generic / harmless values.
# ---------------------------------------------------------------------------
SEED_APP_DB_USER="${SEED_APP_DB_USER:-app}"
SEED_APP_DB_PASSWORD="${SEED_APP_DB_PASSWORD:-change-me-local-only}"
SEED_API_KEY="${SEED_API_KEY:-example-api-key-change-me}"

log "seeding secret/data/app/config"
vault kv put secret/app/config \
  log_level=info \
  feature_flags_enabled=true \
  environment=local >/dev/null

log "seeding secret/data/app/database"
vault kv put secret/app/database \
  username="${SEED_APP_DB_USER}" \
  password="${SEED_APP_DB_PASSWORD}" \
  host=postgres.internal \
  port=5432 \
  database=appdb >/dev/null

log "seeding secret/data/app/api"
vault kv put secret/app/api \
  api_key="${SEED_API_KEY}" \
  rate_limit=1000 >/dev/null

log "seeding secret/data/shared/registry"
vault kv put secret/shared/registry \
  username=readonly \
  password=change-me-local-only \
  registry=ghcr.io >/dev/null

ok "seed complete. Verify with: vault kv get secret/app/database"
