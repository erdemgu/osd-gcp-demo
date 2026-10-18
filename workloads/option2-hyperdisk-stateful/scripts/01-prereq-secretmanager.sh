#!/usr/bin/env bash
# ==============================================================================
# Option 2 - Step 1: 01-prereq-secretmanager.sh
# Configures Google Cloud Secret Manager for the Cymbal Stateful Workload:
#   1. Enables secretmanager.googleapis.com on ${PROJECT_ID}
#   2. Grants roles/secretmanager.admin & roles/secretmanager.secretAccessor
#      to ${SA_EMAIL}
#   3. Creates two secrets in Google Cloud Secret Manager:
#      - ${PREFIX}-cymbal-db-password
#      - ${PREFIX}-cymbal-api-key
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

DB_SECRET_NAME="${PREFIX}-cymbal-db-password"
API_SECRET_NAME="${PREFIX}-cymbal-api-key"

echo "=============================================================================="
echo " Option 2 Step 1: Configuring Google Cloud Secret Manager"
echo "   Project ID : ${PROJECT_ID}"
echo "   Secrets    : ${DB_SECRET_NAME}, ${API_SECRET_NAME}"
echo "=============================================================================="

# Ensure user is authenticated with a privileged GCP user account (not just the
# Bastion VM's attached service account, which lacks Project IAM Admin / Service Usage Admin)
ACTIVE_GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "${ACTIVE_GCLOUD_ACCOUNT}" || "${ACTIVE_GCLOUD_ACCOUNT}" == "${SA_EMAIL}" || "${ACTIVE_GCLOUD_ACCOUNT}" == *".iam.gserviceaccount.com" ]]; then
  echo "--- Step 0: GCP User Authentication Required on Bastion VM ---"
  echo "Current gcloud account is '${ACTIVE_GCLOUD_ACCOUNT:-none}' (Bastion Service Account)."
  echo "Enabling Secret Manager API and granting IAM roles require your GCP user account."
  echo "Running: gcloud auth login"
  gcloud auth login
fi
gcloud config set project "${PROJECT_ID}" >/dev/null 2>&1 || true

# 1. Enable Secret Manager API
echo "--- 1. Enabling secretmanager.googleapis.com ---"
gcloud services enable secretmanager.googleapis.com --project="${PROJECT_ID}"

# 2. Grant Secret Manager IAM roles to Bastion/Workload Service Account
echo "--- 2. Granting Secret Manager IAM roles to ${SA_EMAIL} ---"
for role in "roles/secretmanager.admin" "roles/secretmanager.secretAccessor"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

# 2b. Bind WIF WorkloadIdentityUser on ${SA_EMAIL} for Secret Manager CSI Provider
export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: Not logged into OpenShift cluster. Ensure ~/.kube/config is configured on the Bastion VM."
  exit 1
fi

PD_CREDS_JSON="$(oc get secret gcp-pd-cloud-credentials -n openshift-cluster-csi-drivers -o jsonpath='{.data.service_account\.json}' 2>/dev/null | base64 -d || true)"
WIF_POOL_RESOURCE="$(python3 -c '
import json, re, sys
try:
    data = json.loads(sys.argv[1])
    aud = data.get("audience", "")
    m = re.search(r"(projects/[^/]+/locations/[^/]+/workloadIdentityPools/[^/]+)", aud)
    print(m.group(1) if m else "")
except Exception:
    print("")
' "${PD_CREDS_JSON}")"

if [[ -n "${WIF_POOL_RESOURCE}" ]]; then
  echo "  -> Binding WIF WorkloadIdentityUser on ${SA_EMAIL} for pool '${WIF_POOL_RESOURCE}'..."
  for member in \
    "principalSet://iam.googleapis.com/${WIF_POOL_RESOURCE}/*" \
    "principal://iam.googleapis.com/${WIF_POOL_RESOURCE}/subject/system:serviceaccount:openshift-cluster-csi-drivers:csi-secrets-store-provider-gcp-sa"; do
    for wif_role in "roles/iam.workloadIdentityUser" "roles/iam.serviceAccountTokenCreator"; do
      gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
        --project="${PROJECT_ID}" \
        --role="${wif_role}" \
        --member="${member}" \
        --condition=None \
        --quiet >/dev/null
    done
  done
fi

# Helper to create or update secret in Secret Manager
ensure_secret() {
  local sec_name="$1"
  local sec_val="$2"
  if gcloud secrets describe "${sec_name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "[SKIP] Secret '${sec_name}' already exists in Secret Manager."
  else
    printf "%s" "${sec_val}" | gcloud secrets create "${sec_name}" \
      --replication-policy="automatic" \
      --data-file=- \
      --project="${PROJECT_ID}"
    echo "[CREATED] Secret '${sec_name}' created in Google Cloud Secret Manager."
  fi
}

echo "--- 3. Creating Cymbal Secrets in Google Cloud Secret Manager ---"
ensure_secret "${DB_SECRET_NAME}" "CymbalHyperdiskPg2026!"
ensure_secret "${API_SECRET_NAME}" "cymbal-live-sec-$(openssl rand -hex 8)"

echo ""
echo "=============================================================================="
echo " Google Cloud Secret Manager Prerequisites Complete!"
echo " Next Step: ./scripts/02-deploy-secrets-csi.sh"
echo "=============================================================================="
