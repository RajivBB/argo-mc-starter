# OCM + ArgoCD ApplicationSet Example

This example demonstrates how to use **Open Cluster Management (OCM)** together with **ArgoCD ApplicationSet** to deploy applications across multiple managed clusters using GitOps.

---

## Files

- `applicationset.yaml` → Defines the ApplicationSet that generates ArgoCD Applications for each cluster selected by OCM.  
- `placement.yaml` → OCM Placement resource that targets clusters with a specific `ClusterClaim`.  
- `configmap.yaml` → ConfigMap required by the ApplicationSet generator to interpret OCM PlacementDecisions.  
- `basic-auth-secret.yaml` → ArgoCD repository credential (username/password).  
- `ssh-secret.yaml` → ArgoCD repository credential (SSH private key).  

---

## Workflow

### 1. Cluster Registration with OCM
- Managed clusters must be registered to the hub using OCM Klusterlet.  
- The provided placement selects the cluster with the following claim:

        id.k8s.io = dev-kind-east
Since numberOfClusters: 1, only one cluster will be chosen.

### 2. Repository Credentials for ArgoCD
- Secrets must be created in the argocd namespace in the spoke clusters where the applicationset will be deployed

          kubectl apply -f basic-auth-secret.yaml -n argocd --context kind-east
            # OR
        kubectl apply -f ssh-secret.yaml -n argocd --context kind-east

- Note
    - The ApplicationSet does not reference the secret directly.
ArgoCD automatically matches the secret to the repoURL defined in the ApplicationSet.

### 3. ConfigMap for Placement Generator
 - The configmap.yaml defines how the ApplicationSet generator interprets PlacementDecisions.
- It maps status.decisions[*].clusterName into the {{clusterName}} variable for the ApplicationSet template.

        kubectl apply -f configmap.yaml -n argocd --context kind-hub

### 4. Deploy ApplicationSet
- The applicationset.yaml uses the clusterDecisionResource generator:
- Reads PlacementDecisions produced by OCM.
- Creates one ArgoCD Application for each selected cluster.
- Syncs manifests from the Git repo into the destination cluster(s).

        kubectl apply -f applicationset.yaml -n argocd --context kind-hub

### 5. Placement Decisions in Action
- OCM evaluates the placement (id.k8s.io=dev-kind-east).
- A PlacementDecision object is created with the selected cluster.

The ApplicationSet generator consumes that decision and generates an ArgoCD Application.

ArgoCD syncs the workload into the target cluster (dev-kind-east).

Verification
Check the ApplicationSet:

        kubectl get applicationsets.argoproj.io -n argocd --context kind-hub
Check generated Applications:

        kubectl get applications.argoproj.io -n argocd --context kind-hub
Check PlacementDecisions:

        kubectl get placementdecisions.cluster.open-cluster-management.io -n argocd --context kind-hub


