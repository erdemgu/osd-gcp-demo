#!/usr/bin/env bash
# ==============================================================================
# 05-bastion-install-osd.sh
# RUN THIS SCRIPT MANUALLY INSIDE THE BASTION VM AFTER SSH LOGIN!
#
# What it does:
#   1. Installs required tools (wget, tar, jq, httpd-tools/htpasswd, dnsutils)
#   2. Downloads ocm, oc, and kubectl CLI binaries into ~/bin (if not installed)
#   3. Verifies GCP credentials and Red Hat OCM authentication
#   4. Displays the rendered declarative ~/osd-setup/cluster-config.yaml
#   5. Runs `ocm create cluster` to provision the Private OSD cluster in ${VPC_NAME}
#   6. Waits for the cluster to reach `ready` state and verifies private DNS
#   7. Creates the HTPasswd Identity Provider (`htpasswd`), grants `dedicated-admins`
#      and `cluster-admins`, logs in via `oc login`, applies `cluster-admin-rbac.yaml`,
#      and configures `~/.kube/config`
# ==============================================================================
set -euo pipefail

SETUP_DIR="${HOME}/osd-setup"
ACTION="${1:-install}"

if [[ ! -f "${SETUP_DIR}/config.env" ]]; then
  echo "ERROR: ${SETUP_DIR}/config.env not found. Make sure you are running this on the Bastion VM."
  exit 1
fi
# shellcheck source=/dev/null
source "${SETUP_DIR}/config.env"
export PATH="${HOME}/bin:${PATH}"

print_failure_and_recovery_commands() {
  cat <<EOF

==============================================================================
 [!] OpenShift Dedicated Installation Interrupted — Recovery & Management
==============================================================================

Option A: Check Cluster Status & Installation Logs
------------------------------------------------------------------------------
ocm describe cluster "${CLUSTER_NAME}"
ocm get /api/clusters_mgmt/v1/clusters/\$(ocm describe cluster "${CLUSTER_NAME}" --json | jq -r '.id')/logs/install

  Shortcut: ~/osd-setup/05-bastion-install-osd.sh status

Option B: Resume Waiting & Configure HTPasswd IDP + Admin Login
------------------------------------------------------------------------------
  Shortcut: ~/osd-setup/05-bastion-install-osd.sh setup-idp

Option C: Delete / Destroy the OSD Cluster Only
------------------------------------------------------------------------------
ocm delete cluster "\$(ocm describe cluster "${CLUSTER_NAME}" --json | jq -r '.id')"

  Shortcut: ~/osd-setup/05-bastion-install-osd.sh destroy

Option D: Destroy & Restart OSD Installation from Scratch
------------------------------------------------------------------------------
  Shortcut: ~/osd-setup/05-bastion-install-osd.sh restart

Option E: If 'CLUSTERS-MGMT-401: Unauthorized due to missing quota' Occurred
------------------------------------------------------------------------------
1. Check your Red Hat OCM organization's available quota and active clusters:
   ocm list quota
   ocm list clusters

2. If your quota is under Google Cloud Marketplace ('marketplace-gcp') instead
   of 'standard', update ~/osd-setup/config.env on the Bastion VM:
   sed -i 's/SUBSCRIPTION_TYPE="standard"/SUBSCRIPTION_TYPE="marketplace-gcp"/' ~/osd-setup/config.env
   sed -i 's/MARKETPLACE_GCP_TERMS="false"/MARKETPLACE_GCP_TERMS="true"/' ~/osd-setup/config.env
   ~/osd-setup/05-bastion-install-osd.sh
==============================================================================
EOF
}

ensure_tools_and_auth() {
  echo "--- Step 1: Checking system packages ---"
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y wget tar jq httpd-tools bind-utils >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null
    sudo apt-get install -y wget tar jq apache2-utils dnsutils >/dev/null
  fi

  mkdir -p "${HOME}/bin"
  export PATH="${HOME}/bin:${PATH}"
  if ! grep -q '$HOME/bin' "${HOME}/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "${HOME}/.bashrc"
  fi

  if ! command -v ocm >/dev/null 2>&1; then
    echo "--- Step 2a: Downloading latest ocm CLI ---"
    wget -q --show-progress -O "${HOME}/bin/ocm" \
      "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64"
    chmod +x "${HOME}/bin/ocm"
  else
    echo "[SKIP] ocm CLI already present: $(ocm version)"
  fi

  if ! command -v oc >/dev/null 2>&1; then
    echo "--- Step 2b: Downloading oc and kubectl CLI ---"
    MIRROR_BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable"
    wget -q --show-progress -O /tmp/openshift-client-linux.tar.gz "${MIRROR_BASE}/openshift-client-linux.tar.gz"
    tar -xzf /tmp/openshift-client-linux.tar.gz -C "${HOME}/bin" oc kubectl
    rm -f /tmp/openshift-client-linux.tar.gz
    chmod +x "${HOME}/bin/oc" "${HOME}/bin/kubectl"
  else
    echo "[SKIP] oc CLI already present: $(oc version --client | head -n 1)"
  fi

  if [[ -f "${SETUP_DIR}/ocm.json" && ! -f "${HOME}/.config/ocm/ocm.json" ]]; then
    mkdir -p "${HOME}/.config/ocm"
    cp "${SETUP_DIR}/ocm.json" "${HOME}/.config/ocm/ocm.json"
    chmod 600 "${HOME}/.config/ocm/ocm.json"
  fi

  if ! ocm whoami >/dev/null 2>&1; then
    echo "OCM session not found or expired on Bastion. Copy your token from https://console.redhat.com/openshift/token"
    read -r -s -p "Paste Red Hat OCM Offline Token (or press Enter to use --use-device-code): " OCM_OFFLINE_TOKEN
    echo ""
    if [[ -n "${OCM_OFFLINE_TOKEN}" ]]; then
      ocm login --token="${OCM_OFFLINE_TOKEN}"
    else
      ocm login --use-device-code
    fi
  fi
}

wait_for_cluster_ready() {
  echo ""
  echo "=============================================================================="
  echo " Waiting for OSD Cluster '${CLUSTER_NAME}' to reach 'ready' state..."
  echo " (Typical OSD on GCP provisioning time: ~35-45 minutes)"
  echo "=============================================================================="
  while true; do
    CLUSTER_JSON="$(ocm describe cluster "${CLUSTER_NAME}" --json 2>/dev/null || true)"
    if [[ -z "${CLUSTER_JSON}" ]]; then
      echo "ERROR: Cluster '${CLUSTER_NAME}' not found in OCM."
      return 1
    fi
    STATE="$(echo "${CLUSTER_JSON}" | jq -r '.state // "unknown"')"
    STATE_DESC="$(echo "${CLUSTER_JSON}" | jq -r '.status.description // ""')"
    DNS_READY="$(echo "${CLUSTER_JSON}" | jq -r '.status.dns_ready // false')"
    API_URL="$(echo "${CLUSTER_JSON}" | jq -r '.api.url // ""')"
    CONSOLE_URL="$(echo "${CLUSTER_JSON}" | jq -r '.console.url // ""')"

    echo "[$(date -u '+%H:%M:%S UTC')] State: ${STATE} | DNS Ready: ${DNS_READY} | API: ${API_URL:-pending} | ${STATE_DESC}"

    if [[ "${STATE}" == "ready" ]]; then
      echo "[READY] OSD Cluster '${CLUSTER_NAME}' is ready!"
      break
    elif [[ "${STATE}" == "error" ]]; then
      echo "ERROR: OSD Cluster '${CLUSTER_NAME}' entered 'error' state."
      print_failure_and_recovery_commands
      return 1
    fi
    sleep 60
  done
}

configure_idp_and_kubeconfig() {
  CLUSTER_JSON="$(ocm describe cluster "${CLUSTER_NAME}" --json)"
  CLUSTER_ID="$(echo "${CLUSTER_JSON}" | jq -r '.id')"
  API_URL="$(echo "${CLUSTER_JSON}" | jq -r '.api.url')"
  CONSOLE_URL="$(echo "${CLUSTER_JSON}" | jq -r '.console.url')"
  BASE_DOMAIN="$(echo "${CLUSTER_JSON}" | jq -r '.dns.base_domain')"

  echo ""
  echo "=============================================================================="
  echo " Configuring HTPasswd Identity Provider & Cluster Admin Access"
  echo "   Cluster ID  : ${CLUSTER_ID}"
  echo "   API URL     : ${API_URL}"
  echo "   Console URL : ${CONSOLE_URL}"
  echo "   Admin User  : ${OSD_ADMIN_USER}"
  echo "=============================================================================="

  # Remove any legacy cleartext htpasswd file if present
  rm -f "${SETUP_DIR}/users.htpasswd"

  # Prompt for or auto-generate the admin password strictly in memory (never written to disk)
  local admin_pass=""
  read -r -s -p "Enter Cluster Admin Password for '${OSD_ADMIN_USER}' (leave blank to auto-generate in memory): " admin_pass
  echo ""
  if [[ -z "${admin_pass}" ]]; then
    admin_pass="$(python3 -c 'import secrets, string; chars = string.ascii_letters + string.digits; print("Osd!" + "".join(secrets.choice(chars) for _ in range(12)) + "9a")')"
    echo "  -> Auto-generated strong password in memory (will be displayed once below; NOT saved to disk)."
  fi

  # 1. Create HTPasswd IDP if not already present
  if ocm list idps --cluster="${CLUSTER_ID}" --columns name | grep -qx "htpasswd"; then
    echo "[SKIP] Identity Provider 'htpasswd' already exists on cluster '${CLUSTER_NAME}'."
  else
    echo "[CREATE] Creating HTPasswd Identity Provider 'htpasswd' for user '${OSD_ADMIN_USER}'..."
    ocm create idp \
      --cluster="${CLUSTER_ID}" \
      --type=htpasswd \
      --name=htpasswd \
      --username="${OSD_ADMIN_USER}" \
      --password="${admin_pass}"
  fi

  # 2. Add admin user to dedicated-admins and cluster-admins groups
  for group in dedicated-admins cluster-admins; do
    echo "Granting OCM group '${group}' to '${OSD_ADMIN_USER}'..."
    ocm create user "${OSD_ADMIN_USER}" \
      --cluster="${CLUSTER_ID}" \
      --group="${group}" || echo "[INFO] User '${OSD_ADMIN_USER}' already in '${group}' or group not enabled."
  done

  # 3. Persist KUBECONFIG in ~/.bashrc
  mkdir -p "${HOME}/.kube"
  export KUBECONFIG="${HOME}/.kube/config"
  if ! grep -q "KUBECONFIG=" "${HOME}/.bashrc" 2>/dev/null; then
    echo 'export KUBECONFIG="$HOME/.kube/config"' >> "${HOME}/.bashrc"
  fi

  # 4. Wait for OAuth server to roll out the new HTPasswd IDP and log in via oc
  echo ""
  echo "Waiting for OpenShift OAuth server to activate HTPasswd credentials (usually 1-3 minutes)..."
  MAX_LOGIN_ATTEMPTS=24
  for ((i=1; i<=MAX_LOGIN_ATTEMPTS; i++)); do
    if oc login "${API_URL}" \
        --username="${OSD_ADMIN_USER}" \
        --password="${admin_pass}" \
        --insecure-skip-tls-verify=true >/dev/null 2>&1; then
      echo "[SUCCESS] Logged into OpenShift Dedicated API (${API_URL}) as '${OSD_ADMIN_USER}'!"
      break
    fi
    echo "  Waiting for IDP propagation (attempt ${i}/${MAX_LOGIN_ATTEMPTS})..."
    sleep 15
    if [[ "${i}" -eq "${MAX_LOGIN_ATTEMPTS}" ]]; then
      echo "[WARN] Timed out waiting for automated 'oc login'. You can retry manually:"
      echo "       oc login ${API_URL} -u ${OSD_ADMIN_USER}"
      unset admin_pass
      return 0
    fi
  done

  chmod 600 "${HOME}/.kube/config"

  # 5. Apply declarative RBAC YAML manifest
  if [[ -f "${SETUP_DIR}/cluster-admin-rbac.yaml" ]]; then
    echo "Applying declarative RBAC manifest (${SETUP_DIR}/cluster-admin-rbac.yaml)..."
    oc apply -f "${SETUP_DIR}/cluster-admin-rbac.yaml" || \
      echo "[INFO] Group-level dedicated-admins RBAC is active via OCM."
  fi

  # 6. Configure non-expiring ServiceAccount token in ~/.kube/config for Bastion CLI access
  echo "Configuring non-expiring ServiceAccount ('system:serviceaccount:kube-system:bastion-admin') in ~/.kube/config..."
  local sa_token=""
  for ((i=1; i<=10; i++)); do
    sa_token="$(oc get secret bastion-admin-token -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [[ -n "${sa_token}" ]] && break
    sleep 2
  done
  if [[ -n "${sa_token}" ]]; then
    oc login "${API_URL}" --token="${sa_token}" --insecure-skip-tls-verify=true >/dev/null 2>&1
    chmod 600 "${HOME}/.kube/config"
    echo "[SUCCESS] Persistent kubeconfig configured (authenticated as: $(oc whoami))."
  fi
  unset sa_token

  echo ""
  echo "=============================================================================="
  echo " OpenShift Dedicated Cluster Installation & Admin Setup Complete!"
  echo "=============================================================================="
  echo " Web Console URL : ${CONSOLE_URL}"
  echo " API Server URL  : ${API_URL}"
  echo " Admin Username  : ${OSD_ADMIN_USER}"
  echo " Admin Password  : ${admin_pass}   <-- SAVE THIS NOW (not stored on disk!)"
  echo ""
  unset admin_pass
  echo " Verifying cluster nodes:"
  oc get nodes -o wide
  echo ""
  echo "=============================================================================="
  echo " NEXT STEP (Run on your LOCAL WORKSTATION, NOT on this Bastion VM):"
  echo "   1. Exit this Bastion SSH session (or open a local terminal on your laptop/workstation)"
  echo "   2. Run: ./scripts/06-access-and-test.sh test"
  echo "   3. Run: ./scripts/06-access-and-test.sh hosts"
  echo "   4. Run: ./scripts/06-access-and-test.sh tunnel"
  echo "=============================================================================="
}

destroy_osd_cluster() {
  echo "=============================================================================="
  echo " Destroying OpenShift Dedicated Cluster (${CLUSTER_NAME})"
  echo "=============================================================================="
  if ocm describe cluster "${CLUSTER_NAME}" >/dev/null 2>&1; then
    CLUSTER_ID="$(ocm describe cluster "${CLUSTER_NAME}" --json | jq -r '.id')"
    echo "Deleting cluster '${CLUSTER_NAME}' (ID: ${CLUSTER_ID}) via OCM..."
    ocm delete cluster "${CLUSTER_ID}"
    echo "Waiting for OCM to finish deprovisioning cluster '${CLUSTER_NAME}'..."
    while ocm describe cluster "${CLUSTER_ID}" >/dev/null 2>&1; do
      STATE="$(ocm describe cluster "${CLUSTER_ID}" --json 2>/dev/null | jq -r '.state // "uninstalling"')"
      echo "[$(date -u '+%H:%M:%S UTC')] Cluster state: ${STATE} ..."
      sleep 45
    done
    echo "[DONE] Cluster '${CLUSTER_NAME}' has been completely uninstalled."
  else
    echo "[SKIP] Cluster '${CLUSTER_NAME}' does not exist in OCM."
  fi
}

ensure_tools_and_auth

case "${ACTION}" in
  status)
    ocm describe cluster "${CLUSTER_NAME}"
    exit 0
    ;;
  setup-idp)
    wait_for_cluster_ready
    configure_idp_and_kubeconfig
    exit 0
    ;;
  destroy)
    destroy_osd_cluster
    exit 0
    ;;
  restart)
    destroy_osd_cluster
    echo "[CLEANED] Proceeding with fresh OSD cluster installation..."
    ;;
  install)
    ;;
  *)
    echo "Usage: $0 [install|status|setup-idp|destroy|restart]"
    exit 1
    ;;
esac

echo ""
echo "=============================================================================="
echo " Declarative OSD Cluster Specification (${SETUP_DIR}/cluster-config.yaml)"
echo "=============================================================================="
cat "${SETUP_DIR}/cluster-config.yaml"
echo "=============================================================================="
read -r -p "Start OpenShift Dedicated cluster creation now? [y/N]: " CONFIRM_INSTALL
if [[ ! "${CONFIRM_INSTALL}" =~ ^[Yy]$ ]]; then
  echo "Installation cancelled. You can re-run ~/osd-setup/05-bastion-install-osd.sh anytime."
  exit 0
fi

# Build ocm create cluster command from declarative config
OCM_ARGS=(
  create cluster "${CLUSTER_NAME}"
  --provider=gcp
  --ccs
  --multi-az
  --region="${REGION}"
  --domain-prefix="${DOMAIN_PREFIX}"
  --vpc-name="${VPC_NAME}"
  --control-plane-subnet="${SUBNET_CONTROL_PLANE}"
  --compute-subnet="${SUBNET_WORKER}"
  --psc-subnet="${SUBNET_PSC}"
  --machine-cidr="${VPC_CIDR}"
  --pod-cidr="10.128.0.0/14"
  --service-cidr="172.30.0.0/16"
  --host-prefix=23
  --compute-machine-type="${COMPUTE_MACHINE_TYPE}"
  --compute-nodes="${COMPUTE_NODES}"
  --subscription-type="${SUBSCRIPTION_TYPE}"
  --wif-config="${WIF_CONFIG_NAME}"
  --private
)

if [[ "${SUBSCRIPTION_TYPE}" == "marketplace-gcp" && "${MARKETPLACE_GCP_TERMS}" == "true" ]]; then
  OCM_ARGS+=(--marketplace-gcp-terms)
fi

if [[ "${SECURE_BOOT_FOR_SHIELDED_VMS}" == "true" ]]; then
  OCM_ARGS+=(--secure-boot-for-shielded-vms)
fi

if [[ -n "${OSD_VERSION}" ]]; then
  OCM_ARGS+=(--version="${OSD_VERSION}")
fi

if ocm describe cluster "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "[SKIP] Cluster '${CLUSTER_NAME}' already exists in OCM. Proceeding to monitor status..."
else
  if [[ "${OSD_PRODUCT:-osdtrial}" == "osdtrial" ]]; then
    echo "=============================================================================="
    echo " Using Red Hat OpenShift Dedicated Trial License (product.id='osdtrial')"
    echo " Note: 'ocm create cluster' CLI does not have a '--trial' flag, so we pass"
    echo "       product.id='osdtrial' directly via 'ocm post /api/clusters_mgmt/v1/clusters'"
    echo "=============================================================================="
    WIF_ID="$(ocm gcp list wif-configs | awk -v name="${WIF_CONFIG_NAME}" '$2 == name {print $1}')"
    if ! jq -n \
      --arg name "${CLUSTER_NAME}" \
      --arg domain "${DOMAIN_PREFIX}" \
      --arg region "${REGION}" \
      --arg vpc "${VPC_NAME}" \
      --arg cp_sub "${SUBNET_CONTROL_PLANE}" \
      --arg worker_sub "${SUBNET_WORKER}" \
      --arg psc_sub "${SUBNET_PSC}" \
      --arg cidr "${VPC_CIDR}" \
      --arg mtype "${COMPUTE_MACHINE_TYPE}" \
      --argjson nodes "${COMPUTE_NODES}" \
      --arg wif_id "${WIF_ID}" \
      '{
        name: $name,
        domain_prefix: $domain,
        product: {id: "osdtrial"},
        flavour: {id: "osd-4"},
        cloud_provider: {id: "gcp"},
        region: {id: $region},
        multi_az: true,
        billing_model: "standard",
        ccs: {enabled: true},
        api: {listening: "internal"},
        gcp_network: {vpc_name: $vpc, control_plane_subnet: $cp_sub, compute_subnet: $worker_sub},
        network: {machine_cidr: $cidr, pod_cidr: "10.128.0.0/14", service_cidr: "172.30.0.0/16", host_prefix: 23},
        nodes: {compute: $nodes, compute_machine_type: {id: $mtype}},
        gcp: {
          authentication: {kind: "WifConfig", id: $wif_id},
          private_service_connect: {service_attachment_subnet: $psc_sub},
          security: {secure_boot: true}
        }
      }' | ocm post /api/clusters_mgmt/v1/clusters; then
      print_failure_and_recovery_commands
      exit 1
    fi
  else
    echo "Executing: ocm ${OCM_ARGS[*]}"
    if ! ocm "${OCM_ARGS[@]}"; then
      print_failure_and_recovery_commands
      exit 1
    fi
  fi
fi

if ! wait_for_cluster_ready; then
  exit 1
fi

configure_idp_and_kubeconfig
