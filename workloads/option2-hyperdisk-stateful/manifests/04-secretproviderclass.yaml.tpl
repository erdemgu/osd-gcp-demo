apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: cymbal-gcp-secrets
  namespace: cymbal-stateful
spec:
  provider: gcp
  secretObjects:
  - secretName: cymbal-db-secret
    type: Opaque
    data:
    - objectName: db-password.txt
      key: POSTGRESQL_PASSWORD
    - objectName: cymbal-api-key.txt
      key: CYMBAL_API_KEY
  parameters:
    auth: provider-adc
    secrets: |
      - resourceName: "projects/${PROJECT_ID}/secrets/${PREFIX}-cymbal-db-password/versions/latest"
        path: "db-password.txt"
      - resourceName: "projects/${PROJECT_ID}/secrets/${PREFIX}-cymbal-api-key/versions/latest"
        path: "cymbal-api-key.txt"
