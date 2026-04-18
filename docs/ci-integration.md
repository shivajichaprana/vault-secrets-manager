# CI/CD Integration Guide

This guide walks through integrating HashiCorp Vault into CI/CD pipelines using the AppRole auth method provisioned by this project. Examples cover GitHub Actions, GitLab CI, and Jenkins.

## How It Works

The authentication flow for CI/CD pipelines uses Vault's AppRole method:

```
┌──────────────┐     ┌───────────────┐     ┌──────────────┐
│  CI Pipeline │     │  Orchestrator │     │    Vault     │
│  (runner)    │     │  (privileged) │     │   Server     │
└──────┬───────┘     └───────┬───────┘     └──────┬───────┘
       │                     │                     │
       │  1. Pipeline starts │                     │
       │ ◄───────────────────│                     │
       │                     │                     │
       │                     │  2. Mint secret ID  │
       │                     │ ───────────────────►│
       │                     │                     │
       │                     │  3. Return secret ID│
       │                     │ ◄───────────────────│
       │                     │                     │
       │  4. Inject secret ID│                     │
       │ ◄───────────────────│                     │
       │                     │                     │
       │  5. Login (role ID + secret ID)           │
       │ ─────────────────────────────────────────►│
       │                     │                     │
       │  6. Return token (15 min TTL)             │
       │ ◄─────────────────────────────────────────│
       │                     │                     │
       │  7. Read secrets using token              │
       │ ─────────────────────────────────────────►│
       │                     │                     │
       │  8. Revoke token on completion            │
       │ ─────────────────────────────────────────►│
       │                     │                     │
```

**Role ID** is a stable identifier for the AppRole and can be stored in CI configuration (it is not secret by itself). **Secret ID** is a single-use, time-limited credential minted for each pipeline run. Together they produce a short-lived Vault token scoped to the `ci-cd` policy.

## Prerequisites

Before integrating, ensure the following are in place:

1. Vault is running and the Terraform provisioning has been applied (secrets engines, auth methods, and policies are configured).
2. The `ci-cd` AppRole exists at the `approle/` auth mount.
3. The CI runner can reach the Vault server over the network.
4. The `vault` CLI or `curl` is available on the CI runner (the helper script `scripts/ci-auth.sh` uses `curl` and `jq`).

## Retrieving Role ID and Secret ID

The role ID is a read operation that can be done once and stored:

```bash
vault read -field=role_id auth/approle/role/ci-cd/role-id
```

Secret IDs should be generated per pipeline run by a privileged process:

```bash
vault write -f -field=secret_id auth/approle/role/ci-cd/secret-id
```

The secret ID has a TTL of 10 minutes and is single-use — it can only be exchanged for a token once.

## GitHub Actions

### Using the Helper Script

The simplest integration uses `scripts/ci-auth.sh`, which handles login, secret retrieval, and token revocation:

```yaml
name: deploy
on:
  push:
    branches: [main]

env:
  VAULT_ADDR: ${{ secrets.VAULT_ADDR }}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to Vault and retrieve secrets
        run: |
          # ci-auth.sh logs in via AppRole, reads specified secret paths,
          # and exports them as environment variables.
          ./scripts/ci-auth.sh \
            --role-id "${{ secrets.VAULT_ROLE_ID }}" \
            --secret-id "${{ secrets.VAULT_SECRET_ID }}" \
            --secrets "secret/data/ci/deploy-key,secret/data/ci/docker-registry"
        env:
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}

      - name: Deploy
        run: ./deploy.sh
        # Secrets from Vault are now available as environment variables.
```

### Using curl Directly

For environments where the helper script is not available:

```yaml
      - name: Login to Vault
        id: vault-login
        run: |
          TOKEN=$(curl -s --request POST \
            --data "{\"role_id\": \"${{ secrets.VAULT_ROLE_ID }}\", \"secret_id\": \"${{ secrets.VAULT_SECRET_ID }}\"}" \
            ${VAULT_ADDR}/v1/auth/approle/login | jq -r '.auth.client_token')
          echo "::add-mask::${TOKEN}"
          echo "VAULT_TOKEN=${TOKEN}" >> "$GITHUB_ENV"

      - name: Read secrets
        run: |
          DEPLOY_KEY=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
            ${VAULT_ADDR}/v1/secret/data/ci/deploy-key | jq -r '.data.data.value')
          echo "::add-mask::${DEPLOY_KEY}"
          echo "DEPLOY_KEY=${DEPLOY_KEY}" >> "$GITHUB_ENV"

      - name: Revoke token
        if: always()
        run: |
          curl -s --request POST \
            -H "X-Vault-Token: ${VAULT_TOKEN}" \
            ${VAULT_ADDR}/v1/auth/token/revoke-self || true
```

### Storing Secrets in GitHub

Add the following repository secrets in GitHub Settings > Secrets and variables > Actions:

| Secret | Value | Notes |
|---|---|---|
| `VAULT_ADDR` | `https://vault.example.com:8200` | Use the external Vault URL, not localhost |
| `VAULT_ROLE_ID` | Output of `vault read -field=role_id auth/approle/role/ci-cd/role-id` | Stable, can be stored long-term |
| `VAULT_SECRET_ID` | Minted per run by an orchestrator | Ideally generated just-in-time; for simpler setups, use a longer-TTL secret ID |

## GitLab CI

```yaml
stages:
  - deploy

variables:
  VAULT_ADDR: ${VAULT_ADDR}

deploy:
  stage: deploy
  image: hashicorp/vault:1.15
  script:
    # Login via AppRole.
    - |
      export VAULT_TOKEN=$(vault write -field=token auth/approle/login \
        role_id="${VAULT_ROLE_ID}" \
        secret_id="${VAULT_SECRET_ID}")

    # Read secrets.
    - export DEPLOY_KEY=$(vault kv get -field=value secret/ci/deploy-key)
    - export REGISTRY_PASS=$(vault kv get -field=password secret/ci/docker-registry)

    # Run deployment.
    - ./deploy.sh

    # Revoke token.
    - vault token revoke -self || true
```

Store `VAULT_ADDR`, `VAULT_ROLE_ID`, and `VAULT_SECRET_ID` as masked CI/CD variables in GitLab Settings > CI/CD > Variables.

## Jenkins

### Scripted Pipeline

```groovy
pipeline {
    agent any
    environment {
        VAULT_ADDR = credentials('vault-addr')
    }
    stages {
        stage('Authenticate') {
            steps {
                withCredentials([
                    string(credentialsId: 'vault-role-id', variable: 'ROLE_ID'),
                    string(credentialsId: 'vault-secret-id', variable: 'SECRET_ID')
                ]) {
                    script {
                        def response = sh(
                            script: """
                                curl -s --request POST \
                                    --data '{"role_id": "${ROLE_ID}", "secret_id": "${SECRET_ID}"}' \
                                    ${VAULT_ADDR}/v1/auth/approle/login
                            """,
                            returnStdout: true
                        ).trim()
                        env.VAULT_TOKEN = sh(
                            script: "echo '${response}' | jq -r '.auth.client_token'",
                            returnStdout: true
                        ).trim()
                    }
                }
            }
        }
        stage('Deploy') {
            steps {
                sh '''
                    DEPLOY_KEY=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
                        ${VAULT_ADDR}/v1/secret/data/ci/deploy-key | jq -r '.data.data.value')
                    export DEPLOY_KEY
                    ./deploy.sh
                '''
            }
        }
    }
    post {
        always {
            sh '''
                curl -s --request POST \
                    -H "X-Vault-Token: ${VAULT_TOKEN}" \
                    ${VAULT_ADDR}/v1/auth/token/revoke-self || true
            '''
        }
    }
}
```

Store credentials in Jenkins Credentials Store (Manage Jenkins > Credentials):
- `vault-addr` — Vault server URL
- `vault-role-id` — AppRole role ID (string credential)
- `vault-secret-id` — AppRole secret ID (string credential)

## Security Best Practices

**Short-lived tokens.** The `ci-cd` AppRole is configured with a 15-minute default TTL and 30-minute maximum. Pipelines that run longer should renew their token using `vault token renew` rather than increasing the max TTL.

**Single-use secret IDs.** The AppRole role is configured with `secret_id_num_uses = 1`. Each secret ID can only be exchanged for a token once. If a secret ID is intercepted, it cannot be replayed after the legitimate pipeline has used it.

**Always revoke tokens.** Add a post-build step that calls `vault token revoke-self` regardless of pipeline success or failure. This limits the window during which a leaked token could be used.

**Mask secrets in logs.** Use `::add-mask::` in GitHub Actions, masked variables in GitLab, or Jenkins credentials bindings to prevent secrets from appearing in build logs.

**Network restrictions.** If possible, restrict Vault access to the CIDR ranges of your CI runners using Vault's `bound_cidr_list` on the AppRole role.

**Audit trail.** Vault's audit log records every authentication and secret read with the accessor of the token that performed the operation. Correlate audit entries with CI pipeline run IDs for forensic analysis.

## Troubleshooting

**"permission denied" when reading a secret** — Verify the token's policies with `vault token lookup`. The `ci-cd` policy only grants access to `secret/data/ci/*` and `secret/data/shared/ci/*`. Paths outside these prefixes will return 403.

**"secret ID is expired or not found"** — Secret IDs have a 10-minute TTL. If there is a long delay between minting the secret ID and using it in the pipeline, the ID will have expired. Reduce the delay or increase `secret_id_ttl` in the AppRole configuration.

**"connection refused"** — The CI runner cannot reach the Vault server. Check network connectivity, security groups, and firewall rules. The Vault server listens on port 8200 by default.

**"x509: certificate signed by unknown authority"** — The CI runner does not trust the Vault server's TLS certificate. Either add the CA certificate to the runner's trust store or set `VAULT_SKIP_VERIFY=true` (not recommended for production).
