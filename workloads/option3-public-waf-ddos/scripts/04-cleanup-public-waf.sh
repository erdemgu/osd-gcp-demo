#!/usr/bin/env bash
# ==============================================================================
# 04-cleanup-public-waf.sh
# Phase 3 Step 4: Cleanly removes all Phase 3 Public Edge, Cloud Armor WAF,
# Cloud CDN, Global External ALB, Zonal NEGs, GFE Firewall Rule, Uptime Check,
# and the OpenShift 'cymbal-public' namespace so hourly charges stop immediately.
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
  echo "ERROR: config.env not found."
  exit 1
fi

FW_GFE_NAME="${PREFIX}-allow-gfe-public-neg"
ARMOR_POLICY="${PREFIX}-cloud-armor-waf"
VIP_NAME="${PREFIX}-public-waf-vip"
SSL_POLICY_NAME="${PREFIX}-ssl-policy-modern"
SSL_CERT_NAME="${PREFIX}-public-tls-cert"
HC_NAME="${PREFIX}-public-hc"
BACKEND_SVC="${PREFIX}-public-backend-svc"
URL_MAP="${PREFIX}-public-url-map"
HTTPS_PROXY="${PREFIX}-public-https-proxy"
HTTP_PROXY="${PREFIX}-public-http-proxy"
FWD_HTTPS="${PREFIX}-public-https-fwd"
FWD_HTTP="${PREFIX}-public-http-fwd"
UPTIME_DISPLAY_NAME="${PREFIX}-public-uptime-check"

echo "=============================================================================="
echo " Cleaning Up Phase 3 Public Edge, Cloud Armor WAF, Cloud CDN & ALB Resources"
echo "=============================================================================="

# 1. Delete Cloud Monitoring Uptime Check
echo "--- 1. Deleting Cloud Monitoring Uptime Check (${UPTIME_DISPLAY_NAME}) ---"
UPTIME_IDS="$(gcloud monitoring uptime list-configs \
  --project="${PROJECT_ID}" \
  --filter="displayName='${UPTIME_DISPLAY_NAME}'" \
  --format="value(name)" 2>/dev/null || true)"
for uid in ${UPTIME_IDS}; do
  gcloud monitoring uptime delete "${uid}" --project="${PROJECT_ID}" --quiet && \
    echo "[DELETED] Uptime Check '${uid}'." || true
done

# 2. Delete Global Forwarding Rules
echo "--- 2. Deleting Global Forwarding Rules ---"
for fwd in "${FWD_HTTPS}" "${FWD_HTTP}"; do
  if gcloud compute forwarding-rules describe "${fwd}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute forwarding-rules delete "${fwd}" --global --project="${PROJECT_ID}" --quiet
    echo "[DELETED] Forwarding Rule '${fwd}'."
  fi
done

# 3. Delete Target HTTPS & HTTP Proxies
echo "--- 3. Deleting Target HTTPS & HTTP Proxies ---"
if gcloud compute target-https-proxies describe "${HTTPS_PROXY}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute target-https-proxies delete "${HTTPS_PROXY}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Target HTTPS Proxy '${HTTPS_PROXY}'."
fi
if gcloud compute target-http-proxies describe "${HTTP_PROXY}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute target-http-proxies delete "${HTTP_PROXY}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Target HTTP Proxy '${HTTP_PROXY}'."
fi

# 4. Delete URL Map & Backend Service
echo "--- 4. Deleting URL Map & Global Backend Service ---"
if gcloud compute url-maps describe "${URL_MAP}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute url-maps delete "${URL_MAP}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] URL Map '${URL_MAP}'."
fi
if gcloud compute backend-services describe "${BACKEND_SVC}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute backend-services delete "${BACKEND_SVC}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Backend Service '${BACKEND_SVC}'."
fi
if gcloud compute health-checks describe "${HC_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute health-checks delete "${HC_NAME}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Health Check '${HC_NAME}'."
fi

# 5. Delete SSL Certificate, SSL Policy, Global Static IP & Cloud Armor Policy
echo "--- 5. Deleting SSL Cert, SSL Policy, Global IP & Cloud Armor Policy ---"
if gcloud compute ssl-certificates describe "${SSL_CERT_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssl-certificates delete "${SSL_CERT_NAME}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] SSL Certificate '${SSL_CERT_NAME}'."
fi
if gcloud compute ssl-policies describe "${SSL_POLICY_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssl-policies delete "${SSL_POLICY_NAME}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] SSL Policy '${SSL_POLICY_NAME}'."
fi
if gcloud compute addresses describe "${VIP_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses delete "${VIP_NAME}" --global --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Global Static IP '${VIP_NAME}'."
fi
if gcloud compute security-policies describe "${ARMOR_POLICY}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute security-policies delete "${ARMOR_POLICY}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Cloud Armor Policy '${ARMOR_POLICY}'."
fi

# 6. Delete Zonal NEGs & Least-Privilege GFE Firewall Rule
echo "--- 6. Deleting Zonal NEGs & Least-Privilege GFE Firewall Rule ---"
NEG_LINES="$(gcloud compute network-endpoint-groups list \
  --project="${PROJECT_ID}" \
  --filter="name~'^${PREFIX}-public-neg-'" \
  --format="csv[no-heading](name,zone.basename())" 2>/dev/null || true)"
while IFS=, read -r neg_name neg_zone; do
  [[ -z "${neg_name}" ]] && continue
  gcloud compute network-endpoint-groups delete "${neg_name}" \
    --zone="${neg_zone}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Zonal NEG '${neg_name}' (${neg_zone})."
done <<< "${NEG_LINES}"

if gcloud compute firewall-rules describe "${FW_GFE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute firewall-rules delete "${FW_GFE_NAME}" --project="${PROJECT_ID}" --quiet
  echo "[DELETED] Firewall rule '${FW_GFE_NAME}'."
fi

# 7. Delete OpenShift 'cymbal-public' Namespace (if oc is available)
echo "--- 7. Deleting OpenShift Namespace 'cymbal-public' ---"
export PATH="${HOME}/bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  oc delete namespace cymbal-public --ignore-not-found=true --wait=true
  echo "[DELETED] OpenShift namespace 'cymbal-public'."
else
  echo "[SKIP] 'oc' session not active locally; run 'oc delete ns cymbal-public' on Bastion VM if needed."
fi

echo ""
echo "=============================================================================="
echo " [DONE] Phase 3 Public Edge & Cloud Armor WAF Cleanup Complete!"
echo "=============================================================================="
