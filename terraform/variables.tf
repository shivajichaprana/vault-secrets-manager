# variables.tf
# Input variables for the vault-secrets-manager Terraform module.
#
# Defaults target the local Docker Compose Vault from Day 19. For any other
# environment (staging, prod), override these via terraform.tfvars or -var
# flags. Sensitive values must never be hard-coded in a tfvars file that is
# committed to source control.

variable "vault_address" {
  description = "Address of the Vault server, e.g. http://127.0.0.1:8200"
  type        = string
  default     = "http://127.0.0.1:8200"

  validation {
    condition     = can(regex("^https?://", var.vault_address))
    error_message = "vault_address must start with http:// or https://."
  }
}

variable "vault_token" {
  description = "Vault token used by Terraform to provision resources. Read from VAULT_TOKEN env var by default."
  type        = string
  sensitive   = true
  default     = null
}

variable "skip_tls_verify" {
  description = "Skip TLS verification. Only acceptable for local dev Vault (Docker Compose). Must be false in any shared environment."
  type        = bool
  default     = true
}

variable "provider_max_lease_ttl" {
  description = "Maximum lease TTL (in seconds) for tokens created by the Vault provider."
  type        = number
  default     = 3600

  validation {
    condition     = var.provider_max_lease_ttl > 0 && var.provider_max_lease_ttl <= 86400
    error_message = "provider_max_lease_ttl must be between 1 and 86400 seconds."
  }
}

variable "owner" {
  description = "Owner tag applied to managed resources (used for auditing)."
  type        = string
  default     = "platform-team"
}

# ---------------------------------------------------------------------------
# Secrets-engine inputs
# ---------------------------------------------------------------------------

variable "kv_mount_path" {
  description = "Mount path for the KV v2 secrets engine."
  type        = string
  default     = "secret"
}

variable "aws_secrets_mount_path" {
  description = "Mount path for the AWS dynamic-credentials secrets engine."
  type        = string
  default     = "aws"
}

variable "aws_region" {
  description = "Default AWS region used when the AWS secrets engine issues credentials."
  type        = string
  default     = "us-east-1"
}

variable "database_mount_path" {
  description = "Mount path for the database secrets engine."
  type        = string
  default     = "database"
}

# ---------------------------------------------------------------------------
# Auth-method inputs
# ---------------------------------------------------------------------------

variable "approle_path" {
  description = "Mount path for the AppRole auth method (CI/CD)."
  type        = string
  default     = "approle"
}

variable "kubernetes_auth_path" {
  description = "Mount path for the Kubernetes auth method (pods)."
  type        = string
  default     = "kubernetes"
}

variable "userpass_path" {
  description = "Mount path for the userpass auth method (humans)."
  type        = string
  default     = "userpass"
}

variable "kubernetes_host" {
  description = "URL of the Kubernetes API server. Only required for wiring up the k8s auth method."
  type        = string
  default     = ""
}

variable "kubernetes_ca_cert" {
  description = "PEM-encoded CA certificate of the Kubernetes API. Only required for wiring up the k8s auth method."
  type        = string
  default     = ""
}

variable "kubernetes_jwt" {
  description = "Service account JWT used by Vault to validate pod tokens. Only required for wiring up the k8s auth method."
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# Token TTLs
# ---------------------------------------------------------------------------

variable "ci_cd_token_ttl" {
  description = "Default TTL (in seconds) for tokens issued via AppRole for CI/CD pipelines."
  type        = number
  default     = 900 # 15 minutes
}

variable "ci_cd_token_max_ttl" {
  description = "Max TTL (in seconds) for CI/CD AppRole tokens."
  type        = number
  default     = 1800 # 30 minutes
}

variable "app_token_ttl" {
  description = "Default TTL (in seconds) for application tokens issued via Kubernetes auth."
  type        = number
  default     = 3600 # 1 hour
}
