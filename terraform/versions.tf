# versions.tf
# Terraform and provider version constraints for the Vault provisioning module.
#
# We pin minimum versions to guarantee that all features used in this module
# (KV v2, Kubernetes auth, AppRole, database secrets engine, JSON policy
# documents) are supported by the provider. Upper bounds are intentionally
# loose so patch releases can be picked up automatically.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = ">= 3.25.0, < 5.0.0"
    }
  }
}
