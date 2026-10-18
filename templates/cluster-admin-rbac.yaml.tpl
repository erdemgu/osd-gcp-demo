# ==============================================================================
# Declarative RBAC Manifests for OpenShift Dedicated (OSD) Admin User
# Applied by scripts/05-bastion-install-osd.sh after HTPasswd IDP login
# ==============================================================================
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${PREFIX}-dedicated-admin-binding
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: ${OSD_ADMIN_USER}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dedicated-admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${PREFIX}-cluster-admin-binding
subjects:
  - kind: User
    apiGroup: rbac.authorization.k8s.io
    name: ${OSD_ADMIN_USER}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bastion-admin
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${PREFIX}-bastion-admin-binding
subjects:
  - kind: ServiceAccount
    name: bastion-admin
    namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
---
apiVersion: v1
kind: Secret
metadata:
  name: bastion-admin-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: bastion-admin
type: kubernetes.io/service-account-token
