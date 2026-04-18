# vault-secrets-manager

Production-grade HashiCorp Vault deployment with Consul storage, Terraform-provisioned policies, Kubernetes integration via External Secrets Operator, and automated secret rotation.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          vault-secrets-manager                              │
│                                                                             │
│   ┌─────────────┐   ┌──────────────┐   ┌───────────────────┐               │
│   │  Vault UI    │   │  Vault API   │   │  Vault Telemetry  │               │
│   │  :8200/ui    │   │  :8200/v1    │   │  :8200/v1/sys/    │               │
│   └──────┬───────┘   └──────┬───────┘   └────────┬──────────┘               │
│          │                  │                     │                          │
│          └──────────────────┼─────────────────────┘                          │
│                             │                                                │
│                    ┌────────▼────────┐                                       │
│                    │   Vault Server  │                                       │
│                    │   (HA-ready)    │                                       │
│                    └────────┬────────┘                                       │
│                             │                                                │
│             ┌───────────────┼───────────────┐                                │
│             │               │               │                                │
│     ┌───────▼──────┐ ┌─────▼──────┐ ┌──────▼──────┐                         │
│     │ Auth Methods │ │  Secrets   │ │   Storage   │                         │
│     │              │ │  Engines   │ │   Backend   │                         │
│     │ • AppRole    │ │ • KV v2    │ │             │                         │
│     │ • Kubernetes │ │ • AWS      │ │  ┌───────┐  │                         │
│     │ • userpass   │ │ • Database │ │  │Consul │  │                         │
│     └───────┬──────┘ └─────┬──────┘ │  │ Agent │  │                         │
│             │               │        │  └───────┘  │                         │
│             │               │        └─────────────┘                         │
│  ┌──────────┼───────────────┤                                                │
│  │          │               │                                                │
│  │  ┌───────▼──────┐ ┌─────▼──────────────┐                                 │
│  │  │   Policies   │ │  Dynamic Secrets   │                                 │
│  │  │              │ │                    │                                 │
│  │  │ • ci-cd      │ │  AWS IAM creds     │                                 │
│  │  │ • app        │ │  DB user/pass      │                                 │
│  │  │ • admin      │ │  (auto-rotated)    │                                 │
│  │  └──────────────┘ └────────────────────┘                                 │
│  │                                                                           │
│  │  ┌───────────────────────────────────────────────────┐                    │
│  │  │              Consumers                            │                    │
│  │  │                                                   │                    │
│  │  │  CI/CD ──── AppRole ──────► secret/data/ci/*      │                    │
│  │  │  K8s  ──── SA Token ─────► secret/data/apps/*     │                    │
│  │  │  Ops  ──── userpass ─────► full admin access      │                    │
│  │  └───────────────────────────────────────────────────┘                    │
│  │                                                                           │
└──┴───────────────────────────────────────────────────────────────────────────┘
```

## Architecture

```
                                ┌──────────────┐
                                │   GitHub     │
                                │   Actions    │
                                └──────┬───────┘
                                       │ AppRole auth
                                       ▼
┌──────────────┐  K8s SA Token  ┌──────────────┐  Consul protocol  ┌──────────┐
│  Kubernetes  │ ─────────────► │    Vault     │ ◄───────────────► │  Consul  │
│  (External   │                │   Server     │   (storage)       │  Agent   │
│   Secrets    │                │   :8200      │                   │  :8500   │
│   Operator)  │                └──────┬───────┘                   └──────────┘
└──────────────┘                       │
                                       │ Terraform
                                       │ provisioning
                                ┌──────▼───────┐
                                │  terraform/  │
                                │  *.tf files  │
                                └──────────────┘
```

## Components

| Component | Path | Description |
|---|---|---|
| Docker Compose | `docker/` | Vault server + Consul backend. `docker-compose up` starts the full stack. |
| Vault config | `docker/vault/config.hcl` | Listener, storage, telemetry, and lease defaults. TLS disabled for local dev. |
| Consul config | `docker/consul/config.json` | Single-node Consul agent for Vault's storage backend. |
| Terraform modules | `terraform/` | Secrets engines, auth methods, and policies — all provisioned as code. |
| HCL policies | `terraform/policies/` | Three tiered policies: `ci-cd`, `app`, `admin`. |
| K8s manifests | `k8s/` | External Secrets Operator: SecretStore, ClusterSecretStore, ExternalSecret. |
| Init scripts | `scripts/init-vault.sh` | Idempotent initialization, unseal, and audit log enablement. |
| Seed scripts | `scripts/seed-secrets.sh` | Populate KV v2 with example secrets for testing. |
| K8s auth setup | `scripts/setup-k8s-auth.sh` | Configure Vault Kubernetes auth method with service account and RBAC. |
| Rotation scripts | `scripts/rotate-secrets.sh` | Automated secret rotation for KV v2 secrets on a schedule. |
| CI auth helper | `scripts/ci-auth.sh` | AppRole authentication helper for CI/CD pipelines. |
| Policy validation | `scripts/validate-policies.sh` | Validates HCL policy syntax before apply. |
| Integration tests | `tests/test-vault-setup.sh` | End-to-end test: init, provision, auth, read secrets flow. |
| CI pipeline | `.github/workflows/vault-ci.yml` | Terraform validate, shellcheck, YAML lint on every push. |
| CI example | `examples/github-actions-vault.yml` | Reference GitHub Actions workflow showing Vault integration. |

## Quick Start

Prerequisites: Docker 24+, Docker Compose v2, Terraform 1.5+, `vault` CLI, `jq`, `curl`.

```bash
# 1. Clone and configure.
git clone https://github.com/shivajichaprana/vault-secrets-manager.git
cd vault-secrets-manager
cp .env.example .env

# 2. Start Vault and Consul.
docker compose -f docker/docker-compose.yml up -d

# 3. Initialize, unseal, and enable audit logging.
export VAULT_ADDR=http://127.0.0.1:8200
./scripts/init-vault.sh

# 4. Seed example secrets for testing.
source .env && ./scripts/seed-secrets.sh

# 5. Provision secrets engines, auth methods, and policies via Terraform.
cd terraform
export VAULT_TOKEN="$(cat ../.vault-init/root-token)"
terraform init && terraform apply -auto-approve
cd ..

# 6. Verify everything works.
make validate
```

The Vault UI is available at [http://127.0.0.1:8200/ui](http://127.0.0.1:8200/ui) once the stack is running.

## Auth Methods

| Method | Mount Path | Consumer | Token TTL | Use Case |
|---|---|---|---|---|
| AppRole | `approle/` | CI/CD pipelines | 15 min (max 30 min) | GitHub Actions, Jenkins, GitLab CI authenticate with role ID + secret ID |
| Kubernetes | `kubernetes/` | Pods | 1 hr (max 4 hr) | External Secrets Operator syncs Vault secrets into K8s Secrets |
| userpass | `userpass/` | Human operators | 1 hr (max 8 hr) | On-call engineers and platform admins (pair with MFA in prod) |

## Secrets Engines

| Engine | Mount Path | Lease TTL | Description |
|---|---|---|---|
| KV v2 | `secret/` | n/a (versioned) | Static secrets with 10-version history and rollback support |
| AWS | `aws/` | 30 min (max 1 hr) | Dynamic IAM credentials scoped per role. Root creds stored out-of-band. |
| Database | `database/` | 1 hr (max 24 hr) | Dynamic PostgreSQL credentials with per-role SQL grants |

## Policy Reference

Three tiered policies enforce least-privilege access:

**CI/CD** (`ci-cd-policy.hcl`) — Read-only access to `secret/data/ci/*` and `secret/data/shared/ci/*`. Can request AWS credentials from the `readonly-sample` role. Cannot list secrets outside its prefix or write any data.

**Application** (`app-policy.hcl`) — Read-only access to `secret/data/apps/*` and `secret/data/shared/apps/*`. Can request database credentials from `app-readwrite` and `app-readonly` roles. Pre-wired for transit encrypt/decrypt. Cannot touch CI paths or admin endpoints.

**Admin** (`admin-policy.hcl`) — Full CRUD on all secrets engines, auth methods, policies, audit devices, and leases. Break-glass access for platform operators. Must be paired with MFA and short-lived tokens in production.

## Makefile Targets

```
make up              # Start Docker Compose stack
make down            # Stop and remove containers
make init-vault      # Initialize and unseal Vault
make provision       # Run Terraform apply
make validate        # Terraform validate + fmt check + shellcheck + YAML lint
make test            # Run integration tests
make rotate          # Execute secret rotation
```

## Repository Layout

```
.
├── docker/
│   ├── docker-compose.yml          Vault + Consul Docker Compose stack
│   ├── vault/config.hcl            Vault server configuration
│   └── consul/config.json          Consul agent configuration
├── terraform/
│   ├── main.tf                     Provider and locals
│   ├── secrets-engines.tf          KV v2, AWS, Database engine setup
│   ├── auth-methods.tf             AppRole, Kubernetes, userpass auth
│   ├── policies.tf                 Policy resource definitions
│   ├── database-rotation.tf        Database credential rotation config
│   ├── variables.tf                Input variables with validation
│   ├── outputs.tf                  Provisioned resource outputs
│   ├── versions.tf                 Required provider versions
│   └── policies/
│       ├── ci-cd-policy.hcl        CI/CD pipeline access (read-only)
│       ├── app-policy.hcl          Application workload access
│       └── admin-policy.hcl        Platform admin break-glass access
├── k8s/
│   ├── service-account.yaml        Vault auth service account
│   └── external-secrets/
│       ├── secret-store.yaml       Namespace-scoped SecretStore
│       ├── cluster-secret-store.yaml  Cluster-wide SecretStore
│       └── external-secret-example.yaml  Sample ExternalSecret CR
├── scripts/
│   ├── init-vault.sh               Initialize + unseal + audit
│   ├── seed-secrets.sh             Populate KV v2 with test data
│   ├── setup-k8s-auth.sh           Configure Vault K8s auth
│   ├── rotate-secrets.sh           KV secret rotation
│   ├── ci-auth.sh                  AppRole CI authentication helper
│   └── validate-policies.sh        HCL policy syntax validation
├── tests/
│   └── test-vault-setup.sh         Integration test suite
├── examples/
│   └── github-actions-vault.yml    Reference CI workflow with Vault
├── docs/
│   ├── architecture.md             Design decisions and trade-offs
│   └── ci-integration.md           CI/CD integration guide
├── .github/workflows/
│   └── vault-ci.yml                CI pipeline
├── .env.example                    Sample environment variables
├── Makefile                        Operational targets
├── CONTRIBUTING.md                 Contributor guidelines
├── LICENSE                         MIT
└── README.md                       This file
```

## Security Considerations

- **TLS is disabled** in the default Vault listener. This is only acceptable for a single developer laptop. Enable TLS before deploying to any shared environment.
- **Consul runs single-node** (`bootstrap_expect: 1`). Production deployments require at least three Consul servers with gossip and RPC encryption.
- **Root token** — revoke the root token after provisioning the admin policy and creating a named operator account. The init script writes unseal keys and root token to `.vault-init/` which is git-ignored.
- **Audit logging** is enabled by default. Ship audit logs from `/vault/logs/audit.log` to your SIEM.
- **Secret ID TTL** for AppRole is set to 10 minutes. CI orchestrators should generate a fresh secret ID per pipeline run.

## License

MIT. See [LICENSE](./LICENSE).
