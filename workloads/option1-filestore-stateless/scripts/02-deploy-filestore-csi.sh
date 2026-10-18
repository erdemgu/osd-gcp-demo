#!/usr/bin/env bash
# ==============================================================================
# Option 1 - Step 2: 02-deploy-filestore-csi.sh
# 1. Installs the GCP Filestore CSI Driver Operator from Red Hat Operators
# 2. Enables the ClusterCSIDriver (filestore.csi.storage.gke.io)
# 3. Waits for the CSI controller & node pods to become Ready
# 4. Creates the Regional Private Filestore StorageClass (filestore-regional-csi)
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
echo " Option 1 (Filestore) Step 2: Deploying GCP Filestore CSI Driver Operator"
echo "=============================================================================="

# 1. Ensure an AllNamespaces OperatorGroup (spec: {}) exists in openshift-cluster-csi-drivers
#    Note: CSI driver operators in openshift-cluster-csi-drivers require AllNamespaces
#    InstallModeType (empty spec: {}) and do NOT support OwnNamespace (spec.targetNamespaces).
EXISTING_OG="$(oc get operatorgroup -n openshift-cluster-csi-drivers -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${EXISTING_OG}" ]]; then
  echo "[CREATE] Creating AllNamespaces OperatorGroup in openshift-cluster-csi-drivers..."
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-csi-drivers
  namespace: openshift-cluster-csi-drivers
spec: {}
EOF
else
  OG_TARGETS="$(oc get operatorgroup "${EXISTING_OG}" -n openshift-cluster-csi-drivers -o jsonpath='{.spec.targetNamespaces}' 2>/dev/null || true)"
  if [[ -n "${OG_TARGETS}" && "${OG_TARGETS}" != "[]" ]]; then
    echo "[FIX] OperatorGroup '${EXISTING_OG}' has targetNamespaces=${OG_TARGETS} (OwnNamespace mode)."
    echo "      Patching '${EXISTING_OG}' to AllNamespaces mode (spec: {})..."
    oc patch operatorgroup "${EXISTING_OG}" -n openshift-cluster-csi-drivers --type=merge -p '{"spec":{"targetNamespaces":null}}'
    for csv in $(oc get csv -n openshift-cluster-csi-drivers --no-headers 2>/dev/null | awk '/Failed/ {print $1}'); do
      echo "      Deleting failed CSV '${csv}' to trigger clean OLM reinstall..."
      oc delete csv "${csv}" -n openshift-cluster-csi-drivers --ignore-not-found
    done
  else
    echo "[OK] Existing AllNamespaces OperatorGroup '${EXISTING_OG}' found in openshift-cluster-csi-drivers."
  fi
fi

# 2. Apply Subscription and ClusterCSIDriver
echo "--- Applying GCP Filestore CSI Driver Subscription & ClusterCSIDriver ---"
oc apply -f "${MANIFEST_DIR}/01-filestore-csi-operator.yaml"

# 3. Wait for the GCP Filestore CSI Driver controller pod to be running
echo "--- Waiting for gcp-filestore-csi-driver-controller pod to become Ready (up to 3 mins) ---"
for ((i=1; i<=36; i++)); do
  if oc get pods -n openshift-cluster-csi-drivers 2>/dev/null | grep -q "gcp-filestore-csi-driver-controller.*Running"; then
    echo "[READY] GCP Filestore CSI Driver controller pod is Running!"
    break
  fi
  echo "  Waiting for Filestore CSI Driver pods (attempt ${i}/36)..."
  sleep 5
done

# 4. Render and apply Regional Private Filestore StorageClass
echo "--- Creating StorageClass 'filestore-regional-csi' (tier: regional, 100Gi, 2000 IOPS, NFS_V4_1, PRIVATE_SERVICE_ACCESS) ---"
python3 - "${MANIFEST_DIR}/02-filestore-storageclass.yaml.tpl" << 'PYEOF' | oc apply -f -
import os, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
for var in ("PROJECT_ID", "VPC_NAME"):
    content = content.replace(f"${{{var}}}", os.environ[var])
print(content)
PYEOF

echo ""
echo "=============================================================================="
echo " GCP Filestore CSI Driver & Regional StorageClass Ready!"
echo "=============================================================================="
oc get sc filestore-regional-csi
echo ""
echo "Next Step: ./scripts/03-deploy-cymbal-stateless.sh"
