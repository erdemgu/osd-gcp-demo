# Option 1 Guide: Stateless Cymbal Storefront with Regional Private Cloud Filestore

This step-by-step guide walks through deploying **Option 1**: a multi-replica stateless **Google Cloud Cymbal Retail Storefront** application integrated with a **regional, private Google Cloud Filestore** instance using the **GCP Filestore CSI Driver Operator** on OpenShift Dedicated (OSD).

---

## Prerequisites

1. Your Phase 1 private OpenShift Dedicated cluster is installed and healthy (`oc get nodes` and `oc get co`).
2. `~/osd-setup/config.env` is present on the Bastion VM (synced via `./workloads/sync-to-bastion.sh` from your local workstation).

---

## Step 1: Sync Workloads to Bastion & SSH In

On your **Local Workstation**, sync the `workloads/` folder to the Bastion VM and open an SSH session:

```bash
./workloads/sync-to-bastion.sh
source config.env
gcloud compute ssh "${BASTION_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap
```

---

## Step 2: Configure Private Service Access & Filestore Prerequisites (`01-prereq-filestore-psa.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Regional Cloud Filestore (`Enterprise` tier) connects privately to your custom VPC (`${PREFIX}-vpc`) using **Google Cloud Private Service Access (PSA)** over VPC Network Peering.

Inside the **Bastion VM**, authenticate `gcloud` with your GCP user account (since the Bastion VM's attached service account does not have Project IAM Admin permissions, `01-prereq-filestore-psa.sh` will also automatically prompt `gcloud auth login` if you haven't logged in yet) and run:

```bash
gcloud auth login
cd ~/osd-setup/workloads/option1-filestore-stateless
./scripts/01-prereq-filestore-psa.sh
```

What this script does:
1. Enables `file.googleapis.com` (Cloud Filestore API) and `servicenetworking.googleapis.com` (Service Networking API) on `${PROJECT_ID}`.
2. Grants `roles/file.editor`, `roles/servicenetworking.networksAdmin`, and `roles/compute.networkViewer` to `${SA_EMAIL}`.
3. Allocates an internal `/20` IP range (`${PREFIX}-psa-range`) in `${VPC_NAME}` for `VPC_PEERING`.
4. Establishes the `servicenetworking.googleapis.com` VPC peering connection on `${VPC_NAME}`.
5. Binds `roles/iam.workloadIdentityUser` on `${SA_EMAIL}` to the cluster's GCP Workload Identity Pool for `gcp-filestore-csi-driver-controller-sa` / `gcp-filestore-csi-driver-operator` and creates the keyless WIF `gcp-filestore-cloud-credentials` secret (`"type": "external_account"`) in `openshift-cluster-csi-drivers`.

> [!NOTE]
> **Equivalence to `ccoctl gcp create-service-accounts`**:
> In OpenShift WIF documentation, Day-2 Filestore CSI credentials can be created using `./ccoctl gcp create-service-accounts --name=<sa> --workload-identity-pool=<pool> --workload-identity-provider=<provider> --project=<project> --credentials-requests-dir=/tmp/credreq`.
> `01-prereq-filestore-psa.sh` automates that **exact same** GCP IAM WIF binding and `"type": "external_account"` Kubernetes `Secret` generation directly via `gcloud` and `oc`—without requiring you to obtain a Red Hat pull secret, extract the `ccoctl` binary, or manually look up WIF pool/provider IDs.

---

## Step 3: Deploy the GCP Filestore CSI Driver Operator & Regional StorageClass (`02-deploy-filestore-csi.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, run:

```bash
./scripts/02-deploy-filestore-csi.sh
```

What this script does:
1. Installs the **GCP Filestore CSI Driver Operator** (`gcp-filestore-csi-driver-operator`) in `openshift-cluster-csi-drivers` from the Red Hat Operators catalog.
2. Waits for the operator CSV to succeed and creates the `ClusterCSIDriver` resource (`filestore.csi.storage.gke.io`).
3. Creates the regional `StorageClass` named **`filestore-regional-csi`**:
   - `provisioner: filestore.csi.storage.gke.io`
   - `tier: regional` (Regional multi-zone high-availability Filestore tier)
   - `protocol: NFS_V4_1` (`mountOptions: ["nfsvers=4.1"]`)
   - `max-iops: "2000"` (Custom performance IOPS)
   - `network: projects/${PROJECT_ID}/global/networks/${VPC_NAME}`
   - `connect-mode: PRIVATE_SERVICE_ACCESS`

Verify the CSI driver pods and StorageClass:
```bash
oc get pods -n openshift-cluster-csi-drivers -l app=gcp-filestore-csi-driver-controller
oc get sc filestore-regional-csi
```

---

## Step 4: Deploy the Cymbal Retail Storefront Stateless Workload (`03-deploy-cymbal-stateless.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, run:

```bash
./scripts/03-deploy-cymbal-stateless.sh
```

What this script does:
1. Creates the `cymbal-storefront` namespace and the `100Gi` `ReadWriteMany` (`RWX`) `PersistentVolumeClaim` (`cymbal-shared-assets-pvc`) using `storageClassName: filestore-regional-csi` (`tier: regional`, `2000 IOPS`, `NFSv4.1`).
   - *Note*: Provisioning a new Regional Cloud Filestore instance in Google Cloud typically takes **10–15 minutes**. The script monitors the PVC status until it reaches `Bound`.
2. Deploys the 3-replica stateless **Cymbal Retail Storefront** (`cymbal-storefront-web`), `Service` (`cymbal-storefront-svc`), and TLS Edge `Route` (`cymbal-storefront`).
3. All 3 stateless pods mount the shared Regional Filestore NFS volume at `/mnt/cymbal-filestore` (`ReadWriteMany`).

---

## Step 5: Test & Access the Cymbal Retail Storefront in Your Browser

### 5.1 Verify from Bastion VM
```bash
oc get pvc -n cymbal-storefront
oc get pods -n cymbal-storefront -o wide
ROUTE_HOST=$(oc get route cymbal-storefront -n cymbal-storefront -o jsonpath='{.spec.host}')
curl -k https://${ROUTE_HOST}
```

### 5.2 Open in Local Browser (Run on Local Workstation)
On your **Local Workstation**, run `./scripts/06-access-and-test.sh hosts` (which maps the OSD Console and Phase 2 Cymbal routes to `127.0.0.2` in `/etc/hosts`) and start the tunnel:

```bash
./scripts/06-access-and-test.sh hosts
./scripts/06-access-and-test.sh tunnel
```

Then open in your browser:
- `https://cymbal-storefront-cymbal-storefront.apps.<OSD_BASE_DOMAIN>`

The page **auto-refreshes every 3 seconds**, rotating the active serving **Pod and Worker Node** in round-robin order while all 3 active replicas read and write to the same shared Regional Cloud Filestore NFS mount (`/mnt/cymbal-filestore`).

### 5.3 Live Proof During a Demo (Run on Bastion VM)
You can prove live `ReadWriteMany` NFS sharing across all worker nodes by modifying `/mnt/cymbal-filestore/cymbal-catalog.json` inside **only one pod**—within 3 seconds, **all 3 pods** across every worker node will immediately display the new item:

```bash
# 1. Inspect the Cloud Filestore NFS mount and shared files from any pod:
oc exec -n cymbal-storefront deploy/cymbal-storefront-web -- df -hT /mnt/cymbal-filestore
oc exec -n cymbal-storefront deploy/cymbal-storefront-web -- ls -lh /mnt/cymbal-filestore

# 2. Add a 5th product to /mnt/cymbal-filestore/cymbal-catalog.json from a single pod:
oc exec -n cymbal-storefront deploy/cymbal-storefront-web -- python3 -c '
import json
path = "/mnt/cymbal-filestore/cymbal-catalog.json"
data = json.load(open(path))
data.append({
    "sku": "CYM-999",
    "name": "Cymbal AI Workstation Dock (Live Filestore Edit)",
    "price": "$299.00",
    "category": "Accessories",
    "stock": "Just Added via NFS!"
})
json.dump(data, open(path, "w"), indent=2)
'
```
Watch your browser auto-refresh 3 seconds later: every pod on every worker node immediately serves `CYM-999` from the shared Cloud Filestore file.

---

## Cleanup (Option 1 Only)

To remove the Option 1 Cymbal Storefront workload and dynamically provisioned Cloud Filestore instance (so you do not incur ongoing Filestore Enterprise charges), run on the **Bastion VM**:

```bash
cd ~/osd-setup/workloads/option1-filestore-stateless
./scripts/04-cleanup-option1.sh
```
