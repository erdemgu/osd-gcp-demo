#!/usr/bin/env bash
# ==============================================================================
# 03-iam-and-keys.sh
# 1. Generates SSH key pair (${PREFIX}-ssh)
# 2. Creates Customer-Managed GCP Service Account (${PREFIX}-gcp-sa) — keyless (no JSON key)
# 3. Ensures `ocm` CLI is installed and authenticated to Red Hat OCM
# 4. Configures OSD GCP Workload Identity Federation (`ocm gcp create wif-config`)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"

mkdir -p "${REPO_ROOT}/generated" "${HOME}/bin"
export PATH="${HOME}/bin:$(cd "${REPO_ROOT}/.." && pwd):${PATH}"

echo "=============================================================================="
echo " Step 1: Generating SSH Key Pair"
echo " Key Path: ${SSH_KEY_FILE}"
echo "=============================================================================="
if [[ -f "${SSH_KEY_FILE}" && -f "${SSH_KEY_FILE}.pub" ]]; then
  echo "[SKIP] SSH key pair already exists at ${SSH_KEY_FILE}"
else
  ssh-keygen -t ed25519 -N '' -f "${SSH_KEY_FILE}" -C "osd-admin@${PREFIX}"
  chmod 600 "${SSH_KEY_FILE}"
  chmod 644 "${SSH_KEY_FILE}.pub"
  echo "[CREATED] SSH key pair generated at ${SSH_KEY_FILE}"
fi

echo ""
echo "=============================================================================="
echo " Step 2: Creating Keyless GCP Service Account (${SA_EMAIL})"
echo "=============================================================================="
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] GCP Service Account '${SA_EMAIL}' already exists."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="OSD GCP Service Account (${PREFIX})"
  echo "[CREATED] Service Account '${SA_EMAIL}'."
  sleep 5
fi

BASTION_ROLES=(
  "roles/compute.viewer"
  "roles/dns.reader"
  "roles/viewer"
)
for role in "${BASTION_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done
echo "[OK] Keyless GCP Service Account '${SA_EMAIL}' configured (no JSON key exported)."

echo ""
echo "=============================================================================="
echo " Step 3: Checking OCM CLI & Red Hat Authentication"
echo "=============================================================================="
if ! command -v ocm >/dev/null 2>&1; then
  OS_RAW="$(uname -s)"
  ARCH_RAW="$(uname -m)"
  case "${OS_RAW}" in
    Darwin) OCM_OS="darwin" ;;
    Linux)  OCM_OS="linux" ;;
    *)
      echo "ERROR: Unsupported OS '${OS_RAW}' for automatic ocm download."
      exit 1
      ;;
  esac
  case "${ARCH_RAW}" in
    x86_64|amd64)  OCM_ARCH="amd64" ;;
    arm64|aarch64) OCM_ARCH="arm64" ;;
    *)
      echo "ERROR: Unsupported CPU architecture '${ARCH_RAW}' for automatic ocm download."
      exit 1
      ;;
  esac
  OCM_URL="https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-${OCM_OS}-${OCM_ARCH}"
  echo "Downloading latest ocm CLI (${OCM_OS}-${OCM_ARCH}) to ${HOME}/bin/ocm ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "${HOME}/bin/ocm" "${OCM_URL}"
  else
    wget -q --show-progress -O "${HOME}/bin/ocm" "${OCM_URL}"
  fi
  chmod +x "${HOME}/bin/ocm"
fi
echo "Using ocm CLI: $(command -v ocm) (version: $(ocm version))"

if ! ocm whoami >/dev/null 2>&1; then
  echo "You are not currently logged into Red Hat OCM."
  if [[ "${CLOUD_SHELL:-false}" == "true" ]]; then
    echo "Google Cloud Shell detected: copy your offline token from https://console.redhat.com/openshift/token"
    read -r -s -p "Paste Red Hat OCM Offline Token (or press Enter to use --use-device-code): " OCM_OFFLINE_TOKEN
    echo ""
    if [[ -n "${OCM_OFFLINE_TOKEN}" ]]; then
      ocm login --token="${OCM_OFFLINE_TOKEN}"
    else
      ocm login --use-device-code
    fi
  else
    echo "Initiating 'ocm login --use-auth-code' (or run 'ocm login --token=<TOKEN>' from https://console.redhat.com/openshift/token)..."
    ocm login --use-auth-code
  fi
fi
OCM_USER="$(ocm whoami | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("username") or d.get("email") or "verified")' 2>/dev/null || echo "verified")"
echo "[OK] Authenticated to Red Hat OCM as: ${OCM_USER}"

echo ""
echo "=============================================================================="
echo " Step 4: Configuring OSD GCP Workload Identity Federation (WIF: ${WIF_CONFIG_NAME})"
echo "=============================================================================="
echo "Checking Workload Identity Federation (WIF) configuration '${WIF_CONFIG_NAME}'..."
if ocm gcp list wif-configs | awk '{print $2}' | grep -qx "${WIF_CONFIG_NAME}"; then
  echo "[SKIP] WIF configuration '${WIF_CONFIG_NAME}' already exists in OCM."
else
  echo "Ensure Application Default Credentials (ADC) are active for 'ocm gcp create wif-config'..."
  if [[ ! -f "${HOME}/.config/gcloud/application_default_credentials.json" ]]; then
    echo "Running 'gcloud auth application-default login'..."
    gcloud auth application-default login
  fi
  echo "[CREATE] Creating WIF configuration '${WIF_CONFIG_NAME}' in project '${PROJECT_ID}'..."
  ocm gcp create wif-config \
    --name "${WIF_CONFIG_NAME}" \
    --project "${PROJECT_ID}"
  echo "[CREATED] WIF configuration '${WIF_CONFIG_NAME}' created successfully."
fi
ocm gcp list wif-configs | grep -E "(ID|${WIF_CONFIG_NAME})" || true

echo ""
echo "=============================================================================="
echo " SSH Key, GCP Service Account, and OSD Workload Identity Federation (WIF) Ready!"
echo "   SSH Private Key : ${SSH_KEY_FILE}"
echo "   SSH Public Key  : ${SSH_KEY_FILE}.pub"
echo "   GCP Service Acct: ${SA_EMAIL} (Keyless)"
echo "   OSD WIF Config  : ${WIF_CONFIG_NAME} (Keyless WIF)"
echo "=============================================================================="
echo "Next step: Run ./scripts/04-bastion-setup.sh"
