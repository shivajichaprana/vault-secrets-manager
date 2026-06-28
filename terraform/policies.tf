# policies.tf
# Loads the three tiered Vault policies from separate HCL files in
# ./policies/ and registers them with Vault.
#
# Splitting policy definitions out into their own .hcl files keeps them
# readable (no string escaping) and lets operators lint them with
# `vault policy fmt` (also checked in CI).

resource "vault_policy" "ci_cd" {
  name   = "ci-cd"
  policy = file("${path.module}/policies/ci-cd-policy.hcl")
}

resource "vault_policy" "app" {
  name   = "app"
  policy = file("${path.module}/policies/app-policy.hcl")
}

resource "vault_policy" "admin" {
  name   = "admin"
  policy = file("${path.module}/policies/admin-policy.hcl")
}
