# Contributing to vault-secrets-manager

Thank you for your interest in contributing to this project. This document covers the conventions and processes used to keep the codebase consistent and maintainable.

## Development Setup

1. Clone the repository and copy the environment template:

   ```bash
   git clone https://github.com/shivajichaprana/vault-secrets-manager.git
   cd vault-secrets-manager
   cp .env.example .env
   ```

2. Start the local Vault stack:

   ```bash
   docker compose -f docker/docker-compose.yml up -d
   ./scripts/init-vault.sh
   ```

3. Provision Vault with Terraform:

   ```bash
   cd terraform
   export VAULT_ADDR=http://127.0.0.1:8200
   export VAULT_TOKEN="$(cat ../.vault-init/root-token)"
   terraform init && terraform apply -auto-approve
   ```

4. Run validation to make sure everything is green:

   ```bash
   make validate
   ```

## Code Standards

### Terraform

- Use variable validation blocks for all user-facing inputs.
- Every resource must include a `description` argument where the provider supports it.
- Format all `.tf` files with `terraform fmt` before committing.
- Pin provider versions in `versions.tf`. Use pessimistic constraint operators (`~>`).

### HCL Policies

- One policy per file under `terraform/policies/`.
- Start every file with a comment block stating scope, consumer, and the principle behind the access grants.
- Use explicit `deny` rules to prevent future mounts from being accidentally accessible.
- Validate syntax with `./scripts/validate-policies.sh` before committing.

### Shell Scripts

- Begin every script with `set -euo pipefail`.
- Include a `usage()` function that prints help text and exits non-zero.
- Use color output via ANSI escape codes for user-facing messages (green for success, red for errors, yellow for warnings).
- Add a `trap` for cleanup of temporary files or resources.
- Pass `shellcheck` with zero warnings.

### Kubernetes Manifests

- Include resource requests and limits on every container.
- Add meaningful labels: `app.kubernetes.io/name`, `app.kubernetes.io/component`, `app.kubernetes.io/managed-by`.
- Validate manifests with `kubeval` or `kubeconform` before committing.

### YAML

- Use two-space indentation consistently.
- Lint with `yamllint` (the CI pipeline enforces this).

## Commit Messages

This project uses Conventional Commits. Every commit message must match the pattern:

```
<type>(<scope>): <description>
```

Allowed types: `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `chore`.

Examples:
- `feat(terraform): add transit secrets engine for application encryption`
- `fix(scripts): handle already-initialized Vault in init script`
- `docs(readme): update auth method reference table`

## Pull Request Process

1. Create a feature branch from `main`.
2. Make your changes and ensure `make validate` passes locally.
3. Write or update tests as needed.
4. Open a pull request with a clear description of the change and its motivation.
5. Address review feedback. Commits will be squash-merged into `main`.

## Adding a New Vault Policy

1. Create a new `.hcl` file under `terraform/policies/` following the existing naming convention (`<consumer>-policy.hcl`).
2. Add a corresponding `vault_policy` resource in `terraform/policies.tf`.
3. Assign the policy to the appropriate auth method role in `terraform/auth-methods.tf`.
4. Validate syntax: `./scripts/validate-policies.sh`.
5. Run the integration test: `./tests/test-vault-setup.sh`.
6. Update the Policy Reference section in `README.md`.

## Adding a New Secrets Engine

1. Add the `vault_mount` resource to `terraform/secrets-engines.tf`.
2. Create any associated roles in a new or existing `.tf` file.
3. Update relevant policies to grant or deny access to the new mount path.
4. Add a row to the Secrets Engines table in `README.md`.
5. If the engine has rotation capabilities, add a rotation script or Terraform config.

## Reporting Issues

Open a GitHub issue with a clear description of the problem, including the Vault version, Docker Compose version, and any relevant log output. For security vulnerabilities, please email the maintainer directly rather than opening a public issue.

## License

By contributing to this project, you agree that your contributions will be licensed under the MIT License.
