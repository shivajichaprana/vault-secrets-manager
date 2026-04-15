# admin-policy.hcl
#
# Scope: platform operators managing Vault itself.
#
# Break-glass administrative access -- grants full control over secrets
# engines, auth methods, policies, and audit devices. Pair with MFA and
# short-lived, audited tokens in production. The root token should be
# revoked after this policy is provisioned and a named operator logs in
# via userpass / OIDC.

# ---------------------------------------------------------------------------
# Full control over secrets engines and their data
# ---------------------------------------------------------------------------

path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list", "patch", "sudo"]
}

path "aws/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "database/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# ---------------------------------------------------------------------------
# System-level administration
# ---------------------------------------------------------------------------

# Manage mounts (enable/disable secret engines).
path "sys/mounts" {
  capabilities = ["read", "list"]
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Manage auth methods.
path "sys/auth" {
  capabilities = ["read", "list"]
}

path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Manage policies.
path "sys/policies/acl" {
  capabilities = ["read", "list"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage audit devices (required for compliance).
path "sys/audit" {
  capabilities = ["read", "sudo"]
}

path "sys/audit/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

# Health + seal status endpoints for operators.
path "sys/health" {
  capabilities = ["read", "sudo"]
}

path "sys/seal-status" {
  capabilities = ["read"]
}

# Token administration.
path "auth/token/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Leases -- view and revoke any outstanding lease.
path "sys/leases/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
