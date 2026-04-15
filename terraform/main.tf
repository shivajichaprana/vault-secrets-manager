# main.tf
# Root Terraform configuration for the vault-secrets-manager project.
#
# This file wires up the Vault provider against a local Vault instance started
# by `docker-compose up` (see ../docker/docker-compose.yml) and initialized by
# `../scripts/init-vault.sh`. The root token is read from the VAULT_TOKEN
# environment variable (or the `vault_token` Terraform variable) so that no
# secrets are ever committed to the repository.
#
# Usage:
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN="$(cat ../.vault-init/root-token)"
#   terraform init
#   terraform plan
#   terraform apply

provider "vault" {
  address         = var.vault_address
  token           = var.vault_token
  skip_tls_verify = var.skip_tls_verify

  # Tokens created by this provider are scoped with a short TTL so that a
  # leaked Terraform state cannot be used to gain long-lived access to Vault.
  max_lease_ttl_seconds = var.provider_max_lease_ttl
}

# Track every resource provisioned by this module with a consistent tag so
# operators can tell Terraform-managed objects apart from any manual entries.
locals {
  managed_by = "terraform"
  project    = "vault-secrets-manager"

  common_metadata = {
    managed_by = local.managed_by
    project    = local.project
    owner      = var.owner
  }
}
