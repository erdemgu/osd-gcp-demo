#!/usr/bin/env bash
# ==============================================================================
# 00-prereq-config.sh
# Interactive Prerequisite Check & Environment Configuration Generator
# for Red Hat OpenShift Dedicated (OSD) on Google Cloud
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config.env"

# Detect Windows Subsystem for Linux (WSL)
IS_WSL="false"
if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
  IS_WSL="true"
  if [[ "${REPO_ROOT}" == /mnt/* ]]; then
    echo "WARNING: You are running inside Windows WSL from a mounted Windows drive (${REPO_ROOT})."
    echo "         Windows DrvFs (/mnt/c/...) ignores 'chmod 600' on SSH private keys by default,"
    echo "         which causes SSH and gcloud to reject the generated keys."
    echo "         RECOMMENDED: Clone and run this repository inside your native Linux home directory (e.g., ~/osd-gcp-demo)."
    echo ""
  fi
fi

echo "=============================================================================="
echo " Red Hat OpenShift Dedicated (OSD) on Google Cloud - Prerequisite Setup"
echo "=============================================================================="
echo ""
echo "Before proceeding, please confirm the following prerequisites:"
echo "  1. Visit the Google Cloud Red Hat OpenShift portal and verify OSD requirements:"
echo "     -> https://console.cloud.google.com/redhat-openshift/"
echo "     (Verify your Red Hat OpenShift Dedicated entitlement/subscription,"
echo "      accept Marketplace Terms & Agreements if using GCP Marketplace billing,"
echo "      and verify regional vCPU, Persistent Disk, IP, and Load Balancer quotas.)"
echo "  2. You have an existing Google Cloud Project with Billing enabled."
echo "  3. You have an active Red Hat account with OpenShift Cluster Manager (OCM) access:"
echo "     -> https://console.redhat.com/openshift"
echo "  4. You have authenticated gcloud CLI ('gcloud auth login' & 'gcloud auth application-default login')."
echo ""

read -r -p "Have you visited https://console.cloud.google.com/redhat-openshift/ and verified all OSD prerequisites? [y/N]: " PREREQ_CONFIRM
if [[ ! "${PREREQ_CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "ERROR: Please visit https://console.cloud.google.com/redhat-openshift/ and complete the prerequisites before continuing."
  exit 1
fi

echo ""
echo "--- Step 1: Google Cloud Project & Region ---"
read -r -p "Enter existing GCP Project ID: " PROJECT_ID
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: Project ID cannot be empty."
  exit 1
fi

read -r -p "Enter GCP Region (e.g., us-central1, europe-west1, asia-southeast1): " REGION
if [[ -z "${REGION}" ]]; then
  echo "ERROR: Region cannot be empty."
  exit 1
fi

read -r -p "Enter default GCP Zone for Bastion VM [${REGION}-a]: " INPUT_ZONE
ZONE="${INPUT_ZONE:-${REGION}-a}"

echo ""
echo "--- Step 2: Naming Prefix & Cluster Domain Prefix ---"
echo "This prefix will be used for ALL resources (New VPC, 4 subnets, NAT, Bastion, WIF/SA, SSH key, OSD cluster)."
echo "NOTE: Must be 3-15 characters (lowercase letters, digits, hyphens) to satisfy OCM's 15-char domain-prefix limit."
read -r -p "Enter Naming Prefix (e.g., erd-osd01): " PREFIX
if [[ -z "${PREFIX}" ]]; then
  echo "ERROR: Naming prefix cannot be empty."
  exit 1
fi

if [[ ! "${PREFIX}" =~ ^[a-z][a-z0-9-]{1,13}[a-z0-9]$ ]]; then
  echo "ERROR: Naming prefix must start with a lowercase letter, end with an alphanumeric char, contain only lowercase letters, numbers, or hyphens, and be 3-15 chars."
  exit 1
fi

DOMAIN_PREFIX="${PREFIX}"

echo ""
echo "--- Step 3: New Custom VPC IP Range (/20) ---"
echo "Provide a /20 CIDR range for the new VPC. Four subnets will be carved out automatically:"
echo "  - Control Plane Subnet (/23)"
echo "  - Worker Subnet        (/23)"
echo "  - Bastion Subnet       (/24)"
echo "  - PSC Subnet           (/29) [Private Service Connect for OSD]"
read -r -p "Enter VPC CIDR Range (/20) [10.90.32.0/20]: " INPUT_VPC_CIDR
VPC_CIDR="${INPUT_VPC_CIDR:-10.90.32.0/20}"

# Validate /20 CIDR and compute the 4 subnet ranges using python3 ipaddress
SUBNET_CALC="$(python3 - "${VPC_CIDR}" << 'PYEOF'
import ipaddress
import sys

cidr_str = sys.argv[1]
try:
    net = ipaddress.ip_network(cidr_str, strict=False)
except ValueError as e:
    print(f"ERROR: Invalid CIDR '{cidr_str}': {e}", file=sys.stderr)
    sys.exit(1)

if net.version != 4 or net.prefixlen != 20:
    print(f"ERROR: CIDR '{cidr_str}' must be an IPv4 /20 network (e.g., 10.90.32.0/20).", file=sys.stderr)
    sys.exit(1)

# Carve /23 subnets from /20 (yields 8 /23 blocks)
subnets_23 = list(net.subnets(new_prefix=23))
cp_cidr = str(subnets_23[0])       # first /23 (e.g. 10.90.32.0/23)
worker_cidr = str(subnets_23[1])   # second /23 (e.g. 10.90.34.0/23)
# Carve two /24s from the third /23:
subnets_24 = list(subnets_23[2].subnets(new_prefix=24))
bastion_cidr = str(subnets_24[0])  # first /24 (e.g. 10.90.36.0/24)
# Carve /29 from the second /24 for Private Service Connect (e.g. 10.90.37.0/29)
psc_cidr = str(list(subnets_24[1].subnets(new_prefix=29))[0])

print(f"{net}|{cp_cidr}|{worker_cidr}|{bastion_cidr}|{psc_cidr}")
PYEOF
)"

IFS='|' read -r NORMALIZED_VPC_CIDR CONTROL_PLANE_CIDR WORKER_CIDR BASTION_CIDR PSC_CIDR <<< "${SUBNET_CALC}"
VPC_CIDR="${NORMALIZED_VPC_CIDR}"

echo "  -> Normalized VPC CIDR : ${VPC_CIDR}"
echo "  -> Control Plane (/23) : ${CONTROL_PLANE_CIDR}"
echo "  -> Worker Subnet (/23) : ${WORKER_CIDR}"
echo "  -> Bastion Subnet(/24) : ${BASTION_CIDR}"
echo "  -> PSC Subnet    (/29) : ${PSC_CIDR}"

echo ""
echo "--- Step 4: OSD License / Subscription Model & Cluster Sizing ---"
echo "  -> GCP Authentication Method : Workload Identity Federation (WIF - Keyless)"
echo ""
echo "Select your OpenShift Dedicated license / subscription model:"
echo "  1) OSD Free Trial License   (osdtrial — uses 'cluster|byoc|osdtrial' quota, Default)"
echo "  2) Google Cloud Marketplace (marketplace-gcp — requires accepting terms at https://console.cloud.google.com/redhat-openshift/)"
echo "  3) Standard Red Hat CCS     (standard — direct Red Hat annual entitlement)"
read -r -p "Enter license / subscription option [1-3, default: 1]: " SUB_OPTION
case "${SUB_OPTION:-1}" in
  1)
    OSD_PRODUCT="osdtrial"
    SUBSCRIPTION_TYPE="standard"
    MARKETPLACE_GCP_TERMS="false"
    ;;
  2)
    OSD_PRODUCT="osd"
    SUBSCRIPTION_TYPE="marketplace-gcp"
    MARKETPLACE_GCP_TERMS="true"
    ;;
  3)
    OSD_PRODUCT="osd"
    SUBSCRIPTION_TYPE="standard"
    MARKETPLACE_GCP_TERMS="false"
    ;;
  *)
    echo "ERROR: Invalid subscription option '${SUB_OPTION}'. Choose 1, 2, or 3."
    exit 1
    ;;
esac
echo "  -> Selected OSD Product / Subscription: product=${OSD_PRODUCT}, subscription=${SUBSCRIPTION_TYPE}"

# Multi-AZ High Availability is always enabled (--multi-az requires compute-nodes in multiples of 3, min 3)
MULTI_AZ="true"
DEFAULT_COMPUTE_NODES="3"
echo "  -> Multi-AZ High Availability (--multi-az) : Enabled (3 zones)"

echo ""
echo "Supported OCM GCP Machine Types (examples):"
echo "  - Predefined N4/N2/E2/C2 : n4-standard-4 (default), n2-standard-4, n2-standard-8, e2-standard-4, c2-standard-4"
echo "  - OCM Catalog Custom     : custom-4-16384 (N1 4 vCPU/16GB), custom-8-32768 (N1 8 vCPU/32GB)"
echo "  (Note: Unlike self-managed OCP, OSD only accepts machine types listed in the OCM catalog.)"
read -r -p "Enter Worker Compute Machine Type [n4-standard-4]: " INPUT_MACHINE_TYPE
COMPUTE_MACHINE_TYPE="${INPUT_MACHINE_TYPE:-n4-standard-4}"

read -r -p "Enter Number of Worker Compute Nodes (multiple of 3 for --multi-az) [${DEFAULT_COMPUTE_NODES}]: " INPUT_COMPUTE_NODES
COMPUTE_NODES="${INPUT_COMPUTE_NODES:-${DEFAULT_COMPUTE_NODES}}"

read -r -p "Enter OpenShift Version (leave blank for latest default in stable channel): " INPUT_OSD_VERSION
OSD_VERSION="${INPUT_OSD_VERSION:-}"

read -r -p "Enable Shielded VM Secure Boot for OSD cluster nodes? [Y/n]: " SECURE_BOOT_CONFIRM
if [[ "${SECURE_BOOT_CONFIRM:-Y}" =~ ^[Nn]$ ]]; then
  SECURE_BOOT_FOR_SHIELDED_VMS="false"
else
  SECURE_BOOT_FOR_SHIELDED_VMS="true"
fi

echo ""
echo "--- Step 5: Cluster Admin Identity Provider (HTPasswd) Username ---"
echo "OpenShift Dedicated requires configuring an Identity Provider (IDP) after creation to log in."
echo "Note: For security, the admin password is NEVER saved to config.env or disk; you will set"
echo "      or auto-generate it in memory during Step 5 (05-bastion-install-osd.sh)."
read -r -p "Enter Cluster Admin Username [erdadmin]: " INPUT_ADMIN_USER
OSD_ADMIN_USER="${INPUT_ADMIN_USER:-erdadmin}"

# Derived resource names using PREFIX
VPC_NAME="${PREFIX}-vpc"
SUBNET_BASTION="${PREFIX}-subnet-bastion"
SUBNET_CONTROL_PLANE="${PREFIX}-subnet-control-plane"
SUBNET_WORKER="${PREFIX}-subnet-worker"
SUBNET_PSC="${PREFIX}-subnet-psc"
ROUTER_NAME="${PREFIX}-router"
NAT_NAME="${PREFIX}-nat"
FW_IAP_SSH="${PREFIX}-allow-iap-ssh"
FW_INTERNAL="${PREFIX}-allow-internal"
FW_HEALTH_CHECKS="${PREFIX}-allow-gcp-health-checks"
BASTION_NAME="${PREFIX}-vm-bastion"
SA_NAME="${PREFIX}-gcp-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
WIF_CONFIG_NAME="${PREFIX}-wif"
CLUSTER_NAME="${PREFIX}-cluster"

mkdir -p "${REPO_ROOT}/generated"

# On Windows WSL2, default CONSOLE_LOCAL_IP to 127.0.0.1 because WSL2 NAT mode
# only forwards 127.0.0.1 from the Windows host browser into the WSL2 VM.
if [[ "${IS_WSL}" == "true" ]]; then
  DEFAULT_CONSOLE_LOCAL_IP="127.0.0.1"
else
  DEFAULT_CONSOLE_LOCAL_IP="127.0.0.2"
fi

cat <<EOF > "${CONFIG_FILE}"
# Auto-generated by scripts/00-prereq-config.sh
export PROJECT_ID="${PROJECT_ID}"
export REGION="${REGION}"
export ZONE="${ZONE}"
export PREFIX="${PREFIX}"
export DOMAIN_PREFIX="${DOMAIN_PREFIX}"

# Networking & Subnets (New Custom VPC)
export VPC_CIDR="${VPC_CIDR}"
export CONTROL_PLANE_CIDR="${CONTROL_PLANE_CIDR}"
export WORKER_CIDR="${WORKER_CIDR}"
export BASTION_CIDR="${BASTION_CIDR}"
export PSC_CIDR="${PSC_CIDR}"
export VPC_NAME="${VPC_NAME}"
export SUBNET_BASTION="${SUBNET_BASTION}"
export SUBNET_CONTROL_PLANE="${SUBNET_CONTROL_PLANE}"
export SUBNET_WORKER="${SUBNET_WORKER}"
export SUBNET_PSC="${SUBNET_PSC}"
export ROUTER_NAME="${ROUTER_NAME}"
export NAT_NAME="${NAT_NAME}"
export FW_IAP_SSH="${FW_IAP_SSH}"
export FW_INTERNAL="${FW_INTERNAL}"
export FW_HEALTH_CHECKS="${FW_HEALTH_CHECKS}"

# Compute, IAM, WIF & SSH Keys (Keyless WIF — no SA JSON keys)
export BASTION_NAME="${BASTION_NAME}"
export SA_NAME="${SA_NAME}"
export SA_EMAIL="${SA_EMAIL}"
export WIF_CONFIG_NAME="${WIF_CONFIG_NAME}"
export SSH_KEY_FILE="${REPO_ROOT}/generated/${PREFIX}-ssh"

# OpenShift Dedicated (OSD) Cluster Settings
export CLUSTER_NAME="${CLUSTER_NAME}"
export OSD_PRODUCT="${OSD_PRODUCT}"
export OSD_VERSION="${OSD_VERSION}"
export SUBSCRIPTION_TYPE="${SUBSCRIPTION_TYPE}"
export MARKETPLACE_GCP_TERMS="${MARKETPLACE_GCP_TERMS}"
export MULTI_AZ="${MULTI_AZ}"
export COMPUTE_MACHINE_TYPE="${COMPUTE_MACHINE_TYPE}"
export COMPUTE_NODES="${COMPUTE_NODES}"
export SECURE_BOOT_FOR_SHIELDED_VMS="${SECURE_BOOT_FOR_SHIELDED_VMS}"

# OSD Identity Provider (HTPasswd Admin)
export OSD_ADMIN_USER="${OSD_ADMIN_USER}"

# Discovered OSD Endpoints (Populated automatically after cluster creation)
export OSD_BASE_DOMAIN=""
export OSD_API_HOST=""
export OSD_CONSOLE_HOST=""
export OSD_OAUTH_HOST=""

# Local Loopback Tunnel IP (127.0.0.2 on Linux/macOS; 127.0.0.1 on Windows WSL2)
export CONSOLE_LOCAL_IP="${DEFAULT_CONSOLE_LOCAL_IP}"
EOF

chmod 600 "${CONFIG_FILE}"

echo ""
echo "=============================================================================="
echo " Configuration saved to: ${CONFIG_FILE}"
echo "=============================================================================="
cat "${CONFIG_FILE}"
echo ""
echo "Next step: Run ./scripts/01-policy-check.sh"
