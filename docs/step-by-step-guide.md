# Step-by-Step Installation & Customer Demo Guide: OpenShift Dedicated (OSD) on Google Cloud

Follow this end-to-end guide to:
- **Part 1 (Phase 1)**: Deploy a 100% private **Red Hat OpenShift Dedicated (OSD)** Customer Cloud Subscription (CCS) cluster inside a **new Custom VPC** on Google Cloud.
- **Part 2 (Phases 2 & 3 — Live Customer Demo Guide)**: Deploy and demonstrate three enterprise workload architectures (**Regional Cloud Filestore `RWX`**, **Google Cloud Hyperdisk `RWO` + Secret Manager CSI**, and **Public Edge Exposure with Google Cloud Armor WAF/DDoS + Cloud CDN + Global External ALB**).
- **Part 3 (Day-2 Operations & Cleanup)**: Stop/start cluster VMs to save costs, run minor/patch upgrades, or tear down the environment cleanly.

---

## Prerequisites Checklist

Before running the scripts, ensure you have completed the following:

1. **Visit the Google Cloud Red Hat OpenShift Portal & Verify OSD Requirements**:
   - Open [**https://console.cloud.google.com/redhat-openshift/**](https://console.cloud.google.com/redhat-openshift/) in your browser.
   - Verify your **Red Hat OpenShift Dedicated** subscription/entitlement on Google Cloud.
   - If using **Google Cloud Marketplace** billing (`marketplace-gcp`), review and accept the Google Cloud Marketplace Terms & Agreements at:
     [`https://console.cloud.google.com/marketplace/agreements/redhat-marketplace/red-hat-openshift-dedicated`](https://console.cloud.google.com/marketplace/agreements/redhat-marketplace/red-hat-openshift-dedicated).
   - Verify that your GCP project has sufficient regional quotas for Compute Engine vCPUs, Persistent Disk SSD/Standard, In-use IP addresses, Forwarding Rules, and Firewall Rules.
2. **Google Cloud Project & Permissions**:
   - An existing GCP project with Billing enabled and Organization Policy Admin (`roles/orgpolicy.policyAdmin`) + Project Owner (`roles/owner`) permissions.
3. **Red Hat Account & OCM Access**:
   - An active Red Hat account with access to [OpenShift Cluster Manager (OCM)](https://console.redhat.com/openshift).
   - **Note**: If you or your organization don't have an active subscription, you can open a Red Hat account for free and use the **60-day trial licenses (`osdtrial`)** for the deployment.
4. **Authenticate `gcloud` CLI & Application Default Credentials**:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

---

## Step 0: Configure Prerequisites & Environment (`00-prereq-config.sh`)

From your local workstation, navigate to the repository root and run the interactive configuration script:

```bash
cd osd-gcp-demo
./scripts/00-prereq-config.sh
```

You will be prompted to confirm that you have checked [**https://console.cloud.google.com/redhat-openshift/**](https://console.cloud.google.com/redhat-openshift/) and then enter:
- **Existing GCP Project ID** (e.g., `my-gcp-project-id`)
- **GCP Region** (e.g., `asia-southeast1`, `us-central1`) and **Zone** (e.g., `asia-southeast1-a`)
- **Naming Prefix** (`3–15` chars, e.g., `erd-osd01`) — applied to all GCP resources and used as the OCM `--domain-prefix`
- **New Custom VPC IP Range (`/20`)** (default `10.90.32.0/20`) — automatically splits into:
  - Control Plane Subnet (`/23`): `10.90.32.0/23`
  - Worker Subnet (`/23`): `10.90.34.0/23`
  - Bastion Subnet (`/24`): `10.90.36.0/24`
  - Private Service Connect (PSC) Subnet (`/29`): `10.90.37.0/29`
- **GCP Authentication Method**: **Workload Identity Federation (WIF)** *(100% keyless — no Service Account JSON keys)*
- **OSD Subscription / License Model**:
  - `1) OSD Free Trial License (osdtrial)` *(Default — 60-day free trial)*
  - `2) Google Cloud Marketplace (marketplace-gcp)`
  - `3) Standard Red Hat CCS (standard)`
- **Multi-AZ High Availability (`--multi-az`)**: Enabled automatically (distributes nodes across 3 zones; requires worker node count in multiples of 3, default `3`)
- **Worker Machine Type** (default `n4-standard-4`; also supports OCM-catalog shapes like `n2-standard-4`, `n2-standard-8`, `custom-4-16384`, `custom-8-32768`) and **Worker Node Count** (default `3`)
- **HTPasswd Cluster Admin Username & Password** (default username `erdadmin`; auto-generates a strong password if left blank)

**Output**: Generates `config.env` (`chmod 600`).

---

## Step 1: Check & Configure Organization Policies (`01-policy-check.sh`)

Run the policy check script to enable all required GCP APIs (including `sts.googleapis.com` for WIF) and render/apply the YAML Organization Policies from `templates/policies/` (`compute.trustedImageProjects` and `iam.allowedPolicyMemberDomains`):

```bash
./scripts/01-policy-check.sh
```

> [!TIP]
> Wait approximately 30–60 seconds after this step completes to ensure Organization Policy overrides (`iam.allowedPolicyMemberDomains` and `compute.trustedImageProjects`) have propagated across IAM before running Step 3.

---

## Step 2: Deploy New Custom VPC, 4 Subnets & Cloud NAT (`02-vpc-setup.sh`)

Deploy the new custom VPC (`${PREFIX}-vpc`), the four subnets (`control-plane`, `worker`, `bastion`, and `psc` with `--purpose=PRIVATE_SERVICE_CONNECT`), the Cloud Router + Cloud NAT gateway for outbound internet connectivity, and the IAP/internal/health-check firewall rules:

```bash
./scripts/02-vpc-setup.sh
```

---

## Step 3: Configure SSH Key, Keyless GCP Service Account & OSD WIF (`03-iam-and-keys.sh`)

Generate the Ed25519 SSH key pair (`generated/${PREFIX}-ssh`), create the keyless GCP Service Account (`${PREFIX}-gcp-sa`), verify `ocm` login, and provision the **Workload Identity Federation config (`ocm gcp create wif-config --name ${PREFIX}-wif --project ${PROJECT_ID}`)**:

```bash
./scripts/03-iam-and-keys.sh
```

---

## Step 4: Render YAML Templates, Provision Bastion VM & Copy Files (`04-bastion-setup.sh`)

Render the declarative `generated/cluster-config.yaml` and `generated/cluster-admin-rbac.yaml` manifests from `templates/`, deploy the private Debian 13 Bastion VM (`${PREFIX}-vm-bastion`), and copy all setup files (including your active `~/.config/ocm/ocm.json` token) to `~/osd-setup/` on the Bastion:

```bash
./scripts/04-bastion-setup.sh
```

---

## Step 5: SSH to Bastion & Install OpenShift Dedicated (`05-bastion-install-osd.sh` — Runs on Bastion VM)

> [!IMPORTANT]
> **Execution Location: BASTION VM ONLY**
> `05-bastion-install-osd.sh` runs **inside the Bastion VM** (`~/osd-setup/05-bastion-install-osd.sh`) so that once the private OSD cluster is ready, it can immediately reach the private API (`:6443`) and OAuth server to configure your `htpasswd` login and `~/.kube/config`.

### 5.1 SSH into the Bastion VM via IAP Tunnel (From Local Workstation)
Run the `gcloud compute ssh` command printed at the end of Step 4 (or `./scripts/06-access-and-test.sh ssh`):

```bash
source config.env
gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap
```

### 5.2 Start the OSD Cluster Installation (Inside the Bastion VM)
Once logged into the **Bastion VM**, run:

```bash
~/osd-setup/05-bastion-install-osd.sh
```

What `05-bastion-install-osd.sh` does on the Bastion:
1. Installs `wget`, `tar`, `jq`, `htpasswd` (`apache2-utils`), and `dnsutils`.
2. Downloads `ocm`, `oc`, and `kubectl` CLI binaries into `~/bin/`.
3. Displays the declarative `~/osd-setup/cluster-config.yaml` and prompts for confirmation.
4. Executes `ocm create cluster "${CLUSTER_NAME}" --provider=gcp --ccs --private ...` targeting your new Custom VPC (`${VPC_NAME}`) and subnets (`${SUBNET_CONTROL_PLANE}`, `${SUBNET_WORKER}`, `${SUBNET_PSC}`).
5. Polls `ocm describe cluster "${CLUSTER_NAME}"` every 60 seconds until the cluster state reaches `ready` (~35–45 minutes).
6. Creates the **`htpasswd` Identity Provider** on the cluster for `${OSD_ADMIN_USER}`, grants `dedicated-admins` and `cluster-admins`, waits for OAuth rollout, logs in via `oc login`, applies `~/osd-setup/cluster-admin-rbac.yaml`, and saves `~/.kube/config`.

### 5.3 Useful Bastion Subcommands (`status`, `setup-idp`, `restart`, `destroy`)
- **Check cluster status in OCM**:
  ```bash
  ~/osd-setup/05-bastion-install-osd.sh status
  ```
- **Resume waiting & re-run HTPasswd IDP + `oc login` setup**:
  ```bash
  ~/osd-setup/05-bastion-install-osd.sh setup-idp
  ```
- **Destroy failed cluster & restart clean installation**:
  ```bash
  ~/osd-setup/05-bastion-install-osd.sh restart
  ```
- **Delete / destroy the OSD cluster only**:
  ```bash
  ~/osd-setup/05-bastion-install-osd.sh destroy
  ```

---

## Step 6: Test Cluster Connections (`06-access-and-test.sh` — Runs on Local Workstation)

> [!IMPORTANT]
> **Execution Location: LOCAL WORKSTATION ONLY**
> Exit your Bastion SSH session (or open a new terminal tab on your local workstation) before running `./scripts/06-access-and-test.sh`.

After the installation finishes, run the automated connection and health check from your **Local Workstation**:

```bash
./scripts/06-access-and-test.sh test
```

This automatically queries OCM to discover your cluster's assigned domain (`<PREFIX>.<id>.p2.openshiftapps.com`), saves `OSD_API_HOST`, `OSD_CONSOLE_HOST`, and `OSD_OAUTH_HOST` into `config.env`, and verifies Private DNS resolution, API health (`:6443/healthz`), Web Console ingress (`:443`), cluster version, and node readiness via the Bastion VM.

---

## Step 7: HTTPS Tunnel to Local Machine for Web Console Access (`06-access-and-test.sh` — Runs on Local Workstation)

### 7.1 Add Console & OAuth Hostnames (`127.0.0.2`) to Local `/etc/hosts`
On your **local machine**, run:

```bash
./scripts/06-access-and-test.sh hosts
```

### 7.2 Start the HTTPS/HTTP Port-Forwarding Tunnel (`127.0.0.2:443` & `:80`)
On your **local machine**, run:

```bash
./scripts/06-access-and-test.sh tunnel
```

### 7.3 Open the Web Console in Your Browser
1. Open the `https://console-openshift-console.apps.<PREFIX>.<id>.p2.openshiftapps.com` URL printed by the script in your local browser.
2. Select **`htpasswd`** as the login provider and log in with `${OSD_ADMIN_USER}` and the admin password you set (or auto-generated in memory) during `05-bastion-install-osd.sh`.

> [!TIP]
> **Running on Windows WSL (WSL 2) or Google Cloud Shell?**
> - **WSL 2**: `00-prereq-config.sh` automatically detects WSL and sets `CONSOLE_LOCAL_IP="127.0.0.1"` in `config.env`. Run the **Administrator PowerShell** command printed by `./scripts/06-access-and-test.sh hosts` to append the OSD Console and OAuth hostnames to `C:\Windows\System32\drivers\etc\hosts`.
> - **Google Cloud Shell**: `06-access-and-test.sh tunnel` automatically detects Cloud Shell (`CLOUD_SHELL=true`) and binds unprivileged ports (`127.0.0.1:8443` and `:8080`) without needing `sudo`.

---

## Part 2: Live Customer Demo Guide (Phases 2 & 3 Enterprise Workloads)

Once your Phase 1 private OpenShift Dedicated cluster is healthy, sync the `workloads/` directory from your local workstation to the Bastion VM:

```bash
# Run on Local Workstation
./workloads/sync-to-bastion.sh
```

Then SSH into the Bastion VM (`./scripts/06-access-and-test.sh ssh`) where `~/.kube/config` is pre-configured with a non-expiring `bastion-admin` token.

---

### Demo Scenario 1 (Option 1): Stateless Multi-Zone Web Tier with Regional Enterprise Cloud Filestore (`ReadWriteMany`)

**Customer Value Story**: Show how a stateless retail storefront (`Cymbal Storefront`) scales horizontally across 3 Google Cloud availability zones (`-a`, `-b`, `-c`) while sharing a single high-availability **Regional Cloud Filestore (`Enterprise` tier)** NFSv3 volume (`ReadWriteMany`) over **Private Service Access (PSA)**—with 100% keyless Workload Identity Federation.

#### 1.1 Deploy Option 1
```bash
# 1. Configure Private Service Access (/20 peering range) & Keyless WIF for Filestore (Local or Bastion)
./workloads/option1-filestore-stateless/scripts/01-prereq-filestore-psa.sh

# 2. Install GCP Filestore CSI Driver Operator & Regional StorageClass (Inside Bastion VM)
cd ~/osd-setup/workloads/option1-filestore-stateless
./scripts/02-deploy-filestore-csi.sh

# 3. Deploy 3-Replica Cymbal Storefront & 100Gi ReadWriteMany PVC (2000 IOPS, NFSv4.1) (Inside Bastion VM)
./scripts/03-deploy-cymbal-stateless.sh
```

#### 1.2 What to Show in the Live Demo
1. **Verify Multi-Zone `RWX` Volume Binding**:
   ```bash
   oc get pvc,pods -n cymbal-storefront -o wide
   ```
   Point out that all 3 pods running in 3 different availability zones (`-a`, `-b`, `-c`) simultaneously mount the same `cymbal-shared-assets-pvc` (`ReadWriteMany`) backed by `filestore-regional-csi`.
2. **Open the Live Cymbal Storefront UI**:
   - On your local workstation, add the storefront route to `/etc/hosts` (`./scripts/06-access-and-test.sh hosts`) while `./scripts/06-access-and-test.sh tunnel` is running.
   - Open `https://cymbal-storefront-cymbal-storefront.apps.<PREFIX>.<id>.p2.openshiftapps.com` in your browser.
   - Refresh the page multiple times: show the **Live Shared Filestore Access Log** table where different pods across zones `-a`, `-b`, and `-c` append and read shared telemetry from `/mnt/cymbal-filestore` in real time.

---

### Demo Scenario 2 (Option 2): Stateful Ledger on Google Cloud Hyperdisk (`N4`) + Secret Manager CSI Driver

**Customer Value Story**: Show how mission-critical databases (`PostgreSQL 16 StatefulSet`) run on **Google Cloud `N4` (`n4-standard-4`)** worker nodes with **Hyperdisk Balanced** block storage (decoupling IOPS/throughput from disk size to lower TCO) while fetching database credentials directly in-memory (`tmpfs`) from **Google Cloud Secret Manager** via the **Secrets Store CSI Driver**—with zero plaintext secrets in Git.

#### 2.1 Deploy Option 2
```bash
# 1. Create Secrets in Google Cloud Secret Manager & Grant Keyless WIF Role (Local or Bastion)
./workloads/option2-hyperdisk-stateful/scripts/01-prereq-secretmanager.sh

# 2. Install Secrets Store CSI Driver + GCP Provider & Hyperdisk StorageClass (Inside Bastion VM)
cd ~/osd-setup/workloads/option2-hyperdisk-stateful
./scripts/02-deploy-secrets-csi.sh

# 3. Deploy Cymbal PostgreSQL StatefulSet (Hyperdisk) + Web Ledger UI (Inside Bastion VM)
./scripts/03-deploy-cymbal-stateful.sh
```

#### 2.2 Optional Compute Demo: Upgrade Worker Pool to `N4` & Enable Autoscaling (`3–6` Nodes)
```bash
cd ~/osd-setup/workloads/option2-hyperdisk-stateful
./scripts/04-upgrade-workers-to-n4.sh
./scripts/05-enable-worker-autoscaler.sh
```

#### 2.3 What to Show in the Live Demo
1. **Verify Hyperdisk Volume & Secret Manager CSI Mount**:
   ```bash
   oc get pvc,pods -n cymbal-stateful -o wide
   oc exec -n cymbal-stateful cymbal-ledger-db-0 -- ls -la /mnt/secrets-store
   ```
2. **Open the Live Cymbal Order & Inventory Ledger UI**:
   - Refresh `/etc/hosts` (`./scripts/06-access-and-test.sh hosts`) on your local workstation and open `https://cymbal-ledger-cymbal-stateful.apps.<PREFIX>.<id>.p2.openshiftapps.com`.
   - Show the live PostgreSQL inventory records, the **Hyperdisk Balanced (`hyperdisk-balanced-csi`)** storage badge, and the **Secret Manager CSI (`secrets-store.csi.k8s.io`)** verification card.
3. **Live Stateful Failover Test**:
   ```bash
   oc delete pod cymbal-ledger-db-0 -n cymbal-stateful
   oc get pods -n cymbal-stateful -w
   ```
   Show that Kubernetes recreates `cymbal-ledger-db-0`, re-attaches the same 20 GiB `hyperdisk-balanced` volume in seconds, and preserves all ledger transactions.

---

### Demo Scenario 3 (Option 3 / Phase 3): Public Workload Exposure with Google Cloud Armor WAF, L7 DDoS, Cloud CDN & Global External ALB

**Customer Value Story**: Show how to expose a public-facing application (`Cymbal Global Public Storefront`) to the internet with **Google Cloud's full defense-in-depth edge stack** (**Global External Application Load Balancer**, **Cloud Armor OWASP Top 10 WAF + L7 Rate-Based Ban**, **Cloud CDN**, **Zonal `GCE_VM_IP_PORT` NEGs**, and **Least-Privilege GFE Firewall Rules**) while keeping the OpenShift cluster's API (`:6443`), Web Console (`:443`), and Worker VMs **100% private** (zero public IP addresses on cluster nodes).

#### 3.1 Deploy Option 3 (Inside Bastion VM)
```bash
cd ~/osd-setup/workloads/option3-public-waf-ddos

# 1. Deploy 3-Zone Cymbal Public Storefront, Zero-Trust NetworkPolicy & NodePort (:30080)
./scripts/01-deploy-public-workload.sh

# 2. Deploy Cloud Armor WAF/DDoS Policy, Zonal NEGs, Cloud CDN, Global External ALB & Uptime Check
./scripts/02-deploy-cloud-armor-and-alb.sh
```

#### 3.2 Run the Live WAF, CDN & DDoS Attack Simulation (`03-test-waf-and-ddos.sh`)
*(Wait ~2–4 minutes after Step 3.1 for Global External ALB edge certificate & route propagation).*

```bash
cd ~/osd-setup/workloads/option3-public-waf-ddos
./scripts/03-test-waf-and-ddos.sh
```

What the audience sees live in the terminal and browser:
1. **Direct Public Browser Access (No IAP Tunnel Needed!)**:
   - Open `https://cymbal.<PUBLIC_VIP>.nip.io` printed by the script from any browser.
   - Show the live **Edge Security Posture Dashboard** displaying the serving OpenShift pod, node, availability zone (`-a`, `-b`, `-c`), and active security controls.
2. **Edge Security Headers & Cloud CDN Acceleration (`MISS` $\rightarrow$ `HIT`)**:
   - Point out `strict-transport-security: max-age=31536000; includeSubDomains`, `x-content-type-options: nosniff`, `x-frame-options: DENY`, and `x-cdn-cache-status: HIT` on `/static/catalog.json`.
3. **Live OWASP Top 10 WAF Attack Blocks (`403 Forbidden` at Google Edge)**:
   - Either in the CLI output of `03-test-waf-and-ddos.sh` or by clicking the **Interactive Attack Simulation Buttons** in the browser UI:
     - **SQL Injection (`?search=1' OR '1'='1`)** $\rightarrow$ Blocked by Cloud Armor rule `sqli-v422-stable` (`Priority 1000`, `HTTP 403 Forbidden`).
     - **Cross-Site Scripting (`?q=<script>alert(1)</script>`)** $\rightarrow$ Blocked by Cloud Armor rule `xss-v422-stable` (`Priority 1001`, `HTTP 403 Forbidden`).
     - **Local File Inclusion (`?file=../../../../etc/passwd`)** $\rightarrow$ Blocked by Cloud Armor rule `lfi-v422-stable` (`Priority 1002`, `HTTP 403 Forbidden`).
     - **Remote Code Execution (`?cmd=;cat /etc/shadow`)** $\rightarrow$ Blocked by Cloud Armor rule `rce-v422-stable` (`Priority 1003`, `HTTP 403 Forbidden`).
4. **Live L7 DDoS Rate-Based Ban (`429 Too Many Requests`)**:
   ```bash
   ./scripts/03-test-waf-and-ddos.sh --test-ddos
   ```
   Fires a burst of `>100 requests/min` and demonstrates Cloud Armor Rule **Priority 2000** automatically throttling the client IP with `HTTP 429 Too Many Requests` for `120 seconds`.
5. **Real-Time Cloud Logging WAF Audit Trail**:
   - Show the structured `enforcedSecurityPolicy` entries streamed to Google Cloud Logging (`outcome: DENY`, `status: 403`, `matchedFieldType`).

---

## Part 3: Day-2 Operations, Cost Governance & Full Cleanup

### Step 8: Stop & Start Cluster VMs to Save Compute Costs (`08-stop-start-vms.sh`)

When your demo environment is idle, you can gracefully stop and restart all OpenShift Dedicated cluster VMs (Workers, Infrastructure nodes, and Control Plane Masters) and the Bastion VM:

```bash
# Check current VM power states
./scripts/08-stop-start-vms.sh status

# Stop all Cluster VMs (Workers -> Infra -> Masters) and Bastion VM
./scripts/08-stop-start-vms.sh stop

# Stop Cluster VMs only, keeping Bastion VM running
./scripts/08-stop-start-vms.sh stop --keep-bastion

# Start Bastion -> Masters -> Infra -> Workers and auto-approve node CSRs
./scripts/08-stop-start-vms.sh start
```

---

### Day-2 Operation: Upgrading the OpenShift Dedicated Cluster (Patch & Minor Versions)

Unlike Self-Managed OCP (where cluster admins run `oc adm upgrade`), **OpenShift Dedicated upgrades are orchestrated by Red Hat SRE via OpenShift Cluster Manager (OCM)**—either through the **Red Hat Hybrid Cloud Console (OCM Web UI)** or the **`ocm` CLI**.

| Upgrade Type | Example | Requires `ocm gcp update wif-config`? | How It Runs |
| :--- | :--- | :--- | :--- |
| **Patch / Z-Stream** | `4.22.18` $\rightarrow$ `4.22.19` | **No** | Scheduled manually (**Individual updates**) or automated weekly (**Recurring updates**). |
| **Minor / Y-Stream** | `4.22.x` $\rightarrow$ `4.23.x` | **Yes** *(1 command before scheduling)* | Scheduled in OCM UI or via `ocm upgrade cluster` after updating the WIF config. |

#### 1. Check Current Version & Available Upgrade Paths
```bash
source config.env
ocm describe cluster "${CLUSTER_NAME}"

# List available target versions for your cluster:
CLUSTER_ID="$(ocm describe cluster "${CLUSTER_NAME}" --json | jq -r '.id')"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r '.version.available_upgrades[]?'
```

#### 2. Update WIF Configuration *(Required ONLY Before Minor Version Upgrades, e.g. `4.22` $\rightarrow$ `4.23`)*
Before upgrading to a new **minor** OpenShift release, run this single command so OCM can grant any newly introduced platform operator permissions to its OCM-managed WIF Service Accounts (this never touches your customer-managed `${PREFIX}-gcp-sa` used by Phase 2 Filestore CSI & Secret Manager CSI):
```bash
WIF_ID="$(ocm gcp list wif-configs | awk -v name="${WIF_CONFIG_NAME}" '$2 == name {print $1}')"
ocm gcp update wif-config "${WIF_ID}"
```

#### 3. Trigger or Schedule the Upgrade

##### Option A: Via `ocm` CLI
```bash
# Schedule an immediate upgrade (starts within ~5-10 minutes)
ocm upgrade cluster --cluster="${CLUSTER_NAME}" --version=4.22.19

# Or schedule for a specific UTC date and time (YYYY-MM-DD and HH:MM)
ocm upgrade cluster --cluster="${CLUSTER_NAME}" --version=4.22.19 --date=2026-10-21 --time=02:00

# Check scheduled / running upgrade status
ocm list upgrades --cluster="${CLUSTER_NAME}"
```

##### Option B: Via Red Hat Hybrid Cloud Console (OCM Web UI)
1. Open [console.redhat.com/openshift](https://console.redhat.com/openshift) $\rightarrow$ select **`${CLUSTER_NAME}`**.
2. Go to the **Settings** tab $\rightarrow$ **Update settings**.
3. Choose **Individual updates** (select the target version and click **Update now** or schedule a maintenance window) or **Recurring updates** (automated weekly patch updates).

#### 4. Monitor Live Upgrade Progress Inside the Bastion VM
```bash
oc get clusterversion -w
oc get co
oc get mcp
oc get nodes
```

---

### Step 9: How to Remove the Workloads, Cluster & Infrastructure (`07-cleanup.sh`)

#### 9.1 Clean Up Optional Phase 2 & 3 Workloads First (If Deployed)
If you deployed Option 1, Option 2, or Option 3 workloads, run their cleanup scripts first so external GCP load balancers, Filestore instances, and Hyperdisk volumes are removed cleanly:
```bash
# Option 3 (Public WAF / Global External ALB / NEGs)
~/osd-setup/workloads/option3-public-waf-ddos/scripts/04-cleanup-public-waf.sh

# Option 2 (Hyperdisk StatefulSet & Secret Manager Secrets)
~/osd-setup/workloads/option2-hyperdisk-stateful/scripts/04-cleanup-option2.sh

# Option 1 (Regional Filestore Instance & Private Service Access)
~/osd-setup/workloads/option1-filestore-stateless/scripts/04-cleanup-option1.sh
```

#### 9.2 Automated Full Cluster & VPC Teardown (`07-cleanup.sh`)
Always remove the OpenShift Dedicated cluster **first** via `ocm delete cluster` (and wait for OCM to finish deleting all cluster VMs, load balancers, and Cloud DNS private zones) before deleting the WIF configuration or VPC.

From your **local workstation**, run:

```bash
./scripts/07-cleanup.sh
```

This script automatically:
1. Deletes the OSD cluster via `ocm delete cluster` and waits until OCM finishes deprovisioning all GCP resources.
2. Deletes the WIF configuration (`ocm gcp delete wif-config`).
3. Deletes the Bastion VM (`${BASTION_NAME}`).
4. Deletes Firewall rules (`${FW_IAP_SSH}`, `${FW_INTERNAL}`, `${FW_HEALTH_CHECKS}`).
5. Deletes Cloud NAT (`${NAT_NAME}`) and Cloud Router (`${ROUTER_NAME}`).
6. Deletes the 4 Subnets (`${SUBNET_BASTION}`, `${SUBNET_PSC}`, `${SUBNET_WORKER}`, `${SUBNET_CONTROL_PLANE}`) and the new Custom VPC (`${VPC_NAME}`).
7. Deletes the GCP Service Account (`${SA_EMAIL}`) and cleans up local `/etc/hosts` entries and `generated/`.

---

## Official References

- [Architecture Documentation (`docs/architecture.md`)](architecture.md)
- [Architecture & Security Review (`docs/architecture-review.md`)](architecture-review.md)
- [Phase 2 & 3 Workload Architecture (`workloads/docs/architecture-phase2.md`)](../workloads/docs/architecture-phase2.md)
- [Google Cloud Console: Red Hat OpenShift Requirements & Portal](https://console.cloud.google.com/redhat-openshift/)
- [Red Hat OpenShift Dedicated: Planning Your Environment on GCP](https://docs.redhat.com/en/documentation/red_hat_openshift_dedicated/4/html/planning_your_environment/gcp-ccs-prerequisites_osd-planning-environment)
- [Red Hat OpenShift Cluster Manager (OCM)](https://console.redhat.com/openshift)
