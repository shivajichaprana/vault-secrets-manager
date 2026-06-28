# secrets-engines.tf
# Enables the secrets engines used by the vault-secrets-manager project.
#
# Three engines are enabled:
#   * KV v2      -- generic key/value store for application configuration
#                   and "legacy" static secrets. Versioned so operators can
#                   recover from an accidental overwrite.
#   * AWS        -- dynamic short-lived IAM credentials for apps and CI.
#                   The AWS root credentials themselves are written to the
#                   engine's /config/root endpoint out-of-band (see
#                   scripts/seed-secrets.sh); they are NOT committed here.
#   * Database   -- dynamic database credentials (e.g. PostgreSQL).

# ---------------------------------------------------------------------------
# KV v2
# ---------------------------------------------------------------------------

resource "vault_mount" "kv" {
  path        = var.kv_mount_path
  type        = "kv"
  options     = { version = "2" }
  description = "KV v2 store for static application secrets."

  # Keep up to 10 historical versions so an accidental overwrite can be
  # rolled back without touching backups.
  default_lease_ttl_seconds = 0
  max_lease_ttl_seconds     = 0
}

# Tune the KV mount with versioning defaults. Separate resource so the mount
# itself can be imported without drift on these tuning fields.
resource "vault_kv_secret_backend_v2" "kv_config" {
  mount                = vault_mount.kv.path
  max_versions         = 10
  delete_version_after = 0
  cas_required         = false
}

# ---------------------------------------------------------------------------
# AWS dynamic credentials
# ---------------------------------------------------------------------------

resource "vault_mount" "aws" {
  path                      = var.aws_secrets_mount_path
  type                      = "aws"
  description               = "Dynamic AWS IAM credentials issued per-request."
  default_lease_ttl_seconds = 1800 # 30 min
  max_lease_ttl_seconds     = 3600 # 1 hr
}

# A sample read-only role. Real roles should be provisioned per-application
# and lock down the policy ARN to the minimum permissions required.
resource "vault_aws_secret_backend_role" "readonly_sample" {
  backend         = vault_mount.aws.path
  name            = "readonly-sample"
  credential_type = "iam_user"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Database dynamic credentials
# ---------------------------------------------------------------------------

resource "vault_mount" "database" {
  path                      = var.database_mount_path
  type                      = "database"
  description               = "Dynamic database credentials (e.g. a PostgreSQL connection)."
  default_lease_ttl_seconds = 3600  # 1 hr
  max_lease_ttl_seconds     = 86400 # 24 hr
}
