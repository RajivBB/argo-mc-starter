
---

### 📄 `docs/EXAMPLES.md`
Deep dive into the examples you bundled (`examples/` + `demo/`).

```markdown
# Example Scenarios

This repo includes multiple examples to help you explore **multi-cluster management**:

## 1. ArgoCD Multi-Cluster Deployment
Path: `examples/argocd/`

- **applicationset.yaml**: Defines an ApplicationSet for dynamic cluster targeting
- **configmap.yaml**: Provides cluster metadata
- **placement.yaml**: Controls where apps are deployed

## 2. Location-Based Scheduling
Path: `examples/location-es/`

- **clusterclaims/**: Declare east/west cluster locations
- **content-placement/**: Placement rules to target workloads by location
- **manageclusters/**: ManagedClusterSet definitions
- **workloads/**: Example apps and ManifestWorkReplicaSet

## 3. Demo Applications
Path: `demo/`

- **public/**: Public-facing GitOps ApplicationSets
- **private/**: Private repo integration with SSH + basic auth secrets
