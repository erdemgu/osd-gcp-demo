# Phase 2 (Optional): Google Cloud Cymbal Demo Workloads on OpenShift Dedicated

Phase 2 is **optional** and provides **two independent workload options** showcasing Google Cloud storage and security integrations on your private Red Hat OpenShift Dedicated (OSD) cluster using **Google Cloud Cymbal** sample applications.

You can deploy **Option 1**, **Option 2**, or **both** in any order after your base OpenShift Dedicated cluster is running.

---

## Workload Options Overview

| Option | Cymbal Application | Workload Pattern | Storage / Edge Integration | Security / CSI Operators |
| :--- | :--- | :--- | :--- | :--- |
| **Option 1** | **Cymbal Retail Storefront** (`cymbal-storefront`) | **Stateless** multi-replica web frontend (`replicas: 3`, UBI9 Python 3.14) across zones | **Google Cloud Filestore Regional (`100Gi`, `2000 IOPS`, `NFSv4.1`)** (`ReadWriteMany` via Private Service Access) | **GCP Filestore CSI Driver Operator** (`filestore.csi.storage.gke.io`) |
| **Option 2** | **Cymbal Order & Inventory Ledger** (`cymbal-stateful`) | **Stateful** PostgreSQL database (`StatefulSet`) + Cymbal Ledger UI | **Google Cloud Hyperdisk Balanced** (`ReadWriteOnce` block storage via `pd.csi.storage.gke.io`) | **Secrets Store CSI Driver Operator** (`secrets-store.csi.k8s.io`) + **Google Cloud Secret Manager** |
| **Option 3 (Phase 3)** | **Cymbal Global Public Storefront** (`cymbal-public`) | **Public Edge** 3-zone web storefront exposed from a 100% private cluster | **Global External Application LB (L7)** + **Cloud CDN** + **Zonal NEGs (`GCE_VM_IP_PORT`)** + **Cloud Monitoring Uptime Check** | **Google Cloud Armor WAF (OWASP Top 10) & L7 DDoS** + **TLS 1.2+ SSL Policy** + **GFE Firewall & Zero-Trust `NetworkPolicy`** |

### Screenshots

#### Option 1: Cymbal Shops — Cloud Retail Storefront (Stateless + Regional Cloud Filestore `ReadWriteMany` NFS)

![Cymbal Retail Storefront — Stateless + Regional Cloud Filestore](../docs/images/02-cymbal-storefront-filestore.png)

#### Option 2: Cymbal Order & Inventory Ledger (Stateful PostgreSQL + Google Cloud Hyperdisk + Secret Manager CSI)

![Cymbal Order & Inventory Ledger — Stateful + Hyperdisk + Secret Manager](../docs/images/03-cymbal-ledger-hyperdisk-secrets.png)

---

## Directory Structure

```text
workloads/
├── README.md                                           # Phase 2 overview & quickstart
├── sync-to-bastion.sh                                  # Copies workloads/ directory to ~/osd-setup/workloads on Bastion VM
├── docs/
│   ├── architecture-phase2.md                          # Architecture diagrams & technical design for Options 1, 2 & 3
│   ├── option1-filestore-stateless-guide.md            # Step-by-step guide for Option 1 (Filestore + Stateless Cymbal)
│   ├── option2-hyperdisk-secrets-stateful-guide.md     # Step-by-step guide for Option 2 (Hyperdisk + Secret Manager + Stateful Cymbal)
│   └── option3-public-waf-ddos-guide.md                # Step-by-step guide for Option 3 (Cloud Armor WAF/DDoS, Cloud CDN & Global ALB)
├── option1-filestore-stateless/
│   ├── scripts/
│   │   ├── 01-prereq-filestore-psa.sh                  # Enables Filestore/PSA APIs, IAM roles, VPC Peering & CSI secret
│   │   ├── 02-deploy-filestore-csi.sh                  # Installs GCP Filestore CSI Driver Operator & Regional StorageClass
│   │   ├── 03-deploy-cymbal-stateless.sh               # Deploys Cymbal Storefront (3 replicas + RWX Filestore PVC + Route)
│   │   └── 04-cleanup-option1.sh                       # Removes Option 1 workload, PVC, Filestore instance & CSI resources
│   └── manifests/
│       ├── 01-filestore-csi-operator.yaml              # Subscription & ClusterCSIDriver (filestore.csi.storage.gke.io)
│       ├── 02-filestore-storageclass.yaml.tpl          # Regional Private Filestore StorageClass template
│       ├── 03-cymbal-filestore-pvc.yaml                # Namespace & 1Ti ReadWriteMany PVC
│       └── 04-cymbal-stateless-app.yaml                # Cymbal Storefront 3-replica Deployment, Service & TLS Route
├── option2-hyperdisk-stateful/
│   ├── scripts/
│   │   ├── 01-prereq-secretmanager.sh                  # Enables Secret Manager API, IAM roles & creates Cymbal secrets
│   │   ├── 02-deploy-secrets-csi.sh                    # Installs Secrets Store CSI Driver Operator & GCP Provider
│   │   ├── 03-deploy-cymbal-stateful.sh                # Deploys Hyperdisk StorageClass, SecretProviderClass & Cymbal StatefulSet
│   │   └── 04-cleanup-option2.sh                       # Removes Option 2 workload, Hyperdisk PVC, CSI & GCP Secrets
│   └── manifests/
│       ├── 01-hyperdisk-storageclass.yaml              # Hyperdisk Balanced StorageClass (hyperdisk-balanced)
│       ├── 02-secrets-store-csi-operator.yaml          # Subscription & ClusterCSIDriver (secrets-store.csi.k8s.io)
│       ├── 03-gcp-csi-provider.yaml                    # Google Cloud Provider DaemonSet for Secrets Store CSI Driver
│       ├── 04-secretproviderclass.yaml.tpl             # SecretProviderClass mapping GCP Secret Manager secrets
│       └── 05-cymbal-stateful-app.yaml                 # Cymbal PostgreSQL StatefulSet (Hyperdisk) + Ledger Web UI & Route
└── option3-public-waf-ddos/
    ├── scripts/
    │   ├── 01-deploy-public-workload.sh                # Deploys 3-zone Cymbal Public Storefront, NetworkPolicy & NodePort (:30080)
    │   ├── 02-deploy-cloud-armor-and-alb.sh            # Deploys Cloud Armor WAF/DDoS, Cloud CDN, Zonal NEGs, GFE Firewall & Global ALB
    │   ├── 03-test-waf-and-ddos.sh                     # Automated test suite for OWASP Top 10 WAF, CDN cache & L7 DDoS rate-limiting
    │   └── 04-cleanup-public-waf.sh                    # Removes Global ALB, Cloud Armor, NEGs, GFE Firewall, Uptime Check & namespace
    └── manifests/
        ├── 01-cymbal-public-namespace-netpol.yaml      # Namespace 'cymbal-public' & Zero-Trust NetworkPolicy
        └── 02-cymbal-public-deployment-svc.yaml        # 3-zone Cymbal Public Storefront + Cloud CDN static endpoint + NodePort (:30080)
```

---

## Quickstart

### 1. Copy Phase 2 Workloads to the Bastion VM (Run on Local Workstation)
*(Note: `04-bastion-setup.sh` also copies `workloads/` automatically during initial setup. Use `sync-to-bastion.sh` anytime to push updates).*
```bash
./workloads/sync-to-bastion.sh
```

### 2. SSH into the Bastion VM & Authenticate `gcloud`
Because the Bastion VM's attached service account (`${PREFIX}-gcp-sa`) has least-privilege roles ( unlike Self-Managed OCP where the installer SA is Project Owner), log in with your GCP user account inside the Bastion VM before running `01-prereq-*.sh` (the `01-prereq-*.sh` scripts also automatically prompt `gcloud auth login` if needed):
```bash
source config.env
gcloud compute ssh "${BASTION_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap

# Inside the Bastion VM:
gcloud auth login
```

### 3A. Run Option 1: Stateless Cymbal Storefront + Regional Cloud Filestore (Inside Bastion VM)
```bash
cd ~/osd-setup/workloads/option1-filestore-stateless
./scripts/01-prereq-filestore-psa.sh
./scripts/02-deploy-filestore-csi.sh
./scripts/03-deploy-cymbal-stateless.sh
```

### 3B. Run Option 2: Stateful Cymbal Ledger + Hyperdisk + Secret Manager (Inside Bastion VM)
```bash
cd ~/osd-setup/workloads/option2-hyperdisk-stateful
./scripts/01-prereq-secretmanager.sh
./scripts/02-deploy-secrets-csi.sh
./scripts/03-deploy-cymbal-stateful.sh
```

### 3C. Run Option 3 (Phase 3): Public Edge Storefront + Cloud Armor WAF/DDoS + Cloud CDN + Global ALB (Inside Bastion VM)
```bash
cd ~/osd-setup/workloads/option3-public-waf-ddos
./scripts/01-deploy-public-workload.sh
./scripts/02-deploy-cloud-armor-and-alb.sh
./scripts/03-test-waf-and-ddos.sh
```

### 4. Access Published Cymbal Applications Locally (On Local Workstation)
Update your local `/etc/hosts` (`127.0.0.2` on Linux/macOS, `127.0.0.1` on Windows WSL 2) and use the single IAP HTTPS/HTTP tunnel:
```bash
./scripts/06-access-and-test.sh hosts
./scripts/06-access-and-test.sh tunnel
```
- **Option 1 (Private Cymbal Storefront)**: `https://cymbal-storefront-cymbal-storefront.apps.<OSD_BASE_DOMAIN>`
- **Option 2 (Private Cymbal Stateful Ledger)**: `https://cymbal-ledger-cymbal-stateful.apps.<OSD_BASE_DOMAIN>`
- **Option 3 (Public Edge Cymbal Storefront via Cloud Armor & CDN)**: `https://cymbal.<PUBLIC_VIP>.nip.io` *(Directly accessible from the internet — no IAP tunnel required!)*

---

## Documentation

- [**Phase 2 & 3 Architecture Overview (`docs/architecture-phase2.md`)**](docs/architecture-phase2.md)
- [**Option 1 Step-by-Step Guide: Stateless Cymbal + Cloud Filestore (`docs/option1-filestore-stateless-guide.md`)**](docs/option1-filestore-stateless-guide.md)
- [**Option 2 Step-by-Step Guide: Stateful Cymbal + Hyperdisk + Secret Manager (`docs/option2-hyperdisk-secrets-stateful-guide.md`)**](docs/option2-hyperdisk-secrets-stateful-guide.md)
- [**Option 3 (Phase 3) Step-by-Step Guide: Public Edge + Cloud Armor WAF/DDoS + Cloud CDN (`docs/option3-public-waf-ddos-guide.md`)**](docs/option3-public-waf-ddos-guide.md)
