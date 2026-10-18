#!/usr/bin/env bash
# ==============================================================================
# Option 1 - Step 3: 03-deploy-cymbal-stateless.sh
# 1. Creates namespace 'cymbal-storefront' and 100Gi ReadWriteMany PVC
#    ('cymbal-shared-assets-pvc') backed by Regional Private Cloud Filestore (2000 IOPS, NFSv4.1)
# 2. Waits for the Cloud Filestore instance & PVC to reach 'Bound' state
# 3. Deploys the 3-replica stateless Cymbal Retail Storefront web app + Route
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
echo " Option 1 (Filestore) Step 3: Deploying Cymbal Retail Storefront (Stateless)"
echo "=============================================================================="

# 1. Apply Namespace and ReadWriteMany PVC
echo "--- 1. Creating namespace 'cymbal-storefront' and ReadWriteMany PVC ---"
oc apply -f "${MANIFEST_DIR}/03-cymbal-filestore-pvc.yaml"

echo ""
echo "--- 2. Waiting for Regional Cloud Filestore PVC 'cymbal-shared-assets-pvc' (100Gi, 2000 IOPS, NFSv4.1) to Bind ---"
echo "NOTE: Google Cloud Regional Filestore provisioning typically takes 10-15 minutes."
while true; do
  PVC_PHASE="$(oc get pvc cymbal-shared-assets-pvc -n cymbal-storefront -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")"
  if [[ "${PVC_PHASE}" == "Bound" ]]; then
    echo "[BOUND] PVC 'cymbal-shared-assets-pvc' is Bound to Regional Cloud Filestore!"
    break
  fi
  echo "  [$(date -u +%H:%M:%S)] PVC status: ${PVC_PHASE} (waiting 20s)..."
  sleep 20
done

# 2. Deploy 3-replica Cymbal Retail Storefront Application
echo ""
echo "--- 3. Deploying 3-replica Cymbal Retail Storefront Application & Route ---"
oc apply -f "${MANIFEST_DIR}/04-cymbal-stateless-app.yaml"
oc rollout restart deployment/cymbal-storefront-web -n cymbal-storefront

echo "--- 4. Waiting for 3 Cymbal Storefront replicas to become Ready ---"
oc rollout status deployment/cymbal-storefront-web -n cymbal-storefront --timeout=180s

ROUTE_HOST="$(oc get route cymbal-storefront -n cymbal-storefront -o jsonpath='{.spec.host}')"

echo ""
echo "=============================================================================="
echo " Option 1: Cymbal Retail Storefront (Stateless + Filestore RWX) Deployed!"
echo "=============================================================================="
oc get pvc,pods,route -n cymbal-storefront -o wide
echo ""
echo " Storefront URL : https://${ROUTE_HOST}"
echo ""
echo " To access from your LOCAL WORKSTATION browser:"
echo "   1. On your Local Workstation, run: ./scripts/06-access-and-test.sh hosts"
echo "   2. Start the tunnel (if not running): ./scripts/06-access-and-test.sh tunnel"
echo "   3. Open: https://${ROUTE_HOST}"
echo "=============================================================================="
