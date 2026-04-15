# auth-methods.tf
# Enables and configures Vault auth methods for the three caller types we
# care about:
#
#   * AppRole    -- non-interactive CI/CD pipelines (GitHub Actions, Jenkins).
#                   Role ID is committed to CI config; secret ID is short-lived
#                   and minted just-in-time by a privileged orchestrator.
#   * Kubernetes -- pods authenticate using their projected service account
#                   token. The Vault server validates the token against the
#                   cluster API.
#   * userpass   -- humans (operators, on-call). MFA should be enforced in
#                   production via Vault Enterprise or an external IdP.

# ---------------------------------------------------------------------------
# AppRole (CI/CD)
# ---------------------------------------------------------------------------

resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = var.approle_path
  description = "AppRole auth for CI/CD pipelines (non-interactive)."

  tune {
    default_lease_ttl  = "${var.ci_cd_token_ttl}s"
    max_lease_ttl      = "${var.ci_cd_token_max_ttl}s"
    listing_visibility = "unauth"
  }
}

resource "vault_approle_auth_backend_role" "ci_cd" {
  backend        = vault_auth_backend.approle.path
  role_name      = "ci-cd"
  token_policies = [vault_policy.ci_cd.name]

  # Short-lived tokens, no renewal -- pipelines should re-auth per job.
  token_ttl               = var.ci_cd_token_ttl
  token_max_ttl           = var.ci_cd_token_max_ttl
  token_num_uses          = 0
  secret_id_num_uses      = 1
  secret_id_ttl           = 600 # 10 minutes to bind the role to a pipeline run
  bind_secret_id          = true
  token_no_default_policy = false
}

# ---------------------------------------------------------------------------
# Kubernetes (pods via External Secrets Operator / Vault Agent)
# ---------------------------------------------------------------------------

resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  path        = var.kubernetes_auth_path
  description = "Kubernetes auth for pods using projected service account tokens."

  tune {
    default_lease_ttl  = "${var.app_token_ttl}s"
    max_lease_ttl      = "${var.app_token_ttl * 4}s"
    listing_visibility = "unauth"
  }
}

# Wire up the auth backend to a real cluster only when the operator has
# supplied the cluster details. This lets the module work locally (Day 20)
# without an actual K8s cluster, and be tightened up in Day 21.
resource "vault_kubernetes_auth_backend_config" "this" {
  count = var.kubernetes_host == "" ? 0 : 1

  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.kubernetes_host
  kubernetes_ca_cert = var.kubernetes_ca_cert
  token_reviewer_jwt = var.kubernetes_jwt
  issuer             = "https://kubernetes.default.svc.cluster.local"
}

resource "vault_kubernetes_auth_backend_role" "app" {
  count = var.kubernetes_host == "" ? 0 : 1

  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "app"
  bound_service_account_names      = ["vault-app"]
  bound_service_account_namespaces = ["default", "applications"]
  token_policies                   = [vault_policy.app.name]
  token_ttl                        = var.app_token_ttl
}

# ---------------------------------------------------------------------------
# userpass (humans)
# ---------------------------------------------------------------------------

resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = var.userpass_path
  description = "Username/password auth for human operators. Pair with MFA in production."

  tune {
    default_lease_ttl  = "1h"
    max_lease_ttl      = "8h"
    listing_visibility = "hidden"
  }
}
