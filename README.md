# vault-secrets-manager

HashiCorp Vault deployment with Kubernetes integration, Terraform provisioning, and automated secret rotation.

This repository provides a reference implementation for running Vault in a production-like configuration with a Consul storage backend, full infrastructure-as-code for policies and auth methods, and first-class integration with Kubernetes via the External Secrets Operator.

## Features

- Docker Compose deployment with Vault + Consul storage backend
- Terraform-provisioned secrets engines (KV v2, AWS, database), auth methods (AppRole, Kubernetes, userpass), and tiered policies (CI/CD, application, admin)
- Kubernetes integration via External Secrets Operator with per-namespace and cluster-wide stores
- Automated secret rotation playbooks for AWS and database credentials
- CI validation of Vault policies and Terraform plans via GitHub Actions
- Idempotent initialization and seeding scripts

## Repository Layout

```
.
├── docker/                    Docker Compose stack (Vault + Consul + UI)
│   ├── docker-compose.yml
│   ├── vault/config.hcl       Vault server configuration
│   └── consul/config.json     Consul agent configuration
├── terraform/                 Vault provisioning (policies, engines, auth)
├── k8s/                       External Secrets Operator manifests
├── scripts/                   Operational scripts
│   ├── init-vault.sh          Init + unseal + enable audit
│   └── seed-secrets.sh        Populate KV v2 with example secrets
├── .env.example               Sample environment file
└── README.md
```

## Quick Start

Prerequisites: Docker 24+, Docker Compose v2, `vault` CLI, `jq`, `curl`.

```bash
# 1. Configure environment.
cp .env.example .env

# 2. Bring up the stack (Vault + Consul).
docker compose -f docker/docker-compose.yml up -d

# 3. Initialize and unseal Vault, enable audit logging.
export VAULT_ADDR=http://127.0.0.1:8200
./scripts/init-vault.sh

# 4. Seed example secrets.
source .env && ./scripts/seed-secrets.sh

# 5. Explore.
open http://127.0.0.1:8200/ui
```

The initialization step writes `.vault/init.json` containing the generated root token and unseal keys. This file is ignored by git and must never be committed. Treat it like any other credential.

## Operational Notes

- The Vault listener in `docker/vault/config.hcl` has TLS disabled. This is only appropriate for a single developer laptop. Enable TLS before running on any shared network.
- The Consul agent in this stack runs single-node (`bootstrap_expect: 1`). For production use, run at least three Consul servers and configure gossip and RPC encryption.
- Audit logs land at `/vault/logs/audit.log` inside the Vault container (mounted on the `vault-logs` named volume). Ship these to your log platform of choice.

## Roadmap

| Day | Area | Status |
|-----|------|--------|
| 19  | Docker Compose deployment                 | done    |
| 20  | Terraform provisioning                    | planned |
| 21  | Kubernetes integration (External Secrets) | planned |
| 22  | Secret rotation + AppRole for CI/CD       | planned |
| 23  | CI pipeline + policy validation           | planned |
| 24  | Documentation + runbooks                  | planned |

## License

MIT. See [LICENSE](./LICENSE).
