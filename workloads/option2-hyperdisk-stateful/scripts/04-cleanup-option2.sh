#!/usr/bin/env bash
# ==============================================================================
# Option 2 - Step 4: 04-cleanup-option2.sh
# Removes the Cymbal Stateful Ledger workload, Hyperdisk Balanced PVC,
# StorageClass, and Google Cloud Secret Manager secrets.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${HOME}/osd-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/osd-setup/config.env"
elif [[ -f "${SCRIPT_DIR}/../../../config.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../../config.env"
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

echo "=============================================================================="
echo " Cleaning up Option 2: Cymbal Stateful Ledger, Hyperdisk PVC & Secrets"
echo "=============================================================================="

if oc get namespace cymbal-stateful >/dev/null 2>&1; then
  echo "--- Deleting namespace 'cymbal-stateful' (StatefulSet, Hyperdisk PVC, Route) ---"
  oc delete namespace cymbal-stateful --wait=true
  echo "[DELETED] Namespace 'cymbal-stateful' and Hyperdisk volume removed."
else
  echo "[SKIP] Namespace 'cymbal-stateful' not found."
fi

if oc get sc hyperdisk-balanced-csi >/dev/null 2>&1; then
  oc delete sc hyperdisk-balanced-csi
  echo "[DELETED] StorageClass 'hyperdisk-balanced-csi'."
fi

if [[ -n "${PROJECT_ID:-}" && -n "${PREFIX:-}" ]]; then
  for sec in "${PREFIX}-cymbal-db-password" "${PREFIX}-cymbal-api-key"; do
    if gcloud secrets describe "${sec}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
      gcloud secrets delete "${sec}" --project="${PROJECT_ID}" --quiet
      echo "[DELETED] Secret '${sec}' from Google Cloud Secret Manager."
    fi
  done
fi

echo "=============================================================================="
echo " Option 2 Cleanup Complete!"
echo "=============================================================================="
