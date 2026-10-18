#!/usr/bin/env bash
# ==============================================================================
# 01-policy-check.sh
# Checks and configures GCP Organization Policies via YAML templates and enables
# required Google Cloud APIs for Red Hat OpenShift Dedicated (OSD):
#   1. compute.trustedImageProjects (projects/debian-cloud, projects/rhel-cloud,
#      projects/rhcos-cloud, projects/redhat-marketplace-public, projects/mpi-redhat-marketplace-public)
#   2. iam.allowedPolicyMemberDomains (allowAll: true — required for WIF & Red Hat SRE)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

echo "=============================================================================="
echo " Step 1: Setting active project and enabling required Google Cloud APIs"
echo " Project: ${PROJECT_ID}"
echo "=============================================================================="
gcloud config set project "${PROJECT_ID}"

REQUIRED_APIS=(
  "orgpolicy.googleapis.com"
  "compute.googleapis.com"
  "dns.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "serviceusage.googleapis.com"
  "servicemanagement.googleapis.com"
  "storage.googleapis.com"
  "sts.googleapis.com"
  "cloudapis.googleapis.com"
  "networksecurity.googleapis.com"
)

echo "Enabling APIs: ${REQUIRED_APIS[*]} ..."
gcloud services enable "${REQUIRED_APIS[@]}" --project="${PROJECT_ID}"

mkdir -p "${REPO_ROOT}/generated/policies"

echo ""
echo "=============================================================================="
echo " Step 2: Policy Check #1 - Trusted Image Projects"
echo " Constraint: constraints/compute.trustedImageProjects"
echo " Checking: projects/debian-cloud, projects/rhel-cloud, projects/rhcos-cloud, projects/redhat-marketplace-public, projects/mpi-redhat-marketplace-public"
echo "=============================================================================="
EFFECTIVE_IMAGES="$(gcloud org-policies describe compute.trustedImageProjects \
  --project="${PROJECT_ID}" --effective --format="yaml" 2>/dev/null || true)"

TRUSTED_IMAGES_FILE="${REPO_ROOT}/generated/policies/trusted-images.yaml"
sed "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
  "${REPO_ROOT}/templates/policies/trusted-images.yaml.tpl" > "${TRUSTED_IMAGES_FILE}"

if echo "${EFFECTIVE_IMAGES}" | grep -q "projects/debian-cloud" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/rhel-cloud" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/rhcos-cloud" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/redhat-marketplace-public" && \
   echo "${EFFECTIVE_IMAGES}" | grep -q "projects/mpi-redhat-marketplace-public"; then
  echo "[OK] projects/debian-cloud, projects/rhel-cloud, projects/rhcos-cloud, projects/redhat-marketplace-public, and projects/mpi-redhat-marketplace-public are already allowed."
else
  echo "Applying trusted image YAML policy (${TRUSTED_IMAGES_FILE})..."
  gcloud org-policies set-policy "${TRUSTED_IMAGES_FILE}" --project="${PROJECT_ID}"
fi

echo ""
echo "=============================================================================="
echo " Step 3: Policy Check #2 - Allowed Policy Member Domains (WIF & Red Hat SRE)"
echo " Constraint: constraints/iam.allowedPolicyMemberDomains"
echo "=============================================================================="
DOMAINS_POLICY_FILE="${REPO_ROOT}/generated/policies/allowed-domains.yaml"
sed "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
  "${REPO_ROOT}/templates/policies/allowed-domains.yaml.tpl" > "${DOMAINS_POLICY_FILE}"

echo "Applying YAML policy override (allowAll: true) for iam.allowedPolicyMemberDomains..."
gcloud org-policies set-policy "${DOMAINS_POLICY_FILE}" --project="${PROJECT_ID}"

echo ""
echo "=============================================================================="
echo " Verification Summary of Organization Policies on ${PROJECT_ID}"
echo "=============================================================================="
for policy in \
  compute.trustedImageProjects \
  iam.allowedPolicyMemberDomains; do
  echo "--- Policy: ${policy} ---"
  gcloud org-policies describe "${policy}" --project="${PROJECT_ID}" --effective || true
done

echo ""
echo "Wait ~30-60 seconds for Organization Policy changes to propagate before creating WIF."
echo "Next step: Run ./scripts/02-vpc-setup.sh"
