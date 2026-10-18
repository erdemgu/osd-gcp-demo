#!/usr/bin/env bash
# ==============================================================================
# 08-stop-start-vms.sh
# Gracefully stops, starts, or checks the status of all OpenShift Dedicated (OSD)
# Cluster VMs (Control Plane masters, Infra nodes, and Worker nodes across all
# zones) and the Bastion VM to save Google Cloud compute costs when idle.
#
# Usage:
#   ./scripts/08-stop-start-vms.sh status
#   ./scripts/08-stop-start-vms.sh stop [--keep-bastion]
#   ./scripts/08-stop-start-vms.sh start
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/config.env"
elif [[ -f "${HOME}/osd-setup/config.env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/osd-setup/config.env"
else
  echo "ERROR: config.env not found. Please run ./scripts/00-prereq-config.sh first."
  exit 1
fi

ACTION="${1:-status}"
OPTION="${2:-}"

ON_BASTION="false"
if [[ "$(hostname)" == "${BASTION_NAME}" || "$(hostname)" == *"-vm-bastion"* ]]; then
  ON_BASTION="true"
fi

# Helper: list cluster VMs in our VPC matching a role regex (e.g. "-worker-", "-infra-", "-master-")
# Note: OCM truncates CLUSTER_NAME when generating the OpenShift infra_id (e.g. "erd-osd-cluster" -> "erd-osd-cljb4"),
# so we match by the cluster's custom VPC (${VPC_NAME}) / ${PREFIX} plus the node role pattern.
list_vms() {
  local role_regex="$1"
  gcloud compute instances list \
    --project="${PROJECT_ID}" \
    --filter="(networkInterfaces.network~'/${VPC_NAME}$' OR name~'^${PREFIX}-') AND name~'${role_regex}' AND name!='${BASTION_NAME}'" \
    --format="csv[no-heading](name,zone.basename(),status)" 2>/dev/null || true
}

show_status() {
  echo "=============================================================================="
  echo " OpenShift Dedicated (OSD) Cluster & Bastion VM Power Status"
  echo "   Project : ${PROJECT_ID}"
  echo "   Region  : ${REGION}"
  echo "   VPC     : ${VPC_NAME}"
  echo "   Cluster : ${CLUSTER_NAME}"
  echo "=============================================================================="
  gcloud compute instances list \
    --project="${PROJECT_ID}" \
    --filter="networkInterfaces.network~'/${VPC_NAME}$' OR name='${BASTION_NAME}' OR name~'^${PREFIX}-'" \
    --format="table(name,zone.basename(),machineType.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,status)"
}

stop_vms() {
  local keep_bastion="false"
  if [[ "${OPTION}" == "--keep-bastion" || "${ON_BASTION}" == "true" ]]; then
    keep_bastion="true"
  fi

  echo "=============================================================================="
  echo " Stopping OpenShift Dedicated Cluster VMs (${CLUSTER_NAME})"
  echo "=============================================================================="

  # 1. Stop Worker VMs first
  echo "--- Step 1: Stopping Worker Nodes ---"
  local worker_lines
  worker_lines="$(list_vms "-worker-")"
  if [[ -z "${worker_lines}" ]]; then
    echo "  No worker VMs found in VPC '${VPC_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" == "RUNNING" ]]; then
        echo "  -> Stopping worker ${vm_name} (${vm_zone})..."
        gcloud compute instances stop "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [SKIP] Worker ${vm_name} (${vm_zone}) is already ${vm_status}."
      fi
    done <<< "${worker_lines}"
  fi

  # 2. Stop Infrastructure VMs second (OSD dedicated infra nodes)
  echo ""
  echo "--- Step 2: Stopping Infrastructure (Infra) Nodes ---"
  local infra_lines
  infra_lines="$(list_vms "-infra-")"
  if [[ -z "${infra_lines}" ]]; then
    echo "  No infra VMs found in VPC '${VPC_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" == "RUNNING" ]]; then
        echo "  -> Stopping infra node ${vm_name} (${vm_zone})..."
        gcloud compute instances stop "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [SKIP] Infra node ${vm_name} (${vm_zone}) is already ${vm_status}."
      fi
    done <<< "${infra_lines}"
  fi

  # 3. Stop Control Plane (Master) VMs third
  echo ""
  echo "--- Step 3: Stopping Control Plane (Master) Nodes ---"
  local master_lines
  master_lines="$(list_vms "-master-")"
  if [[ -z "${master_lines}" ]]; then
    echo "  No master VMs found in VPC '${VPC_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" == "RUNNING" ]]; then
        echo "  -> Stopping master ${vm_name} (${vm_zone})..."
        gcloud compute instances stop "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [SKIP] Master ${vm_name} (${vm_zone}) is already ${vm_status}."
      fi
    done <<< "${master_lines}"
  fi

  # 4. Stop Bastion VM last (unless --keep-bastion or running inside Bastion)
  echo ""
  echo "--- Step 4: Bastion VM (${BASTION_NAME}) ---"
  if [[ "${keep_bastion}" == "true" ]]; then
    echo "  [SKIP] Keeping Bastion VM '${BASTION_NAME}' running."
  else
    local bastion_status
    bastion_status="$(gcloud compute instances describe "${BASTION_NAME}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" \
      --format="value(status)" 2>/dev/null || echo "NOT_FOUND")"
    if [[ "${bastion_status}" == "RUNNING" ]]; then
      echo "  -> Stopping Bastion VM ${BASTION_NAME} (${ZONE})..."
      gcloud compute instances stop "${BASTION_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --quiet
    else
      echo "  [SKIP] Bastion VM ${BASTION_NAME} is ${bastion_status}."
    fi
  fi

  echo ""
  show_status
}

start_vms() {
  echo "=============================================================================="
  echo " Starting OpenShift Dedicated Cluster & Bastion VMs (${CLUSTER_NAME})"
  echo "=============================================================================="

  # 1. Start Bastion VM first
  echo "--- Step 1: Starting Bastion VM (${BASTION_NAME}) ---"
  local bastion_status
  bastion_status="$(gcloud compute instances describe "${BASTION_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")"
  if [[ "${bastion_status}" == "TERMINATED" || "${bastion_status}" == "STOPPED" ]]; then
    echo "  -> Starting Bastion VM ${BASTION_NAME} (${ZONE})..."
    gcloud compute instances start "${BASTION_NAME}" \
      --zone="${ZONE}" \
      --project="${PROJECT_ID}" \
      --quiet
  else
    echo "  [OK] Bastion VM ${BASTION_NAME} is ${bastion_status}."
  fi

  # 2. Start Control Plane (Master) VMs first so etcd & API server form quorum
  echo ""
  echo "--- Step 2: Starting Control Plane (Master) Nodes ---"
  local master_lines
  master_lines="$(list_vms "-master-")"
  if [[ -z "${master_lines}" ]]; then
    echo "  No master VMs found in VPC '${VPC_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" != "RUNNING" ]]; then
        echo "  -> Starting master ${vm_name} (${vm_zone})..."
        gcloud compute instances start "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [OK] Master ${vm_name} (${vm_zone}) is already RUNNING."
      fi
    done <<< "${master_lines}"
  fi

  # 3. Start Infrastructure (Infra) VMs second
  echo ""
  echo "--- Step 3: Starting Infrastructure (Infra) Nodes ---"
  local infra_lines
  infra_lines="$(list_vms "-infra-")"
  if [[ -z "${infra_lines}" ]]; then
    echo "  No infra VMs found in VPC '${VPC_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" != "RUNNING" ]]; then
        echo "  -> Starting infra node ${vm_name} (${vm_zone})..."
        gcloud compute instances start "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [OK] Infra node ${vm_name} (${vm_zone}) is already RUNNING."
      fi
    done <<< "${infra_lines}"
  fi

  # 4. Start Worker VMs across all zones
  echo ""
  echo "--- Step 4: Starting Worker Nodes ---"
  local worker_lines
  worker_lines="$(list_vms "-worker-")"
  if [[ -z "${worker_lines}" ]]; then
    echo "  No worker VMs found in VPC '${VPC_NAME}'."
  else
    while IFS=, read -r vm_name vm_zone vm_status; do
      [[ -z "${vm_name}" ]] && continue
      if [[ "${vm_status}" != "RUNNING" ]]; then
        echo "  -> Starting worker ${vm_name} (${vm_zone})..."
        gcloud compute instances start "${vm_name}" \
          --zone="${vm_zone}" \
          --project="${PROJECT_ID}" \
          --quiet
      else
        echo "  [OK] Worker ${vm_name} (${vm_zone}) is already RUNNING."
      fi
    done <<< "${worker_lines}"
  fi

  # 5. Wait for API server & approve any pending CSRs so nodes become Ready
  echo ""
  echo "--- Step 5: Waiting for OpenShift API & Approving Pending Node CSRs ---"
  if [[ "${ON_BASTION}" == "true" ]]; then
    export PATH="${HOME}/bin:${PATH}"
    export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
    for ((i=1; i<=30; i++)); do
      if oc get nodes >/dev/null 2>&1; then
        break
      fi
      echo "  Waiting for OpenShift API server to respond (attempt ${i}/30)..."
      sleep 10
    done
    for csr in $(oc get csr --no-headers 2>/dev/null | awk '/Pending/ {print $1}'); do
      oc adm certificate approve "${csr}" || true
    done
    oc get nodes -o wide || true
  else
    gcloud compute ssh "${BASTION_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${ZONE}" \
      --tunnel-through-iap \
      --command="
        export PATH=\"\$HOME/bin:\$PATH\"
        export KUBECONFIG=\"\$HOME/.kube/config\"
        [[ -f \"\$HOME/osd-setup/config.env\" ]] && source \"\$HOME/osd-setup/config.env\"
        for ((i=1; i<=30; i++)); do
          if oc get nodes >/dev/null 2>&1; then
            break
          fi
          echo \"  Waiting for OpenShift API server to respond (attempt \${i}/30)...\"
          sleep 10
        done
        for csr in \$(oc get csr --no-headers 2>/dev/null | awk '/Pending/ {print \$1}'); do
          oc adm certificate approve \"\${csr}\" || true
        done
        echo ''
        oc get nodes -o wide || true
      " || true
  fi

  echo ""
  show_status
}

case "${ACTION}" in
  status)
    show_status
    ;;
  stop)
    stop_vms
    ;;
  start)
    start_vms
    ;;
  *)
    echo "Usage: $0 [status|stop|start] [--keep-bastion]"
    echo ""
    echo "Commands:"
    echo "  status                 Show current RUNNING/TERMINATED state of all Cluster & Bastion VMs"
    echo "  stop                   Gracefully stop Workers -> Infra -> Control Plane Masters -> Bastion VM"
    echo "  stop --keep-bastion    Stop Cluster VMs (Workers + Infra + Masters) but keep Bastion VM running"
    echo "  start                  Start Bastion -> Control Plane Masters -> Infra -> Workers & approve CSRs"
    exit 1
    ;;
esac
