# app-policy.hcl
#
# Scope: application workloads running on Kubernetes. The External Secrets
# Operator (see Day 21) authenticates via the kubernetes/ auth method and
# assumes this policy to sync secrets into K8s `Secret` objects.
#
# Applications can READ their own config under secret/data/apps/<app>/* and
# request dynamic database credentials, but must never touch the CI/CD
# paths or admin endpoints.

# ---------------------------------------------------------------------------
# KV v2 -- app-owned configuration and runtime secrets
# ---------------------------------------------------------------------------

# Read any version under the apps/ prefix. Specific apps get narrower
# policies in production; this broad read is suitable for the Day-20 sample.
path "secret/data/apps/*" {
  capabilities = ["read"]
}

path "secret/metadata/apps/*" {
  capabilities = ["list", "read"]
}

# Shared runtime config used by many apps (feature flags, 3rd-party URLs).
path "secret/data/shared/apps/*" {
  capabilities = ["read"]
}

path "secret/metadata/shared/apps/*" {
  capabilities = ["list", "read"]
}

# ---------------------------------------------------------------------------
# Database dynamic credentials
# ---------------------------------------------------------------------------

# Apps request a time-bound DB username/password pair. The role itself is
# provisioned in Day 22 and carries the per-app SQL grants.
path "database/creds/app-readwrite" {
  capabilities = ["read"]
}

path "database/creds/app-readonly" {
  capabilities = ["read"]
}

# Deny any other DB role by default so new roles can't be consumed until
# explicitly allow-listed.
path "database/creds/*" {
  capabilities = ["deny"]
}

# ---------------------------------------------------------------------------
# Transit encrypt/decrypt (placeholder for future transit-engine use)
# ---------------------------------------------------------------------------

# Apps commonly need to encrypt/decrypt with keys they cannot export. The
# transit engine is not enabled in Day 20 but this rule is pre-wired so the
# app policy does not need to change when it is.
path "transit/encrypt/app-*" {
  capabilities = ["update"]
}

path "transit/decrypt/app-*" {
  capabilities = ["update"]
}

# ---------------------------------------------------------------------------
# Token self-management
# ---------------------------------------------------------------------------

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
