# Option 2 Guide: Stateful Cymbal Ledger with Hyperdisk Block Storage & Secret Manager

This step-by-step guide walks through deploying **Option 2**: a stateful **Google Cloud Cymbal Order & Inventory Ledger** application backed by **Google Cloud Hyperdisk Balanced** block storage (`ReadWriteOnce`) and **Google Cloud Secret Manager** via the **Secrets Store CSI Driver Operator** on OpenShift Dedicated (OSD).

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

## Step 2: Configure Google Cloud Secret Manager (`01-prereq-secretmanager.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, authenticate `gcloud` with your GCP user account (since the Bastion VM's attached service account does not have Project IAM Admin permissions, `01-prereq-secretmanager.sh` will also automatically prompt `gcloud auth login` if you haven't logged in yet) and run:

```bash
gcloud auth login
cd ~/osd-setup/workloads/option2-hyperdisk-stateful
./scripts/01-prereq-secretmanager.sh
```

What this script does:
1. Enables `secretmanager.googleapis.com` on `${PROJECT_ID}`.
2. Grants `roles/secretmanager.admin` and `roles/secretmanager.secretAccessor` to `${SA_EMAIL}`, and binds `roles/iam.workloadIdentityUser` to the cluster's GCP Workload Identity Pool for `csi-secrets-store-provider-gcp-sa`.
3. Creates two secrets in **Google Cloud Secret Manager**:
   - `${PREFIX}-cymbal-db-password`: PostgreSQL password for the Cymbal Ledger database.
   - `${PREFIX}-cymbal-api-key`: Cymbal internal ledger & payment verification API key.

---

## Step 3: Install the Secrets Store CSI Driver Operator & GCP Provider (`02-deploy-secrets-csi.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, run:

```bash
./scripts/02-deploy-secrets-csi.sh
```

What this script does:
1. Installs the **Secrets Store CSI Driver Operator** (`secrets-store-csi-driver-operator`) in `openshift-cluster-csi-drivers` from the Red Hat Operators catalog.
2. Creates the `ClusterCSIDriver` resource (`secrets-store.csi.k8s.io`) with `managementState: Managed`.
3. Grants the OpenShift `privileged` SecurityContextConstraints (SCC) to the GCP CSI provider service account (`csi-secrets-store-provider-gcp-sa`) so the provider DaemonSet can bind its UNIX domain socket on the host nodes.
4. Deploys the **Google Cloud Provider for Secrets Store CSI Driver** (`csi-secrets-store-provider-gcp` DaemonSet) in `openshift-cluster-csi-drivers` and waits for all DaemonSet pods to become `Ready`.

Verify the Secrets Store CSI Driver and GCP Provider pods:
```bash
oc get pods -n openshift-cluster-csi-drivers -l app=csi-secrets-store
oc get pods -n openshift-cluster-csi-drivers -l app=csi-secrets-store-provider-gcp
```

---

## Step 4: Deploy Hyperdisk StorageClass, SecretProviderClass & Cymbal Stateful Workload (`03-deploy-cymbal-stateful.sh`)

> [!IMPORTANT]
> **Execution Location: BASTION VM**

Inside the **Bastion VM**, run:

```bash
./scripts/03-deploy-cymbal-stateful.sh
```

What this script does:
1. Creates the **`hyperdisk-balanced-csi`** `StorageClass` (`provisioner: pd.csi.storage.gke.io`, `type: hyperdisk-balanced`, `volumeBindingMode: WaitForFirstConsumer`).
2. Creates the `cymbal-stateful` namespace.
3. Renders and applies the `SecretProviderClass` (`cymbal-gcp-secrets`) referencing `projects/${PROJECT_ID}/secrets/${PREFIX}-cymbal-db-password/versions/latest` and `projects/${PROJECT_ID}/secrets/${PREFIX}-cymbal-api-key/versions/latest`.
4. Deploys the **Cymbal PostgreSQL `StatefulSet` (`cymbal-ledger-db`)**:
   - Dynamically provisions a `20Gi` **Google Cloud Hyperdisk Balanced** persistent volume (`cymbal-hyperdisk-data-cymbal-ledger-db-0`) on the `n4-standard-4` worker node.
   - Mounts the Google Cloud Secret Manager secrets at `/mnt/secrets-store` via the `secrets-store.csi.k8s.io` CSI driver and syncs `cymbal-db-secret`.
5. Deploys the **Cymbal Order & Inventory Ledger Dashboard (`cymbal-ledger-ui`)** + `Service` + TLS Edge `Route` (`cymbal-ledger`), which initializes the PostgreSQL schema on Hyperdisk, seeds Cymbal retail order & inventory ledger entries, and exposes an interactive web UI.

---

## Step 5: Test & Access the Cymbal Stateful Ledger in Your Browser

### 5.1 Verify from Bastion VM
```bash
# Check the Hyperdisk-backed PVC and StatefulSet pod:
oc get pvc -n cymbal-stateful
oc get pods -n cymbal-stateful -o wide

# Verify the secrets mounted inside the pod from Google Cloud Secret Manager:
oc exec -n cymbal-stateful statefulset/cymbal-ledger-db -- ls -la /mnt/secrets-store

# Test the Cymbal Ledger Web Route:
ROUTE_HOST=$(oc get route cymbal-ledger -n cymbal-stateful -o jsonpath='{.spec.host}')
curl -k https://${ROUTE_HOST}
```

### 5.2 Open in Local Browser (Run on Local Workstation)
On your **Local Workstation**, update `/etc/hosts` (`127.0.0.2`) and start the tunnel:

```bash
./scripts/06-access-and-test.sh hosts
./scripts/06-access-and-test.sh tunnel
```

Then open in your browser:
- `https://cymbal-ledger-cymbal-stateful.apps.<OSD_BASE_DOMAIN>`

---

## Cleanup (Option 2 Only)

To remove the Option 2 Cymbal Stateful workload, Hyperdisk volume, and Secret Manager secrets, run on the **Bastion VM**:

```bash
cd ~/osd-setup/workloads/option2-hyperdisk-stateful
./scripts/04-cleanup-option2.sh
```
