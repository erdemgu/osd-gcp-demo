#!/usr/bin/env bash
# ==============================================================================
# 04-bastion-setup.sh
# 1. Renders declarative YAML files (cluster-config.yaml & cluster-admin-rbac.yaml)
# 2. Creates the private Linux Bastion VM (${PREFIX}-vm-bastion) in ${SUBNET_BASTION}
# 3. Waits for SSH readiness via Cloud IAP
# 4. Copies all necessary files (cluster-config.yaml, cluster-admin-rbac.yaml,
#    SA keys, SSH keys, OCM session config, config.env, and 05-bastion-install-osd.sh)
#    to ~/osd-setup/ on the Bastion VM
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

for required_file in "${SSH_KEY_FILE}" "${SSH_KEY_FILE}.pub"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "ERROR: Required file '${required_file}' is missing. Did you run ./scripts/03-iam-and-keys.sh?"
    exit 1
  fi
done

echo "=============================================================================="
echo " Step 1: Generating Declarative YAML Manifests from Templates"
echo "=============================================================================="
RENDERED_CLUSTER_CONFIG="${REPO_ROOT}/generated/cluster-config.yaml"
RENDERED_ADMIN_RBAC="${REPO_ROOT}/generated/cluster-admin-rbac.yaml"

python3 - "${REPO_ROOT}/templates/cluster-config.yaml.tpl" "${RENDERED_CLUSTER_CONFIG}" << 'PYEOF'
import os
import sys

tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, "r", encoding="utf-8") as f:
    content = f.read()

vars_to_replace = [
    "CLUSTER_NAME", "DOMAIN_PREFIX", "OSD_PRODUCT", "SUBSCRIPTION_TYPE", "MARKETPLACE_GCP_TERMS",
    "OSD_VERSION", "REGION", "MULTI_AZ", "PROJECT_ID", "WIF_CONFIG_NAME",
    "SECURE_BOOT_FOR_SHIELDED_VMS", "VPC_NAME",
    "SUBNET_CONTROL_PLANE", "SUBNET_WORKER", "SUBNET_PSC", "VPC_CIDR",
    "COMPUTE_MACHINE_TYPE", "COMPUTE_NODES", "OSD_ADMIN_USER"
]
for var in vars_to_replace:
    content = content.replace(f"${{{var}}}", os.environ.get(var, ""))

with open(out_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
chmod 600 "${RENDERED_CLUSTER_CONFIG}"
echo "[CREATED] Rendered ${RENDERED_CLUSTER_CONFIG}"

python3 - "${REPO_ROOT}/templates/cluster-admin-rbac.yaml.tpl" "${RENDERED_ADMIN_RBAC}" << 'PYEOF'
import os
import sys

tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, "r", encoding="utf-8") as f:
    content = f.read()

for var in ["PREFIX", "OSD_ADMIN_USER"]:
    content = content.replace(f"${{{var}}}", os.environ.get(var, ""))

with open(out_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
chmod 600 "${RENDERED_ADMIN_RBAC}"
echo "[CREATED] Rendered ${RENDERED_ADMIN_RBAC}"

echo ""
echo "=============================================================================="
echo " Step 2: Deploying Private Linux Bastion VM (${BASTION_NAME})"
echo "   Subnet : ${SUBNET_BASTION}"
echo "   Zone   : ${ZONE}"
echo "=============================================================================="
if gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Bastion VM '${BASTION_NAME}' already exists in ${ZONE}."
else
  gcloud compute instances create "${BASTION_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="e2-standard-4" \
    --network-interface="subnet=${SUBNET_BASTION},no-address" \
    --image-family="debian-13" \
    --image-project="debian-cloud" \
    --boot-disk-size="100GB" \
    --boot-disk-type="pd-ssd" \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --service-account="${SA_EMAIL}" \
    --scopes="https://www.googleapis.com/auth/cloud-platform" \
    --tags="osd-bastion"
  echo "[CREATED] Bastion VM '${BASTION_NAME}'."
fi

echo ""
echo "=============================================================================="
echo " Step 3: Waiting for Bastion SSH Readiness via Cloud IAP"
echo "=============================================================================="
MAX_RETRIES=15
for ((i=1; i<=MAX_RETRIES; i++)); do
  if gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="mkdir -p ~/osd-setup" >/dev/null 2>&1; then
    echo "[READY] Bastion VM is reachable via IAP SSH!"
    break
  fi
  echo "  Waiting for SSH daemon on ${BASTION_NAME} (attempt ${i}/${MAX_RETRIES})..."
  sleep 10
  if [[ "${i}" -eq "${MAX_RETRIES}" ]]; then
    echo "ERROR: Timed out waiting for SSH access to ${BASTION_NAME}."
    exit 1
  fi
done

echo ""
echo "=============================================================================="
echo " Step 4: Copying Required OSD Installation & YAML Files to Bastion VM"
echo "=============================================================================="
FILES_TO_COPY=(
  "${REPO_ROOT}/config.env"
  "${RENDERED_CLUSTER_CONFIG}"
  "${RENDERED_ADMIN_RBAC}"
  "${SSH_KEY_FILE}"
  "${SSH_KEY_FILE}.pub"
  "${REPO_ROOT}/scripts/05-bastion-install-osd.sh"
)

# Support both Linux/WSL (~/.config/ocm/ocm.json) and macOS (~/Library/Application Support/ocm/ocm.json)
if [[ -f "${HOME}/.config/ocm/ocm.json" ]]; then
  cp "${HOME}/.config/ocm/ocm.json" "${REPO_ROOT}/generated/ocm.json"
  chmod 600 "${REPO_ROOT}/generated/ocm.json"
  FILES_TO_COPY+=("${REPO_ROOT}/generated/ocm.json")
elif [[ -f "${HOME}/Library/Application Support/ocm/ocm.json" ]]; then
  cp "${HOME}/Library/Application Support/ocm/ocm.json" "${REPO_ROOT}/generated/ocm.json"
  chmod 600 "${REPO_ROOT}/generated/ocm.json"
  FILES_TO_COPY+=("${REPO_ROOT}/generated/ocm.json")
fi

if [[ -d "${REPO_ROOT}/workloads" ]]; then
  FILES_TO_COPY+=("${REPO_ROOT}/workloads")
fi

gcloud compute scp --recurse --compress \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  "${FILES_TO_COPY[@]}" \
  "${BASTION_NAME}:~/osd-setup/"

gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command="chmod 600 ~/osd-setup/config.env ~/osd-setup/*-ssh ~/osd-setup/*.yaml && chmod +x ~/osd-setup/05-bastion-install-osd.sh && if [[ -d ~/osd-setup/workloads ]]; then chmod +x ~/osd-setup/workloads/*.sh ~/osd-setup/workloads/option1-filestore-stateless/scripts/*.sh ~/osd-setup/workloads/option2-hyperdisk-stateful/scripts/*.sh ~/osd-setup/workloads/option3-public-waf-ddos/scripts/*.sh 2>/dev/null || true; fi && if [[ -f ~/osd-setup/ocm.json ]]; then mkdir -p ~/.config/ocm && cp ~/osd-setup/ocm.json ~/.config/ocm/ocm.json && chmod 600 ~/.config/ocm/ocm.json; fi"

echo ""
echo "=============================================================================="
echo " Bastion Setup & File Transfer Complete!"
echo "=============================================================================="
echo " OpenShift Dedicated installation is configured to start from the Bastion VM."
echo ""
echo " 1. SSH into the Bastion VM using the IAP tunnel command:"
echo "    gcloud compute ssh ${BASTION_NAME} --project=\"${PROJECT_ID}\" --zone=\"${ZONE}\" --tunnel-through-iap"
echo ""
echo " 2. Once logged into the Bastion VM, start the OpenShift Dedicated installation:"
echo "    ~/osd-setup/05-bastion-install-osd.sh"
echo "=============================================================================="
