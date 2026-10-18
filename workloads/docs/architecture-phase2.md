# Phase 2 Architecture: Cymbal Workloads on OpenShift Dedicated & Google Cloud

This document describes the architecture for the two independent Phase 2 workload options running on the private Red Hat OpenShift Dedicated (OSD) cluster in your custom VPC on Google Cloud.

---

## Option 1 Architecture: Stateless Cymbal Storefront with Regional Private Cloud Filestore

Option 1 demonstrates how a **stateless, multi-replica web tier** (`Cymbal Retail Storefront`) scales horizontally across multiple availability zones while reading and writing shared assets and real-time access logs on a **regional, private Google Cloud Filestore (`Enterprise` tier)** volume provisioned dynamically via the **GCP Filestore CSI Driver Operator**.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1e293b', 'lineColor': '#475569'}}}%%
flowchart TB
    subgraph Local["Local Workstation"]
        Browser["Browser\nhttps://cymbal-storefront-cymbal-storefront.apps.<OSD_BASE_DOMAIN>"]:::client
    end

    subgraph VPC["Custom VPC: <PREFIX>-vpc"]
        Bastion["Bastion VM (<PREFIX>-vm-bastion)\nIAP SSH Tunnel (127.0.0.2:443)"]:::bastion

        subgraph OSD["OpenShift Dedicated Cluster (Worker Subnet — n4-standard-4)"]
            Ingress["OpenShift Internal Router (*.apps :443)\nRoute: cymbal-storefront (TLS Edge)"]:::lb
            Svc["Service: cymbal-storefront-svc (:8080)"]:::network

            subgraph NS1["Namespace: cymbal-storefront"]
                Pod1["Cymbal Storefront Pod 1 (Zone a)\nStateless UBI9 Python 3.14"]:::worker
                Pod2["Cymbal Storefront Pod 2 (Zone b)\nStateless UBI9 Python 3.14"]:::worker
                Pod3["Cymbal Storefront Pod 3 (Zone c)\nStateless UBI9 Python 3.14"]:::worker
                PVC1["PVC: cymbal-shared-assets-pvc\nAccessMode: ReadWriteMany (100Gi)"]:::storage
            end

            FilestoreCSI["GCP Filestore CSI Driver Operator\n(filestore.csi.storage.gke.io)\nStorageClass: filestore-regional-csi"]:::iam
        end

        PSA["Private Service Access (PSA)\nVPC Peering (servicenetworking.googleapis.com)\nAllocated /29 Range: <PREFIX>-psa-range"]:::network
    end

    subgraph ManagedNet["Google Managed Services Network"]
        Filestore["Regional Cloud Filestore (tier: regional)\n100Gi | 2000 IOPS | Multi-Zone HA NFSv4.1 Share\nPrivate IP Only"]:::storage
    end

    Browser -->|"127.0.0.2:443"| Bastion
    Bastion --> Ingress
    Ingress --> Svc
    Svc --> Pod1 & Pod2 & Pod3
    Pod1 & Pod2 & Pod3 -->|"ReadWriteMany (/mnt/cymbal-filestore)"| PVC1
    PVC1 -.->|"Dynamic Provisioning"| FilestoreCSI
    FilestoreCSI -.->|"Creates Regional Instance"| Filestore
    Pod1 & Pod2 & Pod3 <-->|"NFSv3 over Private Service Access"| PSA
    PSA <--> Filestore

    classDef client fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef bastion fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef lb fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#581c87
    classDef network fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
    classDef worker fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef storage fill:#ecfccb,stroke:#65a30d,stroke-width:2px,color:#365314
    classDef iam fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f

    style Local fill:#f0f9ff,stroke:#0284c7,stroke-width:1.5px,color:#0c4a6e
    style VPC fill:#f8fafc,stroke:#64748b,stroke-width:2px,color:#0f172a
    style OSD fill:#ffffff,stroke:#22c55e,stroke-width:1.5px,color:#14532d
    style NS1 fill:#f0fdf4,stroke:#4ade80,stroke-width:1.5px,color:#14532d
    style ManagedNet fill:#f7fee7,stroke:#84cc16,stroke-width:1.5px,color:#365314
```

### Key Architectural Components (Option 1)
1. **Private Service Access (PSA) & VPC Peering**:
   - Because the OpenShift Dedicated cluster is strictly private and uses custom subnets, regional Cloud Filestore (`Enterprise` tier) connects to `${PREFIX}-vpc` via **Private Service Access** (`servicenetworking.googleapis.com`) using a dedicated `/20` peering IP range (`${PREFIX}-psa-range`).
2. **GCP Filestore CSI Driver Operator**:
   - Installed in `openshift-cluster-csi-drivers` via Operator Lifecycle Manager (OLM) and managed through `ClusterCSIDriver` (`filestore.csi.storage.gke.io`).
   - On OSD clusters using Workload Identity Federation (where the Cloud Credential Operator runs in `Manual` mode), `01-prereq-filestore-psa.sh` provisions the `gcp-filestore-cloud-credentials` secret in `openshift-cluster-csi-drivers` so the CSI controller authenticates seamlessly.
   - Provides dynamic provisioning of regional `ReadWriteMany` (`RWX`) NFSv4.1 volumes (`100Gi`, `2000 IOPS`) via `StorageClass` `filestore-regional-csi` (`tier: regional`, `protocol: NFS_V4_1`, `max-iops: "2000"`, `connect-mode: PRIVATE_SERVICE_ACCESS`).
3. **Cymbal Retail Storefront (Stateless Multi-Replica Deployment)**:
   - Runs 3 stateless web replicas spread across worker nodes in 3 zones (`--multi-az`).
   - All 3 pods concurrently mount `/mnt/cymbal-filestore` (`ReadWriteMany`), sharing product catalog assets and appending real-time pod/node request telemetry so users can observe multi-pod `RWX` storage sharing in real time.

---

## Option 2 Architecture: Stateful Cymbal Ledger with Hyperdisk Block Storage & Secret Manager

Option 2 demonstrates how a **stateful database and transaction ledger** (`Cymbal Order & Inventory Ledger`) persists transactional data on **Google Cloud Hyperdisk Balanced** block storage (`ReadWriteOnce`) while mounting database credentials and API keys directly from **Google Cloud Secret Manager** using the **Secrets Store CSI Driver Operator**.

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1e293b', 'lineColor': '#475569'}}}%%
flowchart TB
    subgraph Local["Local Workstation"]
        Browser2["Browser\nhttps://cymbal-ledger-cymbal-stateful.apps.<OSD_BASE_DOMAIN>"]:::client
    end

    subgraph GCP_Sec["Google Cloud Security & Block Storage"]
        GSM["Google Cloud Secret Manager\n- <PREFIX>-cymbal-db-password\n- <PREFIX>-cymbal-api-key"]:::secret
        Hyperdisk["Google Cloud Hyperdisk Balanced\n20Gi Block Volume (ReadWriteOnce)\nProvisioned via pd.csi.storage.gke.io"]:::storage
    end

    subgraph VPC["Custom VPC: <PREFIX>-vpc"]
        Bastion2["Bastion VM (<PREFIX>-vm-bastion)\nIAP SSH Tunnel (127.0.0.2:443)"]:::bastion

        subgraph OSD2["OpenShift Dedicated Cluster (Worker Subnet — n4-standard-4)"]
            Ingress2["OpenShift Internal Router (*.apps :443)\nRoute: cymbal-ledger (TLS Edge)"]:::lb

            subgraph NS2["Namespace: cymbal-stateful"]
                UI["Cymbal Ledger Web UI Pod\nQueries PostgreSQL & Displays Live Ledger"]:::worker
                DB["StatefulSet: cymbal-ledger-db-0\nPostgreSQL 16"]:::master
                SPC["SecretProviderClass: cymbal-gcp-secrets\nMounts /mnt/secrets-store + Syncs K8s Secret"]:::secret
                RWO_PVC["VolumeClaimTemplate PVC\ncymbal-hyperdisk-data (20Gi)\nStorageClass: hyperdisk-balanced-csi"]:::storage
            end

            SecretsCSI["Secrets Store CSI Driver Operator\n(secrets-store.csi.k8s.io)\n+ GCP Provider DaemonSet"]:::iam
            PD_CSI["GCP PD CSI Driver\n(pd.csi.storage.gke.io)"]:::iam
        end
    end

    Browser2 -->|"127.0.0.2:443"| Bastion2
    Bastion2 --> Ingress2
    Ingress2 --> UI
    UI -->|"SQL (:5432)"| DB
    DB -->|"Block I/O (/var/lib/pgsql/data)"| RWO_PVC
    RWO_PVC --> PD_CSI
    PD_CSI --> Hyperdisk
    DB & UI -->|"CSI Inline Volume (/mnt/secrets-store)"| SPC
    SPC --> SecretsCSI
    SecretsCSI -->|"Fetches Secrets via IAM"| GSM

    classDef client fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef bastion fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef lb fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#581c87
    classDef worker fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef master fill:#ffedd5,stroke:#ea580c,stroke-width:2px,color:#7c2d12
    classDef secret fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#831843
    classDef storage fill:#ecfccb,stroke:#65a30d,stroke-width:2px,color:#365314
    classDef iam fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f

    style Local fill:#f0f9ff,stroke:#0284c7,stroke-width:1.5px,color:#0c4a6e
    style GCP_Sec fill:#fdf2f8,stroke:#ec4899,stroke-width:1.5px,color:#831843
    style VPC fill:#f8fafc,stroke:#64748b,stroke-width:2px,color:#0f172a
    style OSD2 fill:#ffffff,stroke:#22c55e,stroke-width:1.5px,color:#14532d
    style NS2 fill:#f0fdf4,stroke:#4ade80,stroke-width:1.5px,color:#14532d
```

### Key Architectural Components (Option 2)
1. **Google Cloud Hyperdisk Balanced (`hyperdisk-balanced-csi`)**:
   - Uses the built-in OpenShift `pd.csi.storage.gke.io` CSI driver with `type: hyperdisk-balanced` and `volumeBindingMode: WaitForFirstConsumer`, matching the `n4-standard-4` worker nodes' next-generation Hyperdisk storage architecture.
2. **Secrets Store CSI Driver Operator + GCP Provider**:
   - Installs the OpenShift **Secrets Store CSI Driver Operator** (`secrets-store.csi.k8s.io`) and the **Google Cloud Provider DaemonSet** (`csi-secrets-store-provider-gcp`) in `openshift-cluster-csi-drivers`.
   - Uses a `SecretProviderClass` (`cymbal-gcp-secrets`) to fetch secrets directly from **Google Cloud Secret Manager** (`${PREFIX}-cymbal-db-password` and `${PREFIX}-cymbal-api-key`), mounting them as in-memory tmpfs files at `/mnt/secrets-store` and syncing them to an OpenShift `Secret` for database initialization.
3. **Cymbal Order & Inventory Ledger (`StatefulSet` + Web Dashboard)**:
   - **`cymbal-ledger-db` (`StatefulSet`)**: Runs PostgreSQL 16 backed by a dedicated 20 GiB `hyperdisk-balanced` persistent volume (`cymbal-hyperdisk-data-cymbal-ledger-db-0`).
   - **`cymbal-ledger-ui`**: Seeds and queries Cymbal retail inventory and order ledger records stored in PostgreSQL on Hyperdisk, displaying live database records, Hyperdisk volume metadata, and Secret Manager CSI mount verification.

---

## Option 3 (Phase 3) Architecture: Public Edge Storefront with Cloud Armor WAF, DDoS, Cloud CDN & Global External ALB

Option 3 demonstrates how to expose a **public-facing enterprise workload** (`Cymbal Global Public Storefront`) from a **100% Private OpenShift Dedicated (`--private`)** cluster using Google Cloud's defense-in-depth edge security and observability stack—while keeping the OpenShift API (`:6443`), Web Console, OAuth server, and worker nodes completely private (zero public IP addresses on cluster nodes):

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'background': '#ffffff', 'primaryTextColor': '#1e293b', 'lineColor': '#475569'}}}%%
flowchart TB
    subgraph Internet["Public Internet & Global Probers"]
        Users["Legitimate Public Users\nhttps://cymbal.<PUBLIC_VIP>.nip.io"]:::client
        Attackers["Malicious Traffic\n(SQLi, XSS, LFI, RCE, Scanners, L7 DDoS)"]:::redhat
        Uptime["Cloud Monitoring Global Uptime Check\nProbes /healthz from US, EU & APAC"]:::dns
    end

    subgraph GoogleEdge["Google Cloud Global Edge (180+ Anycast POPs)"]
        VIP["Global Static Anycast IPv4 (<PREFIX>-public-waf-vip)\nAlways-On Google L3/L4 Volumetric DDoS Protection"]:::lb
        HTTPS_Proxy["Global External Application Load Balancer (EXTERNAL_MANAGED)\n• Target HTTPS Proxy (:443) + SSL Policy (TLS 1.2/1.3 MODERN)\n• Custom Security Headers (HSTS, X-Frame-Options, X-CDN-Cache-Status)"]:::lb
        CloudArmor["Google Cloud Armor WAF & DDoS Policy (<PREFIX>-cloud-armor-waf)\n• Priority 1000–1008: OWASP CRS 4.22 (SQLi, XSS, LFI, RCE, RFI, Generic -> 403)\n• Priority 2000: Rate-Based Ban / L7 DDoS (100 req/min/IP -> 429)"]:::iam
        CloudCDN["Google Cloud CDN (Global Edge Cache)\nCaches /static/* & Catalog Assets at Edge POPs (HIT / MISS)"]:::storage
        BackendSvc["Global Backend Service (<PREFIX>-public-backend-svc)\n+ HTTP Health Check (/healthz)"]:::lb
    end

    subgraph CloudOps["Google Cloud Operations (Observability & Audit)"]
        CloudLog["Cloud Logging\n• 100% ALB & Cloud Armor WAF Audit Logs\n• Firewall Rule & VPC Flow Logs"]:::secret
    end

    subgraph VPC["Private Custom VPC: <PREFIX>-vpc (Zero Public IPs on Nodes)"]
        FW_GFE["Least-Privilege GFE Firewall Rule (<PREFIX>-allow-gfe-public-neg)\n• Source ONLY GFEs: 130.211.0.0/22, 35.191.0.0/16\n• Target Tag: <infra-id>-worker | Port ONLY: tcp:30080\n• Firewall Rule Logging: ENABLED"]:::network

        subgraph SubWorker["Worker Subnet: <PREFIX>-subnet-worker (/23 — VPC Flow Logs ENABLED)"]
            NEG_A["Zonal NEG (Zone a)\nGCE_VM_IP_PORT :30080"]:::infra
            NEG_B["Zonal NEG (Zone b)\nGCE_VM_IP_PORT :30080"]:::infra
            NEG_C["Zonal NEG (Zone c)\nGCE_VM_IP_PORT :30080"]:::infra

            subgraph PublicNS["OpenShift Namespace: cymbal-public"]
                NP_Svc["NodePort Service (:30080 -> :8080)\ncymbal-public-neg-svc"]:::network
                PodA["Cymbal Public Edge Pod 1 (Zone a)\nNon-Root SCC (restricted-v2)"]:::worker
                PodB["Cymbal Public Edge Pod 2 (Zone b)\nNon-Root SCC (restricted-v2)"]:::worker
                PodC["Cymbal Public Edge Pod 3 (Zone c)\nNon-Root SCC (restricted-v2)"]:::worker
                NetPol["Kubernetes NetworkPolicy\nIsolates Namespace Traffic"]:::iam
            end
        end

        subgraph PrivateControl["Strictly Private Control Plane & Console (100% Isolated)"]
            PrivAPI["Private API (:6443) & Console (:443)\nUnreachable from Public ALB"]:::bastion
        end
    end

    Users -->|"HTTPS :443"| VIP
    Uptime -.->|"Synthetic HTTPS Probe"| VIP
    Attackers -.-x|"Blocked at Edge (403 / 429)"| CloudArmor
    VIP --> HTTPS_Proxy
    HTTPS_Proxy --> CloudArmor
    CloudArmor -->|"Allowed Traffic"| CloudCDN
    CloudCDN -->|"Cache Miss / Dynamic"| BackendSvc
    BackendSvc -->|"Google Internal SDN"| FW_GFE
    FW_GFE --> NEG_A & NEG_B & NEG_C
    NEG_A & NEG_B & NEG_C --> NP_Svc
    NP_Svc --> PodA & PodB & PodC
    CloudArmor & BackendSvc & FW_GFE -.->|"Real-Time Telemetry"| CloudLog

    classDef client fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    classDef redhat fill:#ffe4e6,stroke:#e11d48,stroke-width:2px,color:#881337
    classDef dns fill:#ccfbf1,stroke:#0d9488,stroke-width:2px,color:#134e4a
    classDef iam fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef storage fill:#ecfccb,stroke:#65a30d,stroke-width:2px,color:#365314
    classDef secret fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#831843
    classDef network fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#312e81
    classDef lb fill:#f3e8ff,stroke:#9333ea,stroke-width:2px,color:#581c87
    classDef bastion fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef infra fill:#cffafe,stroke:#0891b2,stroke-width:2px,color:#164e63
    classDef worker fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#14532d

    style Internet fill:#f8fafc,stroke:#94a3b8,stroke-width:1.5px,color:#0f172a
    style GoogleEdge fill:#faf5ff,stroke:#9333ea,stroke-width:2px,color:#581c87
    style CloudOps fill:#fdf2f8,stroke:#ec4899,stroke-width:1.5px,color:#831843
    style VPC fill:#ffffff,stroke:#475569,stroke-width:2px,stroke-dasharray: 5 5,color:#0f172a
    style SubWorker fill:#f0fdf4,stroke:#22c55e,stroke-width:1.5px,color:#14532d
    style PublicNS fill:#dcfce7,stroke:#4ade80,stroke-width:1.5px,color:#14532d
    style PrivateControl fill:#eff6ff,stroke:#3b82f6,stroke-width:1.5px,color:#1e3a8a
```

### Key Architectural Components (Option 3)
1. **Google Cloud Armor WAF & L7 DDoS (`${PREFIX}-cloud-armor-waf`)**:
   - Blocks OWASP Top 10 attacks (`sqli-v422-stable`, `xss-v422-stable`, `lfi-v422-stable`, `rce-v422-stable`, `scannerdetection-v422-stable`, `protocolattack-v422-stable`, `rfi-v422-stable`, `sessionfixation-v422-stable`, `generic-v422-stable`) at Google's Global Edge (`403 Forbidden`) and enforces per-IP L7 rate limiting (`100 req/min` $\rightarrow$ `429 Too Many Requests` ban for `120s`).
2. **Global External Application Load Balancer (`EXTERNAL_MANAGED`) + Cloud CDN + SSL Policy**:
   - Terminates HTTPS (`:443`) using a `MODERN` TLS 1.2+ SSL Policy, caches `/static/catalog.json` at 180+ Google Edge POPs via **Cloud CDN**, and injects security response headers (`Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`).
3. **Zonal `GCE_VM_IP_PORT` NEGs + Least-Privilege GFE Firewall Rule**:
   - Routes clean traffic over Google's internal SDN directly to private worker VMs across Zones `-a`, `-b`, `-c` on NodePort `:30080`, restricted by `${PREFIX}-allow-gfe-public-neg` (`130.211.0.0/22`, `35.191.0.0/16` only) with Firewall Rule Logging and sampled VPC Flow Logs enabled.
4. **Cloud Logging & Cloud Monitoring Global Uptime Check**:
   - Streams 100% of ALB and Cloud Armor security events into Cloud Logging and continuously probes `/healthz` from USA, Europe, and Asia-Pacific via Cloud Monitoring.

---

## Day-2 Lifecycle & Cluster Upgrade Resilience (Keyless WIF)

Because OpenShift Dedicated WIF clusters run the **Cloud Credential Operator (`CCO`)** in `Manual` mode:
1. **One-Time CSI Setup (Automated)**: When deploying Option 1 (`Filestore CSI`) or Option 2 (`Secret Manager CSI`), the prerequisite scripts (`01-prereq-filestore-psa.sh`, `01-prereq-secretmanager.sh`, and `02-deploy-secrets-csi.sh`) bind `roles/iam.workloadIdentityUser` on your dedicated customer-managed Service Account (`${PREFIX}-gcp-sa`) to the cluster's existing GCP Workload Identity Pool and populate the keyless `"type": "external_account"` Kubernetes `Secret` (`gcp-filestore-cloud-credentials` / `gcp-secrets-store-cloud-credentials`) in `openshift-cluster-csi-drivers`.
2. **Zero Impact During Day-2 Operations**:
   - **Cluster Upgrades (`4.22` $\rightarrow$ `4.23`) & `ocm gcp update wif-config`**: Because `${PREFIX}-gcp-sa` is customer-managed (not an OCM-owned SA), pre-upgrade WIF updates never overwrite its Filestore or Secret Manager IAM roles.
   - **Node Replacements & MachinePool Scaling**: Authentication uses projected Kubernetes ServiceAccount OIDC tokens (`/var/run/secrets/openshift/serviceaccount/token`), so replacing worker nodes or adding new MachinePools requires no credential changes.
   - **New PVCs & Secrets**: Any additional Filestore `PersistentVolumeClaim` or Secret Manager `SecretProviderClass` created later works automatically.
