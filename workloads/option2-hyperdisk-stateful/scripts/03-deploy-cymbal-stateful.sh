#!/usr/bin/env bash
# ==============================================================================
# Option 2 - Step 3: 03-deploy-cymbal-stateful.sh
# 1. Applies the Hyperdisk Balanced StorageClass (hyperdisk-balanced-csi)
# 2. Creates namespace 'cymbal-stateful' and renders SecretProviderClass
#    ('cymbal-gcp-secrets') connected to Google Cloud Secret Manager
# 3. Deploys Cymbal Order & Inventory Ledger PostgreSQL StatefulSet (20Gi
#    Hyperdisk Balanced PVC + Secret Manager CSI mount) and Web UI Route
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

if [[ -f "${HOME}/osd-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/osd-setup/config.env"
elif [[ -f "${SCRIPT_DIR}/../../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../../config.env"
else
  echo "ERROR: config.env not found."
  exit 1
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: Not logged into OpenShift cluster. Ensure ~/.kube/config is configured on the Bastion VM."
  exit 1
fi

echo "=============================================================================="
echo " Option 2 Step 3: Deploying Cymbal Stateful Ledger (Hyperdisk + Secret Manager)"
echo "=============================================================================="

# 1. Detect worker node machine series and configure StorageClass 'hyperdisk-balanced-csi'
#    Note: Google Cloud 'hyperdisk-balanced' is only supported on newer machine series
#    (n4-*, c4-*, m4-*, c3-*, c3d-*, a3-*). On N1 (custom-*), N2 (n2-*), or E2 (e2-*)
#    workers, GCP returns 'Error 400: hyperdisk-balanced disk type cannot be used by <type>',
#    so we automatically fall back to 'pd-balanced'.
WORKER_TYPES="$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra' \
  -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)"

DISK_TYPE="hyperdisk-balanced"
if [[ -n "${WORKER_TYPES}" ]] && ! echo "${WORKER_TYPES}" | grep -Eq '\b(n4|c4|m4|c3|c3d|a3|h3)-'; then
  DISK_TYPE="pd-balanced"
  echo "[INFO] Detected worker node type(s): '${WORKER_TYPES}' (does not support hyperdisk-balanced)."
  echo "       Automatically configuring StorageClass 'hyperdisk-balanced-csi' with 'type: ${DISK_TYPE}'."
else
  echo "[INFO] Detected worker node type(s): '${WORKER_TYPES:-n4-standard-4}' -> using 'type: ${DISK_TYPE}'."
fi

# If StorageClass already exists with a different disk type (or failed attach), recreate it cleanly
EXISTING_SC_TYPE="$(oc get sc hyperdisk-balanced-csi -o jsonpath='{.parameters.type}' 2>/dev/null || true)"
if [[ -n "${EXISTING_SC_TYPE}" && "${EXISTING_SC_TYPE}" != "${DISK_TYPE}" ]]; then
  echo "[FIX] Replacing existing StorageClass 'hyperdisk-balanced-csi' (type=${EXISTING_SC_TYPE} -> ${DISK_TYPE})..."
  oc delete statefulset cymbal-ledger-db -n cymbal-stateful --ignore-not-found
  oc delete pvc cymbal-hyperdisk-data-cymbal-ledger-db-0 -n cymbal-stateful --ignore-not-found --wait=true
  oc delete sc hyperdisk-balanced-csi --ignore-not-found
fi

echo "--- 1. Creating StorageClass 'hyperdisk-balanced-csi' (type: ${DISK_TYPE}) ---"
sed "s/type: hyperdisk-balanced/type: ${DISK_TYPE}/" "${MANIFEST_DIR}/01-hyperdisk-storageclass.yaml" | oc apply -f -

# 2. Create cymbal-stateful Namespace and apply SecretProviderClass
echo "--- 2. Creating namespace 'cymbal-stateful' and SecretProviderClass ---"
oc create namespace cymbal-stateful --dry-run=client -o yaml | oc apply -f -

python3 - "${MANIFEST_DIR}/04-secretproviderclass.yaml.tpl" << 'PYEOF' | oc apply -f -
import os, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
for var in ("PROJECT_ID", "PREFIX"):
    content = content.replace(f"${{{var}}}", os.environ[var])
print(content)
PYEOF

# 3. Deploy Cymbal PostgreSQL StatefulSet (Hyperdisk) & Ledger UI
echo "--- 3. Deploying Cymbal PostgreSQL StatefulSet & Ledger Web UI ---"
oc apply -f "${MANIFEST_DIR}/05-cymbal-stateful-app.yaml"

echo "--- 4. Waiting for Cymbal PostgreSQL StatefulSet (Hyperdisk PVC + Secret Manager CSI) ---"
oc rollout status statefulset/cymbal-ledger-db -n cymbal-stateful --timeout=240s

echo "--- 5. Waiting for Cymbal Ledger Web UI Deployment ---"
oc rollout status deployment/cymbal-ledger-ui -n cymbal-stateful --timeout=180s

ROUTE_HOST="$(oc get route cymbal-ledger -n cymbal-stateful -o jsonpath='{.spec.host}')"

echo ""
echo "=============================================================================="
echo " Option 2: Cymbal Stateful Ledger (Hyperdisk + Secret Manager) Deployed!"
echo "=============================================================================="
oc get pvc,pods,route -n cymbal-stateful -o wide
echo ""
echo " Mounted Secret Manager Files inside PostgreSQL StatefulSet:"
oc exec -n cymbal-stateful statefulset/cymbal-ledger-db -- ls -la /mnt/secrets-store
echo ""
echo " Cymbal Ledger URL : https://${ROUTE_HOST}"
echo ""
echo " To access from your LOCAL WORKSTATION browser:"
echo "   1. On your Local Workstation, run: ./scripts/06-access-and-test.sh hosts"
echo "   2. Start the tunnel (if not running): ./scripts/06-access-and-test.sh tunnel"
echo "   3. Open: https://${ROUTE_HOST}"
echo "=============================================================================="
