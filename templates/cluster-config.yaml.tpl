# ==============================================================================
# Declarative Red Hat OpenShift Dedicated (OSD) on GCP Cluster Specification
# Rendered by scripts/04-bastion-setup.sh and consumed by 05-bastion-install-osd.sh
# ==============================================================================
apiVersion: ocm.openshift.io/v1alpha1
kind: OSDClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  domainPrefix: ${DOMAIN_PREFIX}
spec:
  product: ${OSD_PRODUCT}
  provider: gcp
  ccs:
    enabled: true
  subscription:
    type: ${SUBSCRIPTION_TYPE}
    marketplaceGcpTerms: ${MARKETPLACE_GCP_TERMS}
  channelGroup: stable
  version: "${OSD_VERSION}"
  region: ${REGION}
  multiAZ: ${MULTI_AZ}
  private: true
  gcp:
    projectID: ${PROJECT_ID}
    authMode: wif
    wifConfigName: "${WIF_CONFIG_NAME}"
    security:
      secureBootForShieldedVMs: ${SECURE_BOOT_FOR_SHIELDED_VMS}
    network:
      vpcName: ${VPC_NAME}
      controlPlaneSubnet: ${SUBNET_CONTROL_PLANE}
      computeSubnet: ${SUBNET_WORKER}
      pscSubnet: ${SUBNET_PSC}
  networking:
    machineCIDR: ${VPC_CIDR}
    podCIDR: 10.128.0.0/14
    serviceCIDR: 172.30.0.0/16
    hostPrefix: 23
  compute:
    machineType: ${COMPUTE_MACHINE_TYPE}
    replicas: ${COMPUTE_NODES}
  identityProvider:
    type: htpasswd
    name: htpasswd
    adminUser: ${OSD_ADMIN_USER}
    groups:
      - dedicated-admins
      - cluster-admins
