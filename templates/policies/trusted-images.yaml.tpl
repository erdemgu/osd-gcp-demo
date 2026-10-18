name: projects/${PROJECT_ID}/policies/compute.trustedImageProjects
spec:
  inheritFromParent: true
  rules:
  - values:
      allowedValues:
      - projects/debian-cloud
      - projects/rhel-cloud
      - projects/rhcos-cloud
      - projects/redhat-marketplace-public
      - projects/mpi-redhat-marketplace-public
