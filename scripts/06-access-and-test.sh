#!/usr/bin/env bash
# ==============================================================================
# 06-access-and-test.sh
# IMPORTANT: RUN THIS SCRIPT ON YOUR LOCAL WORKSTATION (NOT INSIDE BASTION VM)!
#
# Provides and executes commands for:
#   1. Discovering OSD cluster domain & URLs (`*.p2.openshiftapps.com`) via OCM
#   2. SSH Tunnel into Bastion VM
#   3. Testing Private DNS, API (:6443), Console (:443), and Nodes via Bastion
#   4. Configuring local /etc/hosts for private OpenShift Dedicated Web Console
#   5. Starting HTTPS/HTTP Tunnel (127.0.0.2:443 & :80) to local machine
# ==============================================================================
set -euo pipefail

if [[ "$(hostname)" == *"-vm-bastion"* ]]; then
  echo "ERROR: 06-access-and-test.sh must be run on your LOCAL WORKSTATION, not inside the Bastion VM ($(hostname))."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/config.env"
export PATH="${HOME}/bin:$(cd "${REPO_ROOT}/.." && pwd):${PATH}"

CONSOLE_LOCAL_IP="${CONSOLE_LOCAL_IP:-127.0.0.2}"
ACTION="${1:-print}"

discover_osd_endpoints() {
  if [[ -n "${OSD_CONSOLE_HOST:-}" && -n "${OSD_API_HOST:-}" ]]; then
    return 0
  fi

  local cluster_json=""
  if command -v ocm >/dev/null 2>&1 && ocm whoami >/dev/null 2>&1; then
    cluster_json="$(ocm describe cluster "${CLUSTER_NAME}" --json 2>/dev/null || true)"
  fi

  if [[ -z "${cluster_json}" ]]; then
    cluster_json="$(gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="export PATH=\"\$HOME/bin:\$PATH\"; ocm describe cluster \"${CLUSTER_NAME}\" --json 2>/dev/null" 2>/dev/null || true)"
  fi

  if [[ -n "${cluster_json}" ]]; then
    local parsed_endpoints base_domain api_url console_url
    parsed_endpoints="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    bd = d.get("dns", {}).get("base_domain", "") or ""
    au = d.get("api", {}).get("url", "") or ""
    cu = d.get("console", {}).get("url", "") or ""
    print(f"{bd}|{au}|{cu}")
except Exception:
    print("||")
' <<< "${cluster_json}")"
    IFS='|' read -r base_domain api_url console_url <<< "${parsed_endpoints}"

    if [[ -n "${base_domain}" && "${base_domain}" != "null" ]]; then
      OSD_BASE_DOMAIN="${DOMAIN_PREFIX}.${base_domain}"
      OSD_API_HOST="${api_url#https://}"
      OSD_API_HOST="${OSD_API_HOST%:6443}"
      if [[ -z "${OSD_API_HOST}" || "${OSD_API_HOST}" == "null" ]]; then
        OSD_API_HOST="api.${OSD_BASE_DOMAIN}"
      fi
      OSD_CONSOLE_HOST="${console_url#https://}"
      if [[ -z "${OSD_CONSOLE_HOST}" || "${OSD_CONSOLE_HOST}" == "null" ]]; then
        OSD_CONSOLE_HOST="console-openshift-console.apps.${OSD_BASE_DOMAIN}"
      fi
      OSD_OAUTH_HOST="oauth-openshift.apps.${OSD_BASE_DOMAIN}"

      # Persist discovered endpoints in config.env
      sed -i.bak \
        -e "s|^export OSD_BASE_DOMAIN=.*|export OSD_BASE_DOMAIN=\"${OSD_BASE_DOMAIN}\"|" \
        -e "s|^export OSD_API_HOST=.*|export OSD_API_HOST=\"${OSD_API_HOST}\"|" \
        -e "s|^export OSD_CONSOLE_HOST=.*|export OSD_CONSOLE_HOST=\"${OSD_CONSOLE_HOST}\"|" \
        -e "s|^export OSD_OAUTH_HOST=.*|export OSD_OAUTH_HOST=\"${OSD_OAUTH_HOST}\"|" \
        "${REPO_ROOT}/config.env"
      rm -f "${REPO_ROOT}/config.env.bak"
    fi
  fi

  # Fallback placeholder if cluster hasn't been created yet
  OSD_BASE_DOMAIN="${OSD_BASE_DOMAIN:-${DOMAIN_PREFIX}.<id>.p2.openshiftapps.com}"
  OSD_API_HOST="${OSD_API_HOST:-api.${OSD_BASE_DOMAIN}}"
  OSD_CONSOLE_HOST="${OSD_CONSOLE_HOST:-console-openshift-console.apps.${OSD_BASE_DOMAIN}}"
  OSD_OAUTH_HOST="${OSD_OAUTH_HOST:-oauth-openshift.apps.${OSD_BASE_DOMAIN}}"
}

discover_osd_endpoints

CONSOLE_HOST="${OSD_CONSOLE_HOST}"
OAUTH_HOST="${OSD_OAUTH_HOST}"
CYMBAL_STOREFRONT_HOST="cymbal-storefront-cymbal-storefront.apps.${OSD_BASE_DOMAIN}"
CYMBAL_LEDGER_HOST="cymbal-ledger-cymbal-stateful.apps.${OSD_BASE_DOMAIN}"
API_HOST="${OSD_API_HOST}"

print_commands() {
  cat <<EOF
==============================================================================
 1. SSH Tunnel Command to Bastion VM (Run from Local Machine)
==============================================================================
gcloud compute ssh ${BASTION_NAME} \\
  --project="${PROJECT_ID}" \\
  --zone="${ZONE}" \\
  --tunnel-through-iap

  Shortcut: ./scripts/06-access-and-test.sh ssh

==============================================================================
 2. Start / Check / Delete OSD Installation (Run Inside Bastion VM)
==============================================================================
# Start OSD cluster installation & HTPasswd IDP setup:
~/osd-setup/05-bastion-install-osd.sh

# Check cluster status in OCM:
~/osd-setup/05-bastion-install-osd.sh status

# Re-run HTPasswd IDP & kubeconfig setup:
~/osd-setup/05-bastion-install-osd.sh setup-idp

# Destroy OSD cluster & restart clean installation:
~/osd-setup/05-bastion-install-osd.sh restart

# Delete / destroy the OSD cluster completely:
~/osd-setup/05-bastion-install-osd.sh destroy

==============================================================================
 3. Connection Test Commands (Run Inside Bastion VM or via 'test' subcommand)
==============================================================================
export KUBECONFIG=~/.kube/config
oc whoami
oc get nodes -o wide
oc get clusterversion
oc get co
curl -kI https://${API_HOST}:6443/healthz
curl -kI https://${CONSOLE_HOST}

  Shortcut from local machine: ./scripts/06-access-and-test.sh test

==============================================================================
 4. Local /etc/hosts Setup for Private OSD Web Console & Phase 2 Cymbal Apps
    Uses ${CONSOLE_LOCAL_IP} so 127.0.0.1 remains free. All OpenShift Ingress
    routes (*.apps.${OSD_BASE_DOMAIN}) share the same VIP and tunnel.
==============================================================================
sudo sh -c 'cat <<HOSTS >> /etc/hosts
${CONSOLE_LOCAL_IP} ${CONSOLE_HOST}
${CONSOLE_LOCAL_IP} ${OAUTH_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_STOREFRONT_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_LEDGER_HOST}
HOSTS'

  Shortcut: ./scripts/06-access-and-test.sh hosts

==============================================================================
 5. HTTPS/HTTP Tunnel to Local Machine for Web Console & Cymbal App Access
==============================================================================
# Note for macOS only: enable ${CONSOLE_LOCAL_IP} on lo0 loopback interface first:
# sudo ifconfig lo0 alias ${CONSOLE_LOCAL_IP} up

sudo CLOUDSDK_CONFIG="\${CLOUDSDK_CONFIG:-\$HOME/.config/gcloud}" "\$(command -v gcloud)" compute ssh ${BASTION_NAME} \\
  --project="${PROJECT_ID}" \\
  --zone="${ZONE}" \\
  --tunnel-through-iap \\
  -- -N \\
  -L ${CONSOLE_LOCAL_IP}:443:${CONSOLE_HOST}:443 \\
  -L ${CONSOLE_LOCAL_IP}:80:${CONSOLE_HOST}:80

  Then open in your local browser:
    OpenShift Console : https://${CONSOLE_HOST}
    Cymbal Storefront : https://${CYMBAL_STOREFRONT_HOST}  (Phase 2 Option 1)
    Cymbal Ledger     : https://${CYMBAL_LEDGER_HOST}      (Phase 2 Option 2)
    Identity Provider : htpasswd
    Username          : ${OSD_ADMIN_USER}

  Shortcut: ./scripts/06-access-and-test.sh tunnel
==============================================================================
EOF
}

case "${ACTION}" in
  print)
    print_commands
    ;;
  ssh)
    echo "Connecting to Bastion VM '${BASTION_NAME}' via IAP tunnel..."
    gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap
    ;;
  test)
    echo "Running connection and OSD cluster health tests via Bastion '${BASTION_NAME}'..."
    gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="
        set -e
        export PATH=\"\$HOME/bin:\$PATH\"
        export KUBECONFIG=\"\$HOME/.kube/config\"
        echo '--- 1. Testing Private DNS Resolution ---'
        getent hosts ${API_HOST} ${CONSOLE_HOST} ${OAUTH_HOST} || true
        echo ''
        echo '--- 2. Testing OpenShift Dedicated API Health (:6443) ---'
        curl -skI https://${API_HOST}:6443/healthz | head -n 5
        echo ''
        echo '--- 3. Testing OpenShift Dedicated Web Console Ingress (:443) ---'
        curl -skI https://${CONSOLE_HOST} | head -n 5
        echo ''
        echo '--- 4. Checking Cluster Nodes & Version ---'
        oc whoami
        oc get clusterversion
        oc get nodes -o wide
        echo ''
        echo '--- 5. Web Console Login Credentials ---'
        echo \"URL      : https://${CONSOLE_HOST}\"
        echo \"IDP      : htpasswd\"
        echo \"Username : ${OSD_ADMIN_USER}\"
      "
    ;;
  hosts)
    if [[ "${CONSOLE_HOST}" == *"<id>"* ]]; then
      echo "ERROR: Cluster endpoints not yet discovered. Ensure the OSD cluster is created first."
      exit 1
    fi
    echo "Adding OpenShift Dedicated Console, OAuth, and Phase 2 Cymbal App routes (${CONSOLE_LOCAL_IP}) to /etc/hosts (requires sudo)..."
    sudo sed -i.bak "/${CONSOLE_HOST}/d; /${OAUTH_HOST}/d; /${CYMBAL_STOREFRONT_HOST}/d; /${CYMBAL_LEDGER_HOST}/d" /etc/hosts
    sudo rm -f /etc/hosts.bak
    sudo sh -c "cat <<HOSTS >> /etc/hosts
${CONSOLE_LOCAL_IP} ${CONSOLE_HOST}
${CONSOLE_LOCAL_IP} ${OAUTH_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_STOREFRONT_HOST}
${CONSOLE_LOCAL_IP} ${CYMBAL_LEDGER_HOST}
HOSTS"
    echo "[UPDATED] Mapped ${CONSOLE_LOCAL_IP} ->"
    echo "  - ${CONSOLE_HOST}"
    echo "  - ${OAUTH_HOST}"
    echo "  - ${CYMBAL_STOREFRONT_HOST}"
    echo "  - ${CYMBAL_LEDGER_HOST}"
    if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
      echo ""
      echo "=============================================================================="
      echo " [WINDOWS WSL DETECTED] Additional Step for Windows Browsers (Chrome / Edge)"
      echo "=============================================================================="
      echo " Because your browser runs on Windows, you must ALSO add these hostnames to"
      echo " C:\\Windows\\System32\\drivers\\etc\\hosts."
      echo ""
      echo " Open PowerShell as Administrator on Windows and run:"
      echo "------------------------------------------------------------------------------"
      echo "Add-Content -Path C:\\Windows\\System32\\drivers\\etc\\hosts -Value \"\`r\`n${CONSOLE_LOCAL_IP} ${CONSOLE_HOST}\`r\`n${CONSOLE_LOCAL_IP} ${OAUTH_HOST}\`r\`n${CONSOLE_LOCAL_IP} ${CYMBAL_STOREFRONT_HOST}\`r\`n${CONSOLE_LOCAL_IP} ${CYMBAL_LEDGER_HOST}\""
      echo "------------------------------------------------------------------------------"
      echo " NOTE: On WSL2, ensure CONSOLE_LOCAL_IP=\"127.0.0.1\" in config.env (default on"
      echo " WSL) so Windows localhost forwarding reaches the WSL2 tunnel."
      echo "=============================================================================="
    fi
    ;;
  tunnel)
    if [[ "${CONSOLE_HOST}" == *"<id>"* ]]; then
      echo "ERROR: Cluster endpoints not yet discovered. Ensure the OSD cluster is created first."
      exit 1
    fi
    GCLOUD_BIN="$(command -v gcloud || true)"
    if [[ -z "${GCLOUD_BIN}" ]]; then
      echo "ERROR: 'gcloud' CLI not found in PATH."
      exit 1
    fi
    USER_GCLOUD_CONFIG="${CLOUDSDK_CONFIG:-${HOME}/.config/gcloud}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "macOS detected: Adding loopback alias ${CONSOLE_LOCAL_IP} to lo0..."
      sudo ifconfig lo0 alias "${CONSOLE_LOCAL_IP}" up
    fi
    echo "Starting HTTPS/HTTP Tunnel (Local ${CONSOLE_LOCAL_IP}:443 & :80 -> ${CONSOLE_HOST} via ${BASTION_NAME})..."
    echo "Open https://${CONSOLE_HOST} in your browser once connected."
    sudo CLOUDSDK_CONFIG="${USER_GCLOUD_CONFIG}" "${GCLOUD_BIN}" compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      -- -N \
      -L "${CONSOLE_LOCAL_IP}:443:${CONSOLE_HOST}:443" \
      -L "${CONSOLE_LOCAL_IP}:80:${CONSOLE_HOST}:80"
    ;;
  *)
    echo "Usage: $0 [print|ssh|test|hosts|tunnel]"
    exit 1
    ;;
esac
