#!/usr/bin/env bash
# ==============================================================================
# Option 1 - Step 4: 04-cleanup-option1.sh
# Removes the Cymbal Retail Storefront workload, ReadWriteMany PVC (which
# deletes the dynamically provisioned Regional Cloud Filestore instance),
# and the Filestore StorageClass.
# ==============================================================================
set -euo pipefail

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=============================================================================="
echo " Cleaning up Option 1: Cymbal Retail Storefront & Regional Cloud Filestore"
echo "=============================================================================="

if oc get namespace cymbal-storefront >/dev/null 2>&1; then
  echo "--- Deleting Cymbal Storefront Deployment, Service, Route, and PVC ---"
  oc delete namespace cymbal-storefront --wait=true
  echo "[DELETED] Namespace 'cymbal-storefront' and dynamically provisioned Filestore volume removed."
else
  echo "[SKIP] Namespace 'cymbal-storefront' not found."
fi

if oc get sc filestore-regional-csi >/dev/null 2>&1; then
  oc delete sc filestore-regional-csi
  echo "[DELETED] StorageClass 'filestore-regional-csi'."
fi

echo "=============================================================================="
echo " Option 1 Cleanup Complete!"
echo "=============================================================================="
