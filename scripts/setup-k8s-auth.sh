#\!/usr/bin/env bash
# =============================================================================
# setup-k8s-auth.sh — Configure Vault Kubernetes auth method
# =============================================================================
# This script sets up the Vault Kubernetes authentication method, allowing
# Kubernetes workloads to authenticate to Vault using their service account
# tokens. It:
#   1. Enables the Kubernetes auth method in Vault
#   2. Configures it with the cluster's API server and CA certificate
#   3. Creates Vault roles that map K8s service accounts to Vault policies
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - Vault CLI installed and VAULT_ADDR / VAULT_TOKEN set
#   - k8s/service-account.yaml already applied to the cluster
#
# Usage:
#   export VAULT_ADDR="http://127.0.0.1:8200"
#   export VAULT_TOKEN="<root-or-admin-token>"
#   ./scripts/setup-k8s-auth.sh [--namespace default] [--vault-role app-role]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Default configuration
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-default}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-vault-auth}"
VAULT_K8S_ROLE="${VAULT_K8S_ROLE:-app-role}"
VAULT_CLUSTER_ROLE="${VAULT_CLUSTER_ROLE:-cluster-role}"
VAULT_POLICY="${VAULT_POLICY:-app-policy}"
ADMIN_POLICY="${ADMIN_POLICY:-admin-policy}"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            NAMESPACE="$2"; shift 2 ;;
        --vault-role)
            VAULT_K8S_ROLE="$2"; shift 2 ;;
        --service-account)
            SERVICE_ACCOUNT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--namespace NS] [--vault-role ROLE] [--service-account SA]"
            echo ""
            echo "Options:"
            echo "  --namespace        Kubernetes namespace (default: default)"
            echo "  --vault-role       Vault role name (default: app-role)"
            echo "  --service-account  K8s service account name (default: vault-auth)"
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
log_info "Running preflight checks..."

for cmd in vault kubectl; do
    if \! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

if [[ -z "${VAULT_ADDR:-}" ]]; then
    log_error "VAULT_ADDR is not set. Export it before running this script."
    exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
    log_error "VAULT_TOKEN is not set. Export it before running this script."
    exit 1
fi

log_ok "Preflight checks passed"

# ---------------------------------------------------------------------------
# Step 1: Apply Kubernetes service account and RBAC
# ---------------------------------------------------------------------------
log_info "Applying service account and RBAC manifests..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ -f "${REPO_ROOT}/k8s/service-account.yaml" ]]; then
    kubectl apply -f "${REPO_ROOT}/k8s/service-account.yaml"
    log_ok "Service account and ClusterRoleBinding applied"
else
    log_warn "k8s/service-account.yaml not found — ensure the service account exists"
fi

# ---------------------------------------------------------------------------
# Step 2: Enable Kubernetes auth method in Vault
# ---------------------------------------------------------------------------
log_info "Enabling Kubernetes auth method in Vault..."

if vault auth list 2>/dev/null | grep -q "kubernetes/"; then
    log_warn "Kubernetes auth method already enabled — skipping"
else
    vault auth enable kubernetes
    log_ok "Kubernetes auth method enabled"
fi

# ---------------------------------------------------------------------------
# Step 3: Retrieve cluster connection details
# ---------------------------------------------------------------------------
log_info "Retrieving Kubernetes cluster details..."

# Get the Kubernetes API server address
K8S_HOST="$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')"
log_info "Kubernetes API server: ${K8S_HOST}"

# Get the cluster CA certificate
K8S_CA_CERT="$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)"

# Get the service account JWT token (for Vault to use when validating tokens)
# For K8s 1.24+, we create a long-lived token via a Secret
SA_SECRET_NAME="${SERVICE_ACCOUNT}-token"

# Check if a token secret already exists
if \! kubectl get secret "$SA_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_info "Creating long-lived token for service account..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SERVICE_ACCOUNT}
type: kubernetes.io/service-account-token
EOF
    # Wait for the token to be populated by the controller
    sleep 3
fi

SA_JWT_TOKEN="$(kubectl get secret "$SA_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)"

if [[ -z "$SA_JWT_TOKEN" ]]; then
    log_error "Failed to retrieve service account JWT token"
    exit 1
fi

log_ok "Cluster details retrieved"

# ---------------------------------------------------------------------------
# Step 4: Configure Vault Kubernetes auth method
# ---------------------------------------------------------------------------
log_info "Configuring Vault Kubernetes auth backend..."

vault write auth/kubernetes/config \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$K8S_CA_CERT" \
    token_reviewer_jwt="$SA_JWT_TOKEN" \
    issuer="https://kubernetes.default.svc.cluster.local"

log_ok "Vault Kubernetes auth backend configured"

# ---------------------------------------------------------------------------
# Step 5: Create Vault roles for Kubernetes auth
# ---------------------------------------------------------------------------
log_info "Creating Vault role '${VAULT_K8S_ROLE}' for namespace '${NAMESPACE}'..."

vault write "auth/kubernetes/role/${VAULT_K8S_ROLE}" \
    bound_service_account_names="$SERVICE_ACCOUNT" \
    bound_service_account_namespaces="$NAMESPACE" \
    policies="$VAULT_POLICY" \
    ttl="1h" \
    max_ttl="24h"

log_ok "Vault role '${VAULT_K8S_ROLE}' created"

# Create a cluster-wide role for the ClusterSecretStore
log_info "Creating Vault cluster role '${VAULT_CLUSTER_ROLE}'..."

vault write "auth/kubernetes/role/${VAULT_CLUSTER_ROLE}" \
    bound_service_account_names="$SERVICE_ACCOUNT" \
    bound_service_account_namespaces="vault,default,team-backend" \
    policies="${VAULT_POLICY},${ADMIN_POLICY}" \
    ttl="1h" \
    max_ttl="24h"

log_ok "Vault cluster role '${VAULT_CLUSTER_ROLE}' created"

# ---------------------------------------------------------------------------
# Step 6: Verify the configuration
# ---------------------------------------------------------------------------
log_info "Verifying Kubernetes auth configuration..."

# Verify auth method is configured
VAULT_K8S_CONFIG="$(vault read -format=json auth/kubernetes/config 2>/dev/null || true)"
if [[ -n "$VAULT_K8S_CONFIG" ]]; then
    log_ok "Kubernetes auth config verified"
else
    log_error "Failed to read Kubernetes auth config"
    exit 1
fi

# Verify roles exist
for role in "$VAULT_K8S_ROLE" "$VAULT_CLUSTER_ROLE"; do
    if vault read "auth/kubernetes/role/${role}" &>/dev/null; then
        log_ok "Role '${role}' verified"
    else
        log_error "Role '${role}' not found"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Vault Kubernetes Auth Setup Complete"
echo "============================================="
echo ""
echo "  Auth method:     kubernetes"
echo "  K8s API server:  ${K8S_HOST}"
echo "  Service account: ${SERVICE_ACCOUNT} (ns: ${NAMESPACE})"
echo "  Vault roles:"
echo "    - ${VAULT_K8S_ROLE}  → policy: ${VAULT_POLICY}"
echo "    - ${VAULT_CLUSTER_ROLE} → policies: ${VAULT_POLICY}, ${ADMIN_POLICY}"
echo ""
echo "  Next steps:"
echo "    1. Install External Secrets Operator:"
echo "       helm install external-secrets external-secrets/external-secrets \\"
echo "         --namespace external-secrets --create-namespace"
echo "    2. Apply SecretStore manifests:"
echo "       kubectl apply -f k8s/external-secrets/"
echo "    3. Verify secret sync:"
echo "       kubectl get externalsecrets"
echo ""
