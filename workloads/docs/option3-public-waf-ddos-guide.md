# Option 3 (Phase 3): Public Workload Exposure with Google Cloud Armor WAF, DDoS, Cloud CDN & Global External ALB

This guide walks through exposing a public-facing application (`Cymbal Global Public Storefront`) from your **100% Private OpenShift Dedicated (`--private`)** cluster on Google Cloud using Google Cloud's defense-in-depth edge security and observability best practices—while keeping the OpenShift API (`:6443`), Web Console, OAuth server, and worker nodes completely private (zero public IP addresses on cluster nodes).

---

## 1. Architecture & Defense-in-Depth Stack

| Layer | Google Cloud / OpenShift Service | Resource Name | Security & Performance Capability |
| :--- | :--- | :--- | :--- |
| **1. Volumetric L3/L4 DDoS** | **Global Static Anycast IPv4 + GFE** | `${PREFIX}-public-waf-vip` | Absorbs SYN floods, UDP amplification, and volumetric L3/L4 attacks at 180+ Google Edge POPs. |
| **2. Edge TLS & Cryptography** | **Google SSL Policy (`MODERN`) + SAN TLS Cert** | `${PREFIX}-ssl-policy-modern`<br>`${PREFIX}-public-tls-cert` | Enforces TLS 1.2 & TLS 1.3 modern cipher suites at the edge for `https://cymbal.<PUBLIC_VIP>.nip.io`. |
| **3. Edge L7 WAF (OWASP Top 10)** | **Google Cloud Armor (`Priority 1000–1008`)** | `${PREFIX}-cloud-armor-waf` | Evaluates ModSecurity CRS 4.22 preconfigured WAF rules (`sqli-v422-stable`, `xss-v422-stable`, `lfi-v422-stable`, `rce-v422-stable`, `scannerdetection-v422-stable`, `protocolattack-v422-stable`, `rfi-v422-stable`, `sessionfixation-v422-stable`, `generic-v422-stable`) and blocks attacks at the edge (`403 Forbidden`). |
| **4. Edge L7 DDoS & Rate Limiting** | **Google Cloud Armor (`Priority 2000`)** | `${PREFIX}-cloud-armor-waf` | `rate-based-ban`: throttles & bans any client IP exceeding `100 requests/min` with `429 Too Many Requests` for `120s`. |
| **5. Global Edge Caching** | **Google Cloud CDN (`--enable-cdn`)** | `${PREFIX}-public-backend-svc` | Caches `/static/catalog.json` and static storefront assets at Google's edge (`X-CDN-Cache-Status: HIT`), offloading OpenShift pods. |
| **6. Hybrid Edge-to-Private-VPC** | **Zonal `GCE_VM_IP_PORT` NEGs** | `${PREFIX}-public-neg-<zone>` | Routes clean requests over Google's internal Andromeda SDN directly to private OSD worker VMs across Zones `-a`, `-b`, `-c` on NodePort `:30080` (worker VMs have no public IPs). |
| **7. VPC Perimeter & Flow Audit** | **Least-Privilege GFE Firewall + VPC Flow Logs** | `${PREFIX}-allow-gfe-public-neg` | Allows **only** Google Front End ranges (`130.211.0.0/22`, `35.191.0.0/16`) to reach `tcp:30080` on `<infra-id>-worker` with Firewall Rule Logging + 10% Sampled VPC Flow Logs enabled. |
| **8. Observability & Probing** | **Cloud Logging + Cloud Monitoring Uptime Check** | `${PREFIX}-public-uptime-check` | 100% sampled ALB & Cloud Armor security logs in Cloud Logging + multi-region HTTPS Uptime Checks (USA, Europe, Asia-Pacific) probing `/healthz`. |
| **9. In-Cluster Isolation** | **OpenShift `restricted-v2` SCC + `NetworkPolicy`** | `cymbal-public-zero-trust-netpol` | Runs pods non-root with dropped capabilities and restricts East-West pod traffic inside `cymbal-public`. |

---

## 2. Step-by-Step Deployment

### Prerequisite: Sync Workloads to Bastion VM (Run on Local Workstation)
```bash
./workloads/sync-to-bastion.sh
```

### Step 1: Deploy the 3-Zone Public Storefront & Zero-Trust `NetworkPolicy` (Run Inside Bastion VM)
SSH into the Bastion VM (`./scripts/06-access-and-test.sh ssh`) and run:
```bash
cd ~/osd-setup/workloads/option3-public-waf-ddos
./scripts/01-deploy-public-workload.sh
```
What this does:
1. Creates namespace `cymbal-public` and applies `cymbal-public-zero-trust-netpol`.
2. Deploys the 3-replica `cymbal-public-web` storefront across all 3 availability zones (`-a`, `-b`, `-c`) under OpenShift's `restricted-v2` SCC.
3. Exposes `cymbal-public-neg-svc` on `NodePort` `:30080`.

---

### Step 2: Deploy Cloud Armor WAF, DDoS, Cloud CDN, Zonal NEGs & Global External ALB
Run inside the Bastion VM (or from your Local Workstation):
```bash
cd ~/osd-setup/workloads/option3-public-waf-ddos
./scripts/02-deploy-cloud-armor-and-alb.sh
```
What this does:
1. Enables sampled **VPC Flow Logs (`0.1`)** on `${PREFIX}-subnet-worker`.
2. Discovers the OSD worker nodes and their network tag (`<infra-id>-worker`) and creates the **Least-Privilege GFE Firewall Rule (`${PREFIX}-allow-gfe-public-neg`)** with **Firewall Rule Logging** enabled.
3. Creates Zonal `GCE_VM_IP_PORT` Network Endpoint Groups (`${PREFIX}-public-neg-<zone>`) and registers each private worker VM (`:30080`).
4. Creates the **Google Cloud Armor Standard Tier Policy (`${PREFIX}-cloud-armor-waf`)** with `VERBOSE` logging, 9 OWASP CRS 4.22 WAF rules (`Priority 1000–1008`), and L7 Rate-Based Ban (`Priority 2000`).
5. Reserves a Global Static Anycast IPv4 (`${PREFIX}-public-waf-vip`), creates a `MODERN` TLS 1.2+ SSL Policy (`${PREFIX}-ssl-policy-modern`), and creates a SAN TLS Certificate for `https://cymbal.<PUBLIC_VIP>.nip.io`.
6. Creates the Global External Application Load Balancer (`EXTERNAL_MANAGED`) with **Cloud CDN**, custom security response headers (`Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `X-CDN-Cache-Status`), and 100% Cloud Logging.
7. Creates a **Google Cloud Monitoring Global HTTPS Uptime Check** probing `/healthz` from USA, Europe, and Asia-Pacific.

---

### Step 3: Run the Automated WAF, CDN & DDoS Verification Suite
*(Note: Initial Global External ALB propagation takes ~2–4 minutes after creation).*
```bash
./scripts/03-test-waf-and-ddos.sh
```
Expected verification output:
- **Legitimate HTTPS Request**: `HTTP/2 200` + `strict-transport-security`, `x-content-type-options: nosniff`, `x-frame-options: DENY`
- **Google Cloud CDN Cache Test (`/static/catalog.json`)**: `x-cdn-cache-status: MISS` $\rightarrow$ `x-cdn-cache-status: HIT`
- **OWASP Top 10 WAF Attack Simulation**:
  - `OWASP SQL Injection (sqli-v422-stable)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Cross-Site Scripting (xss-v422-stable)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Local File Inclusion (lfi-v422-stable)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Remote Code Execution (rce-v422-stable)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Scanner Detection (scannerdetection)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Remote File Inclusion (rfi-v422-stable)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Session Fixation (sessionfixation-v422)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
  - `OWASP Generic Injection (generic-v422-stable)` $\rightarrow$ **`[PASS - BLOCKED (403 Forbidden)]`**
- **Optional L7 DDoS Burst Test** (sends >100 req/min to trigger `429 Too Many Requests`):
  ```bash
  ./scripts/03-test-waf-and-ddos.sh --test-ddos
  ```
- **Cloud Logging Telemetry**: Displays recent Cloud Armor block logs (`enforcedSecurityPolicy`).

You can also open `https://cymbal.<PUBLIC_VIP>.nip.io` directly in your browser (no IAP tunnel required!) and click the interactive **WAF & CDN Test Buttons** in the UI.

---

## 3. Cleanup & Cost Control (`04-cleanup-public-waf.sh`)

To remove the Global External Application Load Balancer, Cloud Armor Policy, Global IP, Zonal NEGs, GFE Firewall Rule, Uptime Check, and `cymbal-public` namespace when you finish testing:
```bash
./scripts/04-cleanup-public-waf.sh
```
