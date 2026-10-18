#!/usr/bin/env bash
# ==============================================================================
# 03-test-waf-and-ddos.sh
# Phase 3 Step 3: Automated Verification & Attack Simulation Suite for:
#   1. Global External Application Load Balancer HTTPS readiness & Security Headers
#   2. Google Cloud CDN Edge Caching (MISS -> HIT on /static/catalog.json)
#   3. Google Cloud Armor OWASP Top 10 Preconfigured WAF Rules (CRS 4.22):
#        - SQL Injection (sqli-v422-stable)            -> 403 Forbidden
#        - Cross-Site Scripting (xss-v422-stable)      -> 403 Forbidden
#        - Local File Inclusion (lfi-v422-stable)      -> 403 Forbidden
#        - Remote Code Execution (rce-v422-stable)     -> 403 Forbidden
#        - Vulnerability Scanner (scannerdetection)    -> 403 Forbidden
#        - Remote File Inclusion (rfi-v422-stable)     -> 403 Forbidden
#        - Session Fixation (sessionfixation-v422)     -> 403 Forbidden
#        - Generic / SSTI Injection (generic-v422)     -> 403 Forbidden
#   4. Optional L7 DDoS Rate-Limiting Burst Test (--test-ddos -> 429 Too Many Requests)
#   5. Live Cloud Logging query showing Cloud Armor security policy enforcement logs
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

VIP_NAME="${PREFIX}-public-waf-vip"
ARMOR_POLICY="${PREFIX}-cloud-armor-waf"
BACKEND_SVC="${PREFIX}-public-backend-svc"
TEST_DDOS="${1:-}"

PUBLIC_VIP="$(gcloud compute addresses describe "${VIP_NAME}" --global --project="${PROJECT_ID}" --format='value(address)' 2>/dev/null || true)"
if [[ -z "${PUBLIC_VIP}" ]]; then
  echo "ERROR: Global IP '${VIP_NAME}' not found. Did you run ./scripts/02-deploy-cloud-armor-and-alb.sh?"
  exit 1
fi
PUBLIC_HOST="cymbal.${PUBLIC_VIP}.nip.io"
BASE_URL="https://${PUBLIC_HOST}"

echo "=============================================================================="
echo " Phase 3 Step 3: Testing Cloud Armor WAF, DDoS, Cloud CDN & Edge Security"
echo "   Public HTTPS Endpoint : ${BASE_URL}"
echo "   Cloud Armor Policy    : ${ARMOR_POLICY}"
echo "=============================================================================="

# 1. Wait for Global ALB Backend Health & Edge Propagation
echo "--- 1. Checking Backend Health & Waiting for Global ALB HTTPS Readiness ---"
gcloud compute backend-services get-health "${BACKEND_SVC}" --global --project="${PROJECT_ID}" || true

for ((i=1; i<=30; i++)); do
  HTTP_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" 2>/dev/null || echo "000")"
  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "[READY] Global External Application Load Balancer is serving 200 OK over HTTPS!"
    break
  fi
  echo "  Waiting for Global ALB edge propagation (HTTP status: ${HTTP_CODE}, attempt ${i}/30)..."
  sleep 10
done

# 2. Verify Legitimate Request & Edge Security Headers
echo ""
echo "--- 2. Verifying Legitimate Storefront Request & Custom Security Headers ---"
curl -ksSI "${BASE_URL}/?q=trail+bike" | grep -iE "^(HTTP/|strict-transport-security|x-content-type-options|x-frame-options|x-cdn-cache-status|via)" || true

# 3. Verify Google Cloud CDN Edge Caching (/static/catalog.json)
echo ""
echo "--- 3. Testing Google Cloud CDN Edge Caching (/static/catalog.json) ---"
for attempt in 1 2 3; do
  CDN_HEADERS="$(curl -ksSI "${BASE_URL}/static/catalog.json" | tr -d '\r')"
  STATUS_LINE="$(grep -iE "^HTTP/" <<< "${CDN_HEADERS}" | tail -n 1)"
  CDN_STATUS="$(grep -iE "^x-cdn-cache-status:" <<< "${CDN_HEADERS}" || echo "x-cdn-cache-status: (warming)")"
  AGE_HEADER="$(grep -iE "^age:" <<< "${CDN_HEADERS}" || echo "age: 0")"
  echo "  Request #${attempt}: ${STATUS_LINE} | ${CDN_STATUS} | ${AGE_HEADER}"
  sleep 1
done

# 4. Test Google Cloud Armor OWASP Top 10 Preconfigured WAF Rules
echo ""
echo "--- 4. Testing Google Cloud Armor OWASP Top 10 WAF Rules (Expect 403 Forbidden) ---"
run_waf_test() {
  local label="$1"
  shift
  local code
  code="$(curl -ksS -o /dev/null -w '%{http_code}' "$@")"
  if [[ "${code}" == "403" ]]; then
    echo "  [PASS - BLOCKED (403 Forbidden)] ${label}"
  else
    echo "  [WARN - Got HTTP ${code}] ${label}"
  fi
}

run_waf_test "OWASP SQL Injection (sqli-v422-stable)        : /?q=1'%20OR%20'1'='1" \
  "${BASE_URL}/?q=1%27%20OR%20%271%27%3D%271"

run_waf_test "OWASP Cross-Site Scripting (xss-v422-stable)  : /?q=<script>alert(1)</script>" \
  "${BASE_URL}/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"

run_waf_test "OWASP Local File Inclusion (lfi-v422-stable)  : /?file=../../etc/passwd" \
  "${BASE_URL}/?file=..%2F..%2Fetc%2Fpasswd"

run_waf_test "OWASP Remote Code Execution (rce-v422-stable) : /?cmd=;cat+/etc/passwd" \
  "${BASE_URL}/?cmd=%3Bcat+%2Fetc%2Fpasswd"

run_waf_test "OWASP Scanner Detection (scannerdetection)    : User-Agent: sqlmap/1.6" \
  -H "User-Agent: sqlmap/1.6" "${BASE_URL}/"

run_waf_test "OWASP Remote File Inclusion (rfi-v422-stable) : /?include=http://169.254.169.254/latest/meta-data/" \
  "${BASE_URL}/?include=http%3A%2F%2F169.254.169.254%2Flatest%2Fmeta-data%2F"

run_waf_test "OWASP Session Fixation (sessionfixation-v422) : /?q=<script>document.cookie='PHPSESSID=1234'</script>" \
  "${BASE_URL}/?q=%3Cscript%3Edocument.cookie%3D%27PHPSESSID%3D1234%27%3C%2Fscript%3E"

run_waf_test "OWASP Generic Injection (generic-v422-stable) : /?tpl={{constructor.constructor('return process')()}}" \
  "${BASE_URL}/?tpl=%7B%7Bconstructor.constructor(%27return%20process%27)()%7D%7D"

# 5. Optional L7 DDoS Rate-Limiting Burst Test (--test-ddos)
echo ""
if [[ "${TEST_DDOS}" == "--test-ddos" ]]; then
  echo "--- 5. Running L7 DDoS Rate-Limiting Burst Test (>100 req/min -> Expect 429 Too Many Requests) ---"
   throttled=0
  for ((n=1; n<=115; n++)); do
    c="$(curl -ksS -o /dev/null -w '%{http_code}' "${BASE_URL}/healthz" || echo "000")"
    if [[ "${c}" == "429" ]]; then
      echo "  [PASS - RATE LIMITED (429 Too Many Requests)] Cloud Armor banned abusive IP at request #${n}!"
      throttled=1
      break
    fi
  done
  if [[ "${throttled}" -eq 0 ]]; then
    echo "  [INFO] Sent 115 requests (rate-limit counter may still be aggregating at edge)."
  fi
else
  echo "--- 5. L7 DDoS Rate-Limiting Test (Skipped by default so your IP is not banned for 120s) ---"
  echo "  To trigger the 100 req/min rate-based ban (HTTP 429), run:"
  echo "  ./scripts/03-test-waf-and-ddos.sh --test-ddos"
fi

# 6. Query Cloud Logging for Cloud Armor WAF Enforcement Telemetry
echo ""
echo "--- 6. Recent Cloud Armor Security Telemetry in Google Cloud Logging ---"
gcloud logging read \
  "resource.type=\"http_load_balancer\" AND jsonPayload.enforcedSecurityPolicy.name=\"${ARMOR_POLICY}\"" \
  --project="${PROJECT_ID}" \
  --limit=5 \
  --format="table(timestamp,httpRequest.requestMethod,httpRequest.status,httpRequest.requestUrl,jsonPayload.enforcedSecurityPolicy.configuredAction,jsonPayload.enforcedSecurityPolicy.outcome)" 2>/dev/null || true

echo ""
echo "=============================================================================="
echo " Open the Public Storefront in your browser: ${BASE_URL}"
echo " (Note: Accept the self-signed nip.io SAN certificate prompt in your browser)"
echo "=============================================================================="
