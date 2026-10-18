#!/usr/bin/env bash
# ==============================================================================
# 02-deploy-cloud-armor-and-alb.sh
# Phase 3 Step 2: Provisions the Google Cloud Edge Security, Caching & Observability Stack:
#   1. Enables Sampled VPC Flow Logs (0.1) on ${SUBNET_WORKER}
#   2. Creates Least-Privilege GFE Firewall Rule (${PREFIX}-allow-gfe-public-neg)
#      with Firewall Rule Logging enabled (allows ONLY 130.211.0.0/22 & 35.191.0.0/16
#      to tcp:30080 on OSD worker nodes)
#   3. Creates Zonal GCE_VM_IP_PORT Network Endpoint Groups (NEGs) across all
#      OSD worker zones and registers private worker VMs (:30080)
#   4. Creates Google Cloud Armor Standard Tier WAF & L7 DDoS Security Policy
#      (${PREFIX}-cloud-armor-waf):
#        - Priority 1000: OWASP SQL Injection (sqli-v422-stable -> 403 Forbidden)
#        - Priority 1001: OWASP Cross-Site Scripting (xss-v422-stable -> 403 Forbidden)
#        - Priority 1002: OWASP Local File Inclusion (lfi-v422-stable -> 403 Forbidden)
#        - Priority 1003: OWASP Remote Code Execution (rce-v422-stable -> 403 Forbidden)
#        - Priority 1004: OWASP Scanner Detection (scannerdetection-v422-stable -> 403 Forbidden)
#        - Priority 1005: OWASP Protocol Attack (protocolattack-v422-stable -> 403 Forbidden)
#        - Priority 1006: OWASP Remote File Inclusion / SSRF (rfi-v422-stable -> 403 Forbidden)
#        - Priority 1007: OWASP Session Fixation (sessionfixation-v422-stable -> 403 Forbidden)
#        - Priority 1008: OWASP Generic / NodeJS / SSTI Injection (generic-v422-stable -> 403 Forbidden)
#        - Priority 2000: Rate-Based Ban (100 req/min/IP -> 429 Too Many Requests for 120s)
#   5. Reserves Global Anycast IPv4 (${PREFIX}-public-waf-vip), creates Modern TLS 1.2+
#      SSL Policy (${PREFIX}-ssl-policy-modern), and creates SAN TLS Certificate
#      for cymbal.<PUBLIC_VIP>.nip.io
#   6. Creates Global External Application Load Balancer (EXTERNAL_MANAGED) with
#      Cloud CDN enabled, Custom Security Response Headers, and 100% Cloud Logging
#   7. Creates Google Cloud Monitoring Global HTTPS Uptime Check
#
# Can be run inside the Bastion VM (with user gcloud auth) or on Local Workstation!
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

NODEPORT="30080"
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
echo " Phase 3 Step 2: Deploying Cloud Armor WAF, DDoS, Cloud CDN & Global External ALB"
echo "   Project : ${PROJECT_ID}"
echo "   Region  : ${REGION}"
echo "   VPC     : ${VPC_NAME}"
echo "=============================================================================="

# Ensure user account is active (Bastion VM's attached SA has read-only IAM roles)
ACTIVE_GCLOUD_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
if [[ -z "${ACTIVE_GCLOUD_ACCOUNT}" || "${ACTIVE_GCLOUD_ACCOUNT}" == "${SA_EMAIL}" || "${ACTIVE_GCLOUD_ACCOUNT}" == *".iam.gserviceaccount.com" ]]; then
  echo "NOTE: Active gcloud account is '${ACTIVE_GCLOUD_ACCOUNT:-none}' (VM service account has read-only permissions)."
  echo "Please authenticate with your GCP user account to create Cloud Armor & Global Load Balancer resources:"
  gcloud auth login --no-launch-browser
fi

# 1. Enable Cloud Monitoring & Logging APIs + Sampled VPC Flow Logs on Worker Subnet
echo "--- 1. Enabling Monitoring/Logging APIs & Sampled VPC Flow Logs on '${SUBNET_WORKER}' ---"
gcloud services enable compute.googleapis.com logging.googleapis.com monitoring.googleapis.com \
  --project="${PROJECT_ID}" --quiet

gcloud compute networks subnets update "${SUBNET_WORKER}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --enable-flow-logs \
  --logging-flow-sampling=0.1 \
  --logging-aggregation-interval=interval-5-sec \
  --logging-metadata=include-all \
  --quiet
echo "[OK] Sampled VPC Flow Logs (10%) enabled on '${SUBNET_WORKER}'."

# 2. Discover OSD Worker Nodes, Worker Network Tag & Configure Least-Privilege GFE Firewall Rule
echo ""
echo "--- 2. Discovering OSD Worker Nodes & Configuring Least-Privilege GFE Firewall Rule ---"
WORKER_LINES="$(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --filter="(networkInterfaces.network~'/${VPC_NAME}$' OR name~'^${PREFIX}-') AND name~'-worker-' AND status='RUNNING'" \
  --format="csv[no-heading](name,zone.basename(),networkInterfaces[0].networkIP,tags.items[0])" 2>/dev/null || true)"

if [[ -z "${WORKER_LINES}" ]]; then
  echo "ERROR: No RUNNING OSD worker VMs found in VPC '${VPC_NAME}'."
  exit 1
fi

WORKER_TAG="$(head -n 1 <<< "${WORKER_LINES}" | awk -F',' '{print $4}')"
echo "  -> Discovered OSD Worker Network Tag: ${WORKER_TAG:-none}"

if gcloud compute firewall-rules describe "${FW_GFE_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Firewall rule '${FW_GFE_NAME}' already exists."
else
  FW_ARGS=(
    compute firewall-rules create "${FW_GFE_NAME}"
    --project="${PROJECT_ID}"
    --network="${VPC_NAME}"
    --direction=INGRESS
    --priority=1000
    --action=ALLOW
    --rules="tcp:${NODEPORT}"
    --source-ranges="130.211.0.0/22,35.191.0.0/16"
    --enable-logging
    --description="Allow ONLY Google Front Ends (GFEs) and GCP Health Checks to reach Cymbal Public NodePort ${NODEPORT}"
  )
  if [[ -n "${WORKER_TAG}" ]]; then
    FW_ARGS+=(--target-tags="${WORKER_TAG}")
  fi
  gcloud "${FW_ARGS[@]}" --quiet
  echo "[CREATED] Least-Privilege GFE Firewall rule '${FW_GFE_NAME}' (tcp:${NODEPORT}, logging enabled)."
fi

# 3. Create Zonal GCE_VM_IP_PORT Network Endpoint Groups (NEGs) for Private Worker VMs
echo ""
echo "--- 3. Creating Zonal GCE_VM_IP_PORT NEGs for Private OSD Worker VMs (:${NODEPORT}) ---"
declare -A ZONE_NEGS=()
while IFS=, read -r vm_name vm_zone vm_ip _vm_tag; do
  [[ -z "${vm_name}" ]] && continue
  neg_name="${PREFIX}-public-neg-${vm_zone}"
  ZONE_NEGS["${vm_zone}"]="${neg_name}"

  if ! gcloud compute network-endpoint-groups describe "${neg_name}" \
      --zone="${vm_zone}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute network-endpoint-groups create "${neg_name}" \
      --project="${PROJECT_ID}" \
      --zone="${vm_zone}" \
      --network-endpoint-type="GCE_VM_IP_PORT" \
      --network="${VPC_NAME}" \
      --subnet="${SUBNET_WORKER}" \
      --default-port="${NODEPORT}" \
      --quiet
    echo "  [CREATED] Zonal NEG '${neg_name}' in ${vm_zone}."
  fi

  # Register worker VM endpoint if not already in NEG
  EXISTING_EP="$(gcloud compute network-endpoint-groups list-network-endpoints "${neg_name}" \
    --zone="${vm_zone}" --project="${PROJECT_ID}" \
    --format="value( networkEndpoint.instance )" 2>/dev/null | grep -Fx "${vm_name}" || true)"
  if [[ -z "${EXISTING_EP}" ]]; then
    gcloud compute network-endpoint-groups update "${neg_name}" \
      --project="${PROJECT_ID}" \
      --zone="${vm_zone}" \
      --add-endpoint="instance=${vm_name},ip=${vm_ip},port=${NODEPORT}" \
      --quiet
    echo "  [ADDED] Registered private worker '${vm_name}' (${vm_ip}:${NODEPORT}) in '${neg_name}'."
  else
    echo "  [SKIP] Worker '${vm_name}' (${vm_ip}:${NODEPORT}) already registered in '${neg_name}'."
  fi
done <<< "${WORKER_LINES}"

# 4. Create Google Cloud Armor WAF & L7 DDoS Security Policy (Standard Tier)
echo ""
echo "--- 4. Configuring Google Cloud Armor WAF & DDoS Policy (${ARMOR_POLICY}) ---"
if ! gcloud compute security-policies describe "${ARMOR_POLICY}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute security-policies create "${ARMOR_POLICY}" \
    --project="${PROJECT_ID}" \
    --type="CLOUD_ARMOR" \
    --description="OSD Phase 3 Cloud Armor WAF (OWASP CRS 4.22) and L7 DDoS Rate-Limiting Policy" \
    --quiet
  gcloud compute security-policies update "${ARMOR_POLICY}" \
    --project="${PROJECT_ID}" \
    --log-level=VERBOSE \
    --quiet
  echo "[CREATED] Cloud Armor Policy '${ARMOR_POLICY}' (VERBOSE logging enabled)."
else
  echo "[SKIP] Cloud Armor Policy '${ARMOR_POLICY}' already exists."
fi

# Helper to create or update Cloud Armor rule at the given priority
ensure_armor_rule() {
  local priority="$1"
  shift
  if gcloud compute security-policies rules describe "${priority}" \
      --security-policy="${ARMOR_POLICY}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute security-policies rules update "${priority}" \
      --security-policy="${ARMOR_POLICY}" \
      --project="${PROJECT_ID}" \
      "$@" \
      --quiet
    echo "  [UPDATED] Cloud Armor rule priority ${priority}."
  else
    gcloud compute security-policies rules create "${priority}" \
      --security-policy="${ARMOR_POLICY}" \
      --project="${PROJECT_ID}" \
      "$@" \
      --quiet
    echo "  [CREATED] Cloud Armor rule priority ${priority}."
  fi
}

# Remove legacy Priority 100 rule if present (rate-based-ban must run at Priority 2000 AFTER OWASP deny rules)
if gcloud compute security-policies rules describe 100 \
  --security-policy="${ARMOR_POLICY}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute security-policies rules delete 100 \
    --security-policy="${ARMOR_POLICY}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "  [REMOVED] Legacy Cloud Armor Rule Priority 100 (moved to Priority 2000 after OWASP WAF rules)."
fi

# Priority 1000-1008: OWASP Top 10 ModSecurity CRS 4.22 Preconfigured WAF Rules (Evaluated FIRST)
ensure_armor_rule 1000 \
  --expression="evaluatePreconfiguredWaf('sqli-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP SQL Injection (sqli-v422-stable)"

ensure_armor_rule 1001 \
  --expression="evaluatePreconfiguredWaf('xss-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP Cross-Site Scripting (xss-v422-stable)"

ensure_armor_rule 1002 \
  --expression="evaluatePreconfiguredWaf('lfi-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP Local File Inclusion / Path Traversal (lfi-v422-stable)"

ensure_armor_rule 1003 \
  --expression="evaluatePreconfiguredWaf('rce-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP Remote Code Execution / Command Injection (rce-v422-stable)"

ensure_armor_rule 1004 \
  --expression="evaluatePreconfiguredWaf('scannerdetection-v422-stable')" \
  --action="deny-403" \
  --description="Block Automated Vulnerability Scanners (scannerdetection-v422-stable)"

ensure_armor_rule 1005 \
  --expression="evaluatePreconfiguredWaf('protocolattack-v422-stable')" \
  --action="deny-403" \
  --description="Block HTTP Request Smuggling & Protocol Attacks (protocolattack-v422-stable)"

ensure_armor_rule 1006 \
  --expression="evaluatePreconfiguredWaf('rfi-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP Remote File Inclusion / SSRF (rfi-v422-stable)"

ensure_armor_rule 1007 \
  --expression="evaluatePreconfiguredWaf('sessionfixation-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP Session Fixation (sessionfixation-v422-stable)"

ensure_armor_rule 1008 \
  --expression="evaluatePreconfiguredWaf('generic-v422-stable')" \
  --action="deny-403" \
  --description="Block OWASP Generic / NodeJS / SSTI Injection (generic-v422-stable)"

# Priority 2000: L7 DDoS Rate-Based Ban (Evaluated AFTER OWASP WAF rules; 100 req/min per client IP -> 429 for 120s)
ensure_armor_rule 2000 \
  --action="rate-based-ban" \
  --src-ip-ranges="*" \
  --rate-limit-threshold-count=100 \
  --rate-limit-threshold-interval-sec=60 \
  --ban-duration-sec=120 \
  --conform-action="allow" \
  --exceed-action="deny-429" \
  --enforce-on-key="IP" \
  --description="L7 DDoS defense: Rate-limit & ban IPs exceeding 100 req/min for 120s"

# 5. Reserve Global Static Anycast IPv4, SSL Policy (TLS 1.2+ MODERN), and SAN TLS Certificate
echo ""
echo "--- 5. Reserving Global Anycast IPv4, Modern SSL Policy & Edge TLS Certificate ---"
if ! gcloud compute addresses describe "${VIP_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses create "${VIP_NAME}" \
    --global \
    --ip-version=IPV4 \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Global Static Anycast IP '${VIP_NAME}'."
fi
PUBLIC_VIP="$(gcloud compute addresses describe "${VIP_NAME}" --global --project="${PROJECT_ID}" --format='value(address)')"
PUBLIC_HOST="cymbal.${PUBLIC_VIP}.nip.io"
echo "  -> Global Anycast IPv4 : ${PUBLIC_VIP}"
echo "  -> Public Edge Hostname: ${PUBLIC_HOST}"

if ! gcloud compute ssl-policies describe "${SSL_POLICY_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssl-policies create "${SSL_POLICY_NAME}" \
    --global \
    --profile="MODERN" \
    --min-tls-version="1.2" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] SSL Policy '${SSL_POLICY_NAME}' (TLS 1.2+ MODERN)."
else
  echo "[SKIP] SSL Policy '${SSL_POLICY_NAME}' already exists."
fi

if ! gcloud compute ssl-certificates describe "${SSL_CERT_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  TMP_CERT_DIR="$(mktemp -d)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "${TMP_CERT_DIR}/privkey.pem" \
    -out "${TMP_CERT_DIR}/fullchain.pem" \
    -subj "/CN=${PUBLIC_HOST}/O=Cymbal Global Edge" \
    -addext "subjectAltName=DNS:${PUBLIC_HOST},IP:${PUBLIC_VIP}" 2>/dev/null
  gcloud compute ssl-certificates create "${SSL_CERT_NAME}" \
    --global \
    --certificate="${TMP_CERT_DIR}/fullchain.pem" \
    --private-key="${TMP_CERT_DIR}/privkey.pem" \
    --project="${PROJECT_ID}" \
    --quiet
  rm -rf "${TMP_CERT_DIR}"
  echo "[CREATED] Edge TLS Certificate '${SSL_CERT_NAME}' for ${PUBLIC_HOST}."
else
  echo "[SKIP] Edge TLS Certificate '${SSL_CERT_NAME}' already exists."
fi

# 6. Create Global External Application Load Balancer + Cloud CDN + Security Headers + 100% Logging
echo ""
echo "--- 6. Creating Global External Application Load Balancer + Cloud CDN ---"
if ! gcloud compute health-checks describe "${HC_NAME}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute health-checks create http "${HC_NAME}" \
    --global \
    --port="${NODEPORT}" \
    --request-path="/healthz" \
    --check-interval=10s \
    --timeout=5s \
    --healthy-threshold=2 \
    --unhealthy-threshold=3 \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Global HTTP Health Check '${HC_NAME}' (:${NODEPORT}/healthz)."
fi

if ! gcloud compute backend-services describe "${BACKEND_SVC}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute backend-services create "${BACKEND_SVC}" \
    --global \
    --load-balancing-scheme="EXTERNAL_MANAGED" \
    --protocol="HTTP" \
    --health-checks="${HC_NAME}" \
    --enable-cdn \
    --cache-mode="CACHE_ALL_STATIC" \
    --default-ttl=3600 \
    --enable-logging \
    --logging-sample-rate=1.0 \
    --custom-response-header="Strict-Transport-Security: max-age=31536000; includeSubDomains" \
    --custom-response-header="X-Content-Type-Options: nosniff" \
    --custom-response-header="X-Frame-Options: DENY" \
    --custom-response-header="X-CDN-Cache-Status: {cdn_cache_status}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Global Backend Service '${BACKEND_SVC}' (Cloud CDN + 100% Logging)."
fi

gcloud compute backend-services update "${BACKEND_SVC}" \
  --global \
  --security-policy="${ARMOR_POLICY}" \
  --project="${PROJECT_ID}" \
  --quiet
echo "[UPDATED] Attached Cloud Armor Security Policy '${ARMOR_POLICY}' to '${BACKEND_SVC}'."

for vm_zone in "${!ZONE_NEGS[@]}"; do
  neg_name="${ZONE_NEGS[${vm_zone}]}"
  EXISTING_BACKEND="$(gcloud compute backend-services describe "${BACKEND_SVC}" \
    --global --project="${PROJECT_ID}" \
    --format="value(backends[].group)" 2>/dev/null | grep "${neg_name}" || true)"
  if [[ -z "${EXISTING_BACKEND}" ]]; then
    gcloud compute backend-services add-backend "${BACKEND_SVC}" \
      --global \
      --network-endpoint-group="${neg_name}" \
      --network-endpoint-group-zone="${vm_zone}" \
      --balancing-mode="RATE" \
      --max-rate-per-endpoint=100 \
      --project="${PROJECT_ID}" \
      --quiet
    echo "  [ADDED] Attached Zonal NEG '${neg_name}' (${vm_zone}) to '${BACKEND_SVC}'."
  else
    echo "  [SKIP] Zonal NEG '${neg_name}' (${vm_zone}) already attached to '${BACKEND_SVC}'."
  fi
done

if ! gcloud compute url-maps describe "${URL_MAP}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute url-maps create "${URL_MAP}" \
    --global \
    --default-service="${BACKEND_SVC}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] URL Map '${URL_MAP}'."
fi

if ! gcloud compute target-https-proxies describe "${HTTPS_PROXY}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute target-https-proxies create "${HTTPS_PROXY}" \
    --global \
    --url-map="${URL_MAP}" \
    --ssl-certificates="${SSL_CERT_NAME}" \
    --ssl-policy="${SSL_POLICY_NAME}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Target HTTPS Proxy '${HTTPS_PROXY}'."
fi

if ! gcloud compute target-http-proxies describe "${HTTP_PROXY}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute target-http-proxies create "${HTTP_PROXY}" \
    --global \
    --url-map="${URL_MAP}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Target HTTP Proxy '${HTTP_PROXY}'."
fi

if ! gcloud compute forwarding-rules describe "${FWD_HTTPS}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute forwarding-rules create "${FWD_HTTPS}" \
    --global \
    --load-balancing-scheme="EXTERNAL_MANAGED" \
    --address="${VIP_NAME}" \
    --target-https-proxy="${HTTPS_PROXY}" \
    --ports=443 \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Global HTTPS Forwarding Rule '${FWD_HTTPS}' (${PUBLIC_VIP}:443)."
fi

if ! gcloud compute forwarding-rules describe "${FWD_HTTP}" --global --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute forwarding-rules create "${FWD_HTTP}" \
    --global \
    --load-balancing-scheme="EXTERNAL_MANAGED" \
    --address="${VIP_NAME}" \
    --target-http-proxy="${HTTP_PROXY}" \
    --ports=80 \
    --project="${PROJECT_ID}" \
    --quiet
  echo "[CREATED] Global HTTP Forwarding Rule '${FWD_HTTP}' (${PUBLIC_VIP}:80)."
fi

# 7. Create Google Cloud Monitoring Global HTTPS Uptime Check
echo ""
echo "--- 7. Configuring Google Cloud Monitoring Global HTTPS Uptime Check ---"
EXISTING_UPTIME="$(gcloud monitoring uptime list-configs \
  --project="${PROJECT_ID}" \
  --filter="displayName='${UPTIME_DISPLAY_NAME}'" \
  --format="value(name)" 2>/dev/null || true)"
if [[ -z "${EXISTING_UPTIME}" ]]; then
  gcloud monitoring uptime create "${UPTIME_DISPLAY_NAME}" \
    --project="${PROJECT_ID}" \
    --resource-type="uptime-url" \
    --resource-labels="host=${PUBLIC_HOST},project_id=${PROJECT_ID}" \
    --protocol="https" \
    --port=443 \
    --path="/healthz" \
    --period=1 \
    --timeout=10 \
    --regions="usa-oregon,europe,asia-pacific" \
    --quiet || echo "[INFO] Uptime check creation skipped or already active."
  echo "[CREATED] Cloud Monitoring Global Uptime Check '${UPTIME_DISPLAY_NAME}' (US, EU, APAC -> /healthz)."
else
  echo "[SKIP] Cloud Monitoring Uptime Check '${UPTIME_DISPLAY_NAME}' already exists."
fi

echo ""
echo "=============================================================================="
echo " [SUCCESS] Phase 3 Google Cloud Public Edge Stack Deployed!"
echo "=============================================================================="
echo " Public HTTPS URL   : https://${PUBLIC_HOST}"
echo " Public HTTP URL    : http://${PUBLIC_HOST}"
echo " Static Catalog CDN : https://${PUBLIC_HOST}/static/catalog.json"
echo " Cloud Armor Policy : ${ARMOR_POLICY} (OWASP Top 10 + 100 req/min Rate-Based Ban)"
echo " SSL Policy         : ${SSL_POLICY_NAME} (TLS 1.2+ MODERN)"
echo " GFE Firewall Rule  : ${FW_GFE_NAME} (130.211.0.0/22, 35.191.0.0/16 -> tcp:${NODEPORT})"
echo ""
echo " NOTE: Global External Application Load Balancer propagation typically takes"
echo "       2-4 minutes after initial creation."
echo ""
echo " Next step: Run ./scripts/03-test-waf-and-ddos.sh"
echo "=============================================================================="
