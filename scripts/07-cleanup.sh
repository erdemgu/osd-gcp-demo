#!/usr/bin/env bash
# ==============================================================================
# 07-cleanup.sh
# Complete Teardown & Cleanup Script (Reverse Order of Creation):
#   1. Destroys the OpenShift Dedicated cluster via OCM (and waits for completion)
#   2. Deletes the OSD WIF configuration (${WIF_CONFIG_NAME})
#   3. Deletes the Bastion VM (${BASTION_NAME})
#   4. Deletes Firewall Rules (${FW_IAP_SSH}, ${FW_INTERNAL}, ${FW_HEALTH_CHECKS})
#   5. Deletes Cloud NAT (${NAT_NAME}) and Cloud Router (${ROUTER_NAME})
#   6. Deletes the 4 Subnets (bastion, psc, worker, control-plane) and Custom VPC (${VPC_NAME})
#   7. Deletes the GCP Service Account (${SA_EMAIL})
#   8. Cleans up local /etc/hosts entries and generated/ artifacts
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Cannot determine resource names to delete."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"
export PATH="${HOME}/bin:$(cd "${REPO_ROOT}/.." && pwd):${PATH}"

echo "=============================================================================="
echo " WARNING: This will permanently delete ALL OSD demo resources for '${PREFIX}'"
echo "   Project ID      : ${PROJECT_ID}"
echo "   OSD Cluster     : ${CLUSTER_NAME}"
echo "   OSD WIF Config  : ${WIF_CONFIG_NAME}"
echo "   Bastion VM      : ${BASTION_NAME} (${ZONE})"
echo "   VPC & Subnets   : ${VPC_NAME}, ${SUBNET_CONTROL_PLANE}, ${SUBNET_WORKER}, ${SUBNET_BASTION}, ${SUBNET_PSC}"
echo "   Cloud NAT/Router: ${NAT_NAME} / ${ROUTER_NAME}"
echo "   GCP Service Acct: ${SA_EMAIL}"
echo "=============================================================================="
read -r -p "Are you sure you want to destroy the OSD cluster and all infrastructure? [y/N]: " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

# 1. Destroy OpenShift Dedicated Cluster via OCM
echo ""
echo "--- Step 1: Destroying OpenShift Dedicated Cluster (${CLUSTER_NAME}) ---"
if command -v ocm >/dev/null 2>&1 && ocm whoami >/dev/null 2>&1; then
  if ocm describe cluster "${CLUSTER_NAME}" >/dev/null 2>&1; then
    CLUSTER_ID="$(ocm describe cluster "${CLUSTER_NAME}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    echo "Deleting OSD cluster '${CLUSTER_NAME}' (ID: ${CLUSTER_ID})..."
    ocm delete cluster "${CLUSTER_ID}"
    echo "Waiting for OCM to finish deprovisioning GCP cluster resources..."
    while ocm describe cluster "${CLUSTER_ID}" >/dev/null 2>&1; do
      STATE="$(ocm describe cluster "${CLUSTER_ID}" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state","uninstalling"))' 2>/dev/null || echo "uninstalling")"
      echo "[$(date -u '+%H:%M:%S UTC')] Cluster state: ${STATE} ..."
      sleep 45
    done
    echo "[DELETED] OSD cluster '${CLUSTER_NAME}' uninstalled."
  else
    echo "[SKIP] OSD cluster '${CLUSTER_NAME}' not found in OCM."
  fi
elif gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Running OSD cluster destroy via Bastion VM..."
  gcloud compute ssh "${BASTION_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --command="~/osd-setup/05-bastion-install-osd.sh destroy" || \
    echo "[WARN] Could not run cluster destroy on Bastion; continuing teardown."
else
  echo "[SKIP] Neither local ocm session nor Bastion VM available to check cluster."
fi

# 2. Delete OSD GCP Workload Identity Federation (WIF) Configuration
echo ""
echo "--- Step 2: Deleting OSD GCP WIF Configuration (${WIF_CONFIG_NAME}) ---"
if command -v ocm >/dev/null 2>&1 && ocm whoami >/dev/null 2>&1; then
  if ocm gcp list wif-configs | awk '{print $2}' | grep -qx "${WIF_CONFIG_NAME}"; then
    WIF_ID="$(ocm gcp list wif-configs | awk -v name="${WIF_CONFIG_NAME}" '$2 == name {print $1}')"
    echo "Deleting WIF configuration '${WIF_CONFIG_NAME}' (ID: ${WIF_ID})..."
    ocm gcp delete wif-config "${WIF_ID}" || echo "[WARN] Could not delete WIF config '${WIF_CONFIG_NAME}'."
    echo "[DELETED] WIF configuration '${WIF_CONFIG_NAME}'."
  else
    echo "[SKIP] WIF configuration '${WIF_CONFIG_NAME}' not found."
  fi
fi

# 3. Delete Bastion VM
echo ""
echo "--- Step 3: Deleting Bastion VM (${BASTION_NAME}) ---"
if gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute instances delete "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Bastion VM '${BASTION_NAME}'."
else
  echo "[SKIP] Bastion VM '${BASTION_NAME}' already deleted."
fi

# 4. Delete Firewall Rules
echo ""
echo "--- Step 4: Deleting Firewall Rules ---"
for fw in "${FW_IAP_SSH}" "${FW_INTERNAL}" "${FW_HEALTH_CHECKS}"; do
  if gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Firewall rule '${fw}'."
  else
    echo "[SKIP] Firewall rule '${fw}' not found."
  fi
done

# 5. Delete Cloud NAT & Cloud Router
echo ""
echo "--- Step 5: Deleting Cloud NAT (${NAT_NAME}) and Cloud Router (${ROUTER_NAME}) ---"
if gcloud compute routers nats describe "${NAT_NAME}" \
    --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers nats delete "${NAT_NAME}" \
    --router="${ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Cloud NAT '${NAT_NAME}'."
else
  echo "[SKIP] Cloud NAT '${NAT_NAME}' not found."
fi

if gcloud compute routers describe "${ROUTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers delete "${ROUTER_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Cloud Router '${ROUTER_NAME}'."
else
  echo "[SKIP] Cloud Router '${ROUTER_NAME}' not found."
fi

# 6. Delete Phase 2 & Phase 3 GCP Resources (Public ALB/WAF/NEGs, PSA IP Range & Secret Manager Secrets) + 4 Subnets & Custom VPC
echo ""
echo "--- Step 6: Deleting Phase 2 & Phase 3 GCP Resources, 4 Subnets, and Custom VPC (${VPC_NAME}) ---"
if [[ -f "${REPO_ROOT}/workloads/option3-public-waf-ddos/scripts/04-cleanup-public-waf.sh" ]]; then
  bash "${REPO_ROOT}/workloads/option3-public-waf-ddos/scripts/04-cleanup-public-waf.sh" || true
fi
for sec in "${PREFIX}-cymbal-db-password" "${PREFIX}-cymbal-api-key"; do
  if gcloud secrets describe "${sec}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud secrets delete "${sec}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Secret '${sec}'."
  fi
done

PSA_RANGE_NAME="${PREFIX}-psa-range"
if gcloud compute addresses describe "${PSA_RANGE_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses delete "${PSA_RANGE_NAME}" --global --project="${PROJECT_ID}" --quiet || true
  echo "[DELETED] PSA IP range '${PSA_RANGE_NAME}'."
fi

for subnet in "${SUBNET_BASTION}" "${SUBNET_PSC}" "${SUBNET_WORKER}" "${SUBNET_CONTROL_PLANE}"; do
  if gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute networks subnets delete "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Subnet '${subnet}'."
  else
    echo "[SKIP] Subnet '${subnet}' not found."
  fi
done

if gcloud compute networks describe "${VPC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks delete "${VPC_NAME}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] VPC '${VPC_NAME}'."
else
  echo "[SKIP] VPC '${VPC_NAME}' not found."
fi

# 7. Delete GCP Service Account
echo ""
echo "--- Step 7: Deleting GCP Service Account (${SA_EMAIL}) ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] GCP Service Account '${SA_EMAIL}'."
else
  echo "[SKIP] GCP Service Account '${SA_EMAIL}' not found."
fi

# 8. Clean up local /etc/hosts and generated files
echo ""
echo "--- Step 8: Cleaning up local /etc/hosts and generated/ files ---"
if [[ -n "${OSD_CONSOLE_HOST:-}" ]] && grep -q "${OSD_CONSOLE_HOST}" /etc/hosts 2>/dev/null; then
  CYMBAL_STOREFRONT_HOST="cymbal-storefront-cymbal-storefront.apps.${OSD_BASE_DOMAIN}"
  CYMBAL_LEDGER_HOST="cymbal-ledger-cymbal-stateful.apps.${OSD_BASE_DOMAIN}"
  sudo sed -i.bak "/${OSD_CONSOLE_HOST}/d; /${OSD_OAUTH_HOST}/d; /${CYMBAL_STOREFRONT_HOST}/d; /${CYMBAL_LEDGER_HOST}/d" /etc/hosts
  sudo rm -f /etc/hosts.bak
  echo "[CLEANED] Removed OSD Console, OAuth, and Cymbal app routes from /etc/hosts."
fi

rm -rf "${REPO_ROOT}/generated"
echo "[CLEANED] Removed local ${REPO_ROOT}/generated directory."
echo ""
echo "=============================================================================="
echo " Teardown & Cleanup Complete!"
echo "=============================================================================="
