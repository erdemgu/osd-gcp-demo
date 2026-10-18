#!/usr/bin/env bash
# ==============================================================================
# workloads/sync-to-bastion.sh
# Run on your LOCAL WORKSTATION to copy the Phase 2 workloads/ directory and
# config.env to ~/osd-setup/ on the Bastion VM via Cloud IAP SCP.
# ==============================================================================
set -euo pipefail

if [[ "$(hostname)" == *"-vm-bastion"* ]]; then
  echo "ERROR: sync-to-bastion.sh must be run on your LOCAL WORKSTATION, not inside the Bastion VM."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: ${REPO_ROOT}/config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

echo "=============================================================================="
echo " Syncing Phase 2 Workloads to Bastion VM (${BASTION_NAME})"
echo "   Project : ${PROJECT_ID}"
echo "   Zone    : ${ZONE}"
echo "   Target  : ${BASTION_NAME}:~/osd-setup/workloads/"
echo "=============================================================================="

gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="mkdir -p ~/osd-setup/workloads"

gcloud compute scp --recurse --compress \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  "${REPO_ROOT}/config.env" \
  "${REPO_ROOT}/workloads" \
  "${BASTION_NAME}:~/osd-setup/"

gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="chmod +x ~/osd-setup/workloads/option1-filestore-stateless/scripts/*.sh ~/osd-setup/workloads/option2-hyperdisk-stateful/scripts/*.sh ~/osd-setup/workloads/option3-public-waf-ddos/scripts/*.sh"

echo ""
echo "=============================================================================="
echo " Phase 2 & Phase 3 Workloads Synced Successfully!"
echo "=============================================================================="
echo " Next steps inside the Bastion VM (./scripts/06-access-and-test.sh ssh):"
echo ""
echo "   0. Authenticate gcloud with your GCP user account (required once on Bastion"
echo "      to enable APIs and grant IAM roles in 01-prereq-*.sh):"
echo "     gcloud auth login"
echo ""
echo "   Option 1 (Stateless Cymbal Storefront + Regional Private Filestore):"
echo "     cd ~/osd-setup/workloads/option1-filestore-stateless"
echo "     ./scripts/01-prereq-filestore-psa.sh"
echo "     ./scripts/02-deploy-filestore-csi.sh"
echo "     ./scripts/03-deploy-cymbal-stateless.sh"
echo ""
echo "   Option 2 (Stateful Cymbal Order Ledger + Hyperdisk + Secret Manager CSI):"
echo "     cd ~/osd-setup/workloads/option2-hyperdisk-stateful"
echo "     ./scripts/01-prereq-secretmanager.sh"
echo "     ./scripts/02-deploy-secrets-csi.sh"
echo "     ./scripts/03-deploy-cymbal-stateful.sh"
echo ""
echo "   Option 3 (Public Edge Storefront + Cloud Armor WAF/DDoS + Cloud CDN + Global ALB):"
echo "     cd ~/osd-setup/workloads/option3-public-waf-ddos"
echo "     ./scripts/01-deploy-public-workload.sh"
echo "     ./scripts/02-deploy-cloud-armor-and-alb.sh"
echo "     ./scripts/03-test-waf-and-ddos.sh"
echo "=============================================================================="
