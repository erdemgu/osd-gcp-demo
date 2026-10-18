#!/usr/bin/env bash
# ==============================================================================
# Option 1 - Step 1: 01-prereq-filestore-psa.sh
# Configures all Google Cloud & OpenShift Dedicated prerequisites for Regional
# Private Cloud Filestore:
#   1. Enables file.googleapis.com and servicenetworking.googleapis.com
#   2. Grants roles/file.editor, roles/servicenetworking.networksAdmin &
#      roles/compute.networkViewer to ${SA_EMAIL}
#   3. Reserves /20 Private Service Access (PSA) IP range (${PREFIX}-psa-range)
#   4. Connects VPC Peering to servicenetworking.googleapis.com
#   5. Creates gcp-filestore-cloud-credentials secret in openshift-cluster-csi-drivers
#      (Required on OSD WIF clusters where Cloud Credential Operator runs in Manual mode)
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
  echo "ERROR: config.env not found in ~/osd-setup/ or repository root."
  exit 1
fi

export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

PSA_RANGE_NAME="${PREFIX}-psa-range"

echo "=============================================================================="
echo " Option 1 (Filestore) Step 1: Configuring Cloud Filestore & Private Service Access"
echo "   Project ID : ${PROJECT_ID}"
echo "   VPC        : ${VPC_NAME}"
echo "   PSA Range  : ${PSA_RANGE_NAME} (/20)"
echo "=============================================================================="

# Ensure user is authenticated with a privileged GCP user account (not just the
# Bastion VM's attached service account, which lacks Project IAM Admin / Service Usage Admin)
ACTIVE_GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "${ACTIVE_GCLOUD_ACCOUNT}" || "${ACTIVE_GCLOUD_ACCOUNT}" == "${SA_EMAIL}" || "${ACTIVE_GCLOUD_ACCOUNT}" == *".iam.gserviceaccount.com" ]]; then
  echo "--- Step 0: GCP User Authentication Required on Bastion VM ---"
  echo "Current gcloud account is '${ACTIVE_GCLOUD_ACCOUNT:-none}' (Bastion Service Account)."
  echo "Enabling APIs, granting IAM roles, and creating VPC Peering require your GCP user account."
  echo "Running: gcloud auth login"
  gcloud auth login
fi
gcloud config set project "${PROJECT_ID}" >/dev/null 2>&1 || true

# 1. Enable Cloud Filestore & Service Networking APIs
echo "--- 1. Enabling file.googleapis.com and servicenetworking.googleapis.com ---"
gcloud services enable file.googleapis.com servicenetworking.googleapis.com \
  --project="${PROJECT_ID}"

# 2. Grant Filestore & Service Networking IAM roles to Bastion/Workload SA
echo "--- 2. Granting Filestore & Service Networking IAM roles to ${SA_EMAIL} ---"
for role in "roles/file.editor" "roles/servicenetworking.networksAdmin" "roles/compute.networkViewer"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

# 3. Allocate Private Service Access (PSA) IP range in VPC
echo "--- 3. Allocating Private Service Access IP range (${PSA_RANGE_NAME}) ---"
if gcloud compute addresses describe "${PSA_RANGE_NAME}" \
    --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] PSA IP range '${PSA_RANGE_NAME}' already exists."
else
  gcloud compute addresses create "${PSA_RANGE_NAME}" \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length=20 \
    --description="Private Service Access peering range for Cloud Filestore (${PREFIX})" \
    --network="${VPC_NAME}" \
    --project="${PROJECT_ID}"
  echo "[CREATED] Allocated /20 PSA range '${PSA_RANGE_NAME}'."
fi

# 4. Connect Service Networking VPC Peering
echo "--- 4. Connecting VPC Peering to servicenetworking.googleapis.com ---"
if gcloud services vpc-peerings list \
    --network="${VPC_NAME}" --project="${PROJECT_ID}" 2>/dev/null | grep -q "servicenetworking-googleapis-com"; then
  echo "[UPDATE] Updating existing servicenetworking VPC peering with range '${PSA_RANGE_NAME}'..."
  gcloud services vpc-peerings update \
    --service=servicenetworking.googleapis.com \
    --ranges="${PSA_RANGE_NAME}" \
    --network="${VPC_NAME}" \
    --project="${PROJECT_ID}" \
    --force || true
else
  echo "[CREATE] Creating servicenetworking VPC peering connection..."
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${PSA_RANGE_NAME}" \
    --network="${VPC_NAME}" \
    --project="${PROJECT_ID}"
fi

# 5. Configure keyless WIF secret 'gcp-filestore-cloud-credentials' in openshift-cluster-csi-drivers
echo "--- 5. Configuring keyless WIF secret 'gcp-filestore-cloud-credentials' in openshift-cluster-csi-drivers ---"
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: Not logged into OpenShift cluster. Ensure ~/.kube/config is configured on the Bastion VM."
  exit 1
fi

PD_CREDS_JSON="$(oc get secret gcp-pd-cloud-credentials -n openshift-cluster-csi-drivers -o jsonpath='{.data.service_account\.json}' 2>/dev/null | base64 -d || true)"
if [[ -z "${PD_CREDS_JSON}" ]]; then
  echo "ERROR: Could not read WIF template from secret/gcp-pd-cloud-credentials in openshift-cluster-csi-drivers."
  exit 1
fi

WIF_POOL_RESOURCE="$(python3 -c '
import json, re, sys
data = json.loads(sys.argv[1])
aud = data.get("audience", "")
m = re.search(r"(projects/[^/]+/locations/[^/]+/workloadIdentityPools/[^/]+)", aud)
print(m.group(1) if m else "")
' "${PD_CREDS_JSON}")"

if [[ -z "${WIF_POOL_RESOURCE}" ]]; then
  echo "ERROR: Could not parse Workload Identity Pool from gcp-pd-cloud-credentials audience."
  exit 1
fi

echo "  -> Binding WIF WorkloadIdentityUser on ${SA_EMAIL} for pool '${WIF_POOL_RESOURCE}'..."
for member in \
  "principalSet://iam.googleapis.com/${WIF_POOL_RESOURCE}/*" \
  "principal://iam.googleapis.com/${WIF_POOL_RESOURCE}/subject/system:serviceaccount:openshift-cluster-csi-drivers:gcp-filestore-csi-driver-controller-sa" \
  "principal://iam.googleapis.com/${WIF_POOL_RESOURCE}/subject/system:serviceaccount:openshift-cluster-csi-drivers:gcp-filestore-csi-driver-operator"; do
  for wif_role in "roles/iam.workloadIdentityUser" "roles/iam.serviceAccountTokenCreator"; do
    gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
      --project="${PROJECT_ID}" \
      --role="${wif_role}" \
      --member="${member}" \
      --condition=None \
      --quiet >/dev/null
  done
done

WIF_FILESTORE_JSON="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
sa_email = sys.argv[2]
data["service_account_impersonation_url"] = f"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{sa_email}:generateAccessToken"
print(json.dumps(data, indent=2))
' "${PD_CREDS_JSON}" "${SA_EMAIL}")"

oc create secret generic gcp-filestore-cloud-credentials \
  -n openshift-cluster-csi-drivers \
  --from-literal=service_account.json="${WIF_FILESTORE_JSON}" \
  --dry-run=client -o yaml | oc apply -f -
echo "[CREATED] Keyless WIF secret 'gcp-filestore-cloud-credentials' configured."

echo ""
echo "=============================================================================="
echo " Filestore & Private Service Access Prerequisites Complete!"
echo " Next Step: ./scripts/02-deploy-filestore-csi.sh"
echo "=============================================================================="
