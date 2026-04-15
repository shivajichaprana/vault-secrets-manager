# outputs.tf
# Outputs exposed by the vault-secrets-manager Terraform module.
#
# These outputs are intended for downstream automation (scripts, other
# Terraform modules, CI jobs). Values that could be useful to an attacker
# (role IDs, token policies) are NOT marked sensitive, but values that *are*
# secret (secret IDs) are emitted with sensitive = true so they are redacted
# from Terraform output.

# ---------------------------------------------------------------------------
# Secrets engine outputs
# ---------------------------------------------------------------------------

output "kv_mount_path" {
  description = "Mount path of the KV v2 secrets engine."
  value       = vault_mount.kv.path
}

output "aws_mount_path" {
  description = "Mount path of the AWS dynamic-credentials secrets engine."
  value       = vault_mount.aws.path
}

output "database_mount_path" {
  description = "Mount path of the database secrets engine."
  value       = vault_mount.database.path
}

# ---------------------------------------------------------------------------
# Auth method outputs
# ---------------------------------------------------------------------------

output "approle_path" {
  description = "Mount path of the AppRole auth backend."
  value       = vault_auth_backend.approle.path
}

output "approle_ci_role_id" {
  description = "AppRole role_id for CI/CD pipelines. Combine with the secret_id to authenticate."
  value       = vault_approle_auth_backend_role.ci_cd.role_id
}

output "kubernetes_auth_path" {
  description = "Mount path of the Kubernetes auth backend."
  value       = vault_auth_backend.kubernetes.path
}

output "userpass_path" {
  description = "Mount path of the userpass auth backend."
  value       = vault_auth_backend.userpass.path
}

# ---------------------------------------------------------------------------
# Policy outputs
# ---------------------------------------------------------------------------

output "policy_names" {
  description = "Names of all Vault policies provisioned by this module."
  value = [
    vault_policy.ci_cd.name,
    vault_policy.app.name,
    vault_policy.admin.name,
  ]
}
