# ci-cd-policy.hcl
#
# Scope: non-interactive CI/CD pipelines (GitHub Actions, Jenkins, GitLab CI).
#
# Principle of least privilege -- pipelines can only READ a narrow set of KV
# paths dedicated to CI, and can only request short-lived AWS credentials
# from a pre-approved role. They cannot list every secret, write to KV, or
# touch any auth method.

# ---------------------------------------------------------------------------
# KV v2 -- read-only access to ci/ and shared/ci/ paths only
# ---------------------------------------------------------------------------

# Read the latest version of a secret under secret/data/ci/*
path "secret/data/ci/*" {
  capabilities = ["read"]
}

# List keys under secret/metadata/ci/* so pipelines can discover what's
# available without being able to read the values.
path "secret/metadata/ci/*" {
  capabilities = ["list", "read"]
}

# Shared build-time config (e.g. Docker registry URLs, artifact bucket names)
path "secret/data/shared/ci/*" {
  capabilities = ["read"]
}

path "secret/metadata/shared/ci/*" {
  capabilities = ["list", "read"]
}

# ---------------------------------------------------------------------------
# AWS dynamic creds -- read the readonly-sample role's credentials
# ---------------------------------------------------------------------------

path "aws/creds/readonly-sample" {
  capabilities = ["read"]
}

# Explicitly deny any other AWS role to prevent privilege escalation if a new
# role is added later with a looser policy.
path "aws/creds/*" {
  capabilities = ["deny"]
}

# ---------------------------------------------------------------------------
# Token self-management
# ---------------------------------------------------------------------------

# The pipeline needs to look up its own token to reason about remaining TTL.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Allow the caller to revoke its own token when the pipeline finishes.
path "auth/token/revoke-self" {
  capabilities = ["update"]
}

# Allow renewing the token if a long-running job needs extra time (bounded by
# the AppRole's max_ttl).
path "auth/token/renew-self" {
  capabilities = ["update"]
}
