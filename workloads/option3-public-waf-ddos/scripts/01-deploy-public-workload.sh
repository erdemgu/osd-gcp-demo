#!/usr/bin/env bash
# ==============================================================================
# 01-deploy-public-workload.sh
# Phase 3 Step 1: Deploys the Multi-Zone Cymbal Public Edge Storefront,
# Zero-Trust Kubernetes NetworkPolicy, and NodePort Service (:30080) inside
# the OpenShift Dedicated cluster.
#
# Run inside the Bastion VM!
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"

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
echo " Phase 3 Step 1: Deploying Cymbal Public Edge Workload & Zero-Trust NetworkPolicy"
echo "=============================================================================="

echo "--- 1. Applying Namespace 'cymbal-public' and Zero-Trust NetworkPolicy ---"
oc apply -f "${MANIFEST_DIR}/01-cymbal-public-namespace-netpol.yaml"

echo ""
echo "--- 2. Deploying 3-Zone Cymbal Public Storefront & NodePort Service (:30080) ---"
oc apply -f "${MANIFEST_DIR}/02-cymbal-public-deployment-svc.yaml"

echo ""
echo "--- 3. Waiting for 'cymbal-public-web' Pods to reach Ready across Worker Zones ---"
oc rollout status deployment/cymbal-public-web -n cymbal-public --timeout=180s

echo ""
echo "--- 4. Verifying Pods, Node Placement, NetworkPolicy & NodePort (:30080) ---"
oc get pods -n cymbal-public -o wide
echo ""
oc get svc,networkpolicy -n cymbal-public

echo ""
echo "=============================================================================="
echo " [SUCCESS] Cymbal Public Workload is Ready on NodePort :30080!"
echo " Next step: Run ./scripts/02-deploy-cloud-armor-and-alb.sh"
echo "=============================================================================="
