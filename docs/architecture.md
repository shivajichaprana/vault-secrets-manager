# Architecture Decisions

This document captures the key design choices behind the vault-secrets-manager project and the trade-offs considered at each decision point.

## Storage Backend: Consul

**Decision:** Use Consul as the Vault storage backend instead of the integrated Raft storage, S3, or DynamoDB.

**Context:** Vault supports over a dozen storage backends. The three most common production options are Consul, Raft (integrated storage), and cloud-managed stores (S3, DynamoDB, GCS). Each has distinct operational characteristics.

**Why Consul:**

- Consul provides active health checking of Vault nodes and automatic leader election via session-based locking, giving us high-availability semantics without additional orchestration.
- The Consul UI offers direct visibility into the key-value entries Vault writes (under the `vault/` prefix), which is valuable during development and troubleshooting.
- Consul's gossip protocol handles membership and failure detection, so Vault nodes can join and leave the cluster without manual intervention.
- Running Consul alongside Vault is a well-trodden pattern with extensive community documentation and battle-tested operational runbooks.

**Why not Raft:** Raft (integrated storage) eliminates the Consul dependency and is the recommended backend for new deployments as of Vault 1.4+. It simplifies the stack but removes the independent health-checking and service-mesh capabilities that Consul provides. For this reference project, the Consul backend was chosen to demonstrate a production-like multi-component deployment. Teams that want a simpler operational model should evaluate Raft.

**Why not S3/DynamoDB:** Cloud-managed backends are attractive for serverless or fully-managed deployments, but they introduce cloud provider lock-in and have higher read latency for Vault's frequent storage operations. They also lack native HA leader election, requiring a separate DynamoDB table or external coordination for that purpose.

**Trade-offs accepted:** Running Consul means an additional process to monitor, patch, and back up. In the Docker Compose setup, Consul runs as a single node (`bootstrap_expect: 1`), which is not HA. Production deployments must run at least three Consul servers with gossip encryption and ACLs enabled.

## Secrets Delivery: External Secrets Operator

**Decision:** Use the External Secrets Operator (ESO) to sync Vault secrets into native Kubernetes `Secret` objects, rather than the Vault CSI Provider or Vault Agent sidecar injection.

**Context:** There are three primary ways to deliver Vault secrets to Kubernetes pods:

1. **Vault Agent sidecar** — a Vault-aware container injected into each pod that renders secrets to a shared volume.
2. **Vault CSI Provider** — a CSI driver that mounts secrets as files in the pod's filesystem.
3. **External Secrets Operator** — a Kubernetes controller that reads secrets from Vault and writes them into native `Secret` objects.

**Why ESO:**

- ESO produces native Kubernetes `Secret` objects, which means existing workloads that read from environment variables or volume-mounted secrets require zero code changes.
- The `SecretStore` and `ClusterSecretStore` custom resources decouple the Vault connection configuration from individual workloads. A platform team configures the store once; application teams reference it in their `ExternalSecret` CRs without knowing Vault connection details.
- ESO supports multiple secret backends (Vault, AWS Secrets Manager, GCP Secret Manager, Azure Key Vault) through a single API surface. Teams that migrate between providers only change the `SecretStore` definition.
- Refresh intervals on `ExternalSecret` resources ensure secrets are periodically re-synced, picking up rotations without pod restarts.

**Why not Vault Agent sidecar:** The sidecar model adds a container to every pod, increasing memory overhead and complicating pod startup ordering (the application must wait for secrets to be rendered before starting). It also requires the Vault Agent Injector mutating webhook, which is another component to maintain.

**Why not Vault CSI Provider:** CSI-based delivery mounts secrets as files, which works well for TLS certificates and configuration files but is less ergonomic for environment-variable-based applications. It also does not create Kubernetes `Secret` objects, so any workload that expects `secretKeyRef` in its environment definition would need refactoring.

**Trade-offs accepted:** ESO writes secrets into Kubernetes `Secret` objects, which are base64-encoded (not encrypted) in etcd by default. Teams must enable etcd encryption at rest or use a KMS provider to protect secrets stored in the cluster. The refresh interval also introduces a delay between a secret being updated in Vault and the corresponding Kubernetes `Secret` being refreshed (configurable, default 1 hour).

## Auth Strategy: Three Tiers

**Decision:** Provision three distinct auth methods (AppRole, Kubernetes, userpass) with dedicated policies for each consumer type.

**Context:** Vault supports a wide range of auth methods. Rather than enabling a single method and sharing policies, this project provisions one method per consumer archetype to enforce clear access boundaries.

**Why three methods:**

- **AppRole for CI/CD** — pipelines are non-interactive and short-lived. AppRole's role ID + secret ID model fits this pattern: the role ID is stable and can be stored in CI configuration, while the secret ID is single-use and minted just-in-time by a privileged orchestrator. Token TTLs are capped at 30 minutes.
- **Kubernetes for pods** — pods authenticate using their projected service account token, which Vault validates against the Kubernetes API. This eliminates the need to distribute any Vault credential to pods; the service account token is already available in every pod. Token TTLs are 1 hour with renewal.
- **userpass for humans** — operators authenticate with a username and password. In production, this should be replaced with OIDC/SAML backed by the organization's identity provider, with MFA enforced. The userpass method is used here as a minimal, self-contained alternative for the reference setup.

**Policy design:** Each auth method's role is bound to a specific Vault policy (`ci-cd`, `app`, `admin`). Policies use explicit `deny` rules on paths outside their scope to prevent accidental access if new secrets engines or paths are added later. This defense-in-depth approach ensures that a compromised CI token cannot read application secrets, and an application token cannot access CI-only paths.

**Trade-offs accepted:** Three auth methods mean three sets of configuration to maintain. For small teams, a single OIDC method with group-based policy assignment may be simpler. The three-method approach was chosen here because it clearly demonstrates the distinct authentication patterns for each consumer type.

## Secret Rotation Strategy

**Decision:** Use a combination of Vault's native dynamic secrets (for AWS and database credentials) and a script-based rotation workflow (for static KV secrets).

**Context:** Not all secrets can be dynamically generated. API keys from third-party services, encryption keys, and legacy credentials must be stored as static values and rotated on a schedule.

**Dynamic secrets (AWS, database):** Vault's AWS and database secrets engines generate short-lived credentials on demand. Each consumer gets a unique credential pair with a TTL measured in minutes or hours. When the lease expires, the credential is automatically revoked. This eliminates the need for manual rotation entirely — every read produces a fresh credential.

**Static secrets (KV v2):** For secrets that cannot be dynamically generated, the `scripts/rotate-secrets.sh` script implements a rotation workflow: generate a new value, write it to KV v2 (creating a new version), and verify the write succeeded. KV v2's versioning ensures that the previous value remains available for rollback. The script can be run on a cron schedule or triggered by an external orchestrator.

**Trade-offs accepted:** The script-based rotation for static secrets is not atomic — there is a window between writing the new value to Vault and the consuming application picking it up. For applications using ESO, this window is bounded by the ExternalSecret refresh interval. For CI pipelines, the next run will pick up the new value automatically.

## Infrastructure as Code: Terraform

**Decision:** Provision all Vault configuration (secrets engines, auth methods, policies) via Terraform rather than manual `vault` CLI commands or the UI.

**Why Terraform:**

- All configuration is versioned in Git, providing a complete audit trail of who changed what and when.
- `terraform plan` shows the exact diff before any change is applied, reducing the risk of accidental misconfiguration.
- The same Terraform code can provision Vault in development, staging, and production with environment-specific variables, ensuring consistency across environments.
- Terraform's state tracking detects drift — if someone manually changes a Vault configuration, the next `terraform plan` will flag the difference.

**Why not Vault CLI scripts:** Shell scripts that call `vault write` and `vault policy write` are imperative and non-idempotent by default. Running the same script twice may fail or produce unexpected results. Terraform's declarative model handles idempotency natively.

**Trade-offs accepted:** Terraform state contains sensitive information (mount accessors, policy names, auth backend paths). The state file must be stored securely — either in an encrypted remote backend (S3 + DynamoDB, Terraform Cloud) or encrypted at rest on the local filesystem. The local development setup stores state on disk, which is acceptable for a single-developer laptop but not for shared environments.
