apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-regional-csi
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
mountOptions:
  - nfsvers=4.1
parameters:
  # Regional tier deploys a Multi-Zone HA Cloud Filestore instance (100Gi, 2000 IOPS, NFSv4.1)
  tier: regional
  protocol: NFS_V4_1
  max-iops: "2000"
  network: "projects/${PROJECT_ID}/global/networks/${VPC_NAME}"
  connect-mode: PRIVATE_SERVICE_ACCESS
