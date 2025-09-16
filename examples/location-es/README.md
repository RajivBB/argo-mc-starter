# Location-Based Placement (location-es) with OCM

This example demonstrates **Open Cluster Management (OCM)** placement by location, using a **ManagedClusterSet**, **ManagedClusterSetBinding**, **ClusterClaims** (east/west), and two distribution patterns:

- `ManifestWorkReplicaSet` to push **workloads/manifests** to selected clusters.
- `ManifestWorkReplicaSet` that pushes an **Argo CD Application** object into selected clusters (requires Argo CD installed in those clusters).

---

## What’s in this folder

- `managedclusterset.yaml` — Defines a `ManagedClusterSet` named **location-es**.
- `managedclustersetbinding.yaml` — Creates namespace **dev-team** and binds it to **location-es**.
- `clusterclaim-east.yaml` — Sets `ClusterClaim id.k8s.io=dev-kind-east` on the **east** cluster.
- `clusterclaim-west.yaml` — Sets `ClusterClaim id.k8s.io=dev-kind-west` on the **west** cluster.
- `placement.yaml` — A `Placement` that selects clusters with `id.k8s.io=dev-kind-east` (currently in namespace **argocd**, name **guestbook-app-placement-cluster1**).
- `application.yaml` — A `ManifestWorkReplicaSet` (in namespace **dev-team**) that deploys an **Argo CD Application** (guestbook) to clusters chosen by the Placement **select-dev-kind-es**.
- `manifestworkreplicaset.yaml` — A `ManifestWorkReplicaSet` (in namespace **dev-team**) that deploys an **NGINX** workload (Deployment) to clusters chosen by the Placement **select-dev-kind-es**.

---

## Prerequisites

- An OCM **Hub** cluster and at least two **Managed (spoke)** clusters registered (e.g., `dev-kind-east`, `dev-kind-west`).
- Kubeconfig contexts (examples below assume: `kind-hub`, `kind-east`, `kind-west`).
- If you intend to use `application.yaml`, **Argo CD must already be installed on the target clusters**, and the `argocd` namespace must exist on those spokes.

---

## Step-by-step

### 1) Create the `ManagedClusterSet` on the Hub

-  On the Hub

        kubectl --context kind-hub apply -f managedclusterset.yaml

- This defines the set location-es. Clusters “join” this set by having the label:
- on their corresponding ManagedCluster resource.

        cluster.open-cluster-management.io/clusterset=location-es

    

2) Bind the set to a namespace 

-  On the Hub

        kubectl --context kind-hub apply -f managedclustersetbinding.yaml
This:
- Creates the namespace dev-team.
- Binds dev-team to the ManagedClusterSet location-es so workloads created in dev-team can target that set.

- Note
    -   ManagedClusterSetBinding name must match the ManagedClusterSet name (already correct in the manifest).

3) Label your ManagedClusters to join the set
On the Hub, label the ManagedCluster resources that should be part of location-es:



- Example: label two managed clusters on the Hub

        kubectl --context kind-hub label managedcluster dev-kind-east  cluster.open-cluster-management.io/clusterset=location-es --overwrite
        kubectl --context kind-hub label managedcluster dev-kind-west  cluster.open-cluster-management.io/clusterset=location-es --overwrite

4) Create ClusterClaims on each spoke
Apply the cluster claims on the managed clusters:



-  On the east cluster

        kubectl --context kind-east apply -f clusterclaim-east.yaml

- On the west cluster
        
        kubectl --context kind-west apply -f clusterclaim-west.yaml
- This sets:

      id.k8s.io=dev-kind-east on the east cluster

      id.k8s.io=dev-kind-west on the west cluster

5) Create a Placement that targets the east cluster
W
```
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: guestbook-app-placement-cluster1
  namespace: argocd
spec:
  predicates:
    - requiredClusterSelector:
        claimSelector:
          matchExpressions:
            - key: id.k8s.io
              operator: In
              values:
                - dev-kind-east
  numberOfClusters: 1
```
Apply it on the Hub:

    kubectl --context kind-hub apply -f placement.yaml

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: select-dev-kind-es
  namespace: dev-team
spec:
  predicates:
    - requiredClusterSelector:
        claimSelector:
          matchExpressions:
            - key: id.k8s.io
              operator: In
              values:
                - dev-kind-east
  numberOfClusters: 1
```
Then:
```
kubectl --context kind-hub apply -f placement.yaml
```


6) Distribute workloads using ManifestWorkReplicaSet (from Hub)

6a) NGINX workload


- On the Hub

            kubectl --context kind-hub apply -f manifestworkreplicaset.yaml

    -  This ManifestWorkReplicaSet (in dev-team) distributes an NGINX Deployment (image nginx:1.14.2) to the cluster(s) selected by the Placement.
    - It includes the necessary namespace and deployment manifest in its template.

6b) Argo CD guestbook Application (optional)


- On the Hub

        kubectl --context kind-hub apply -f application.yaml

This ManifestWorkReplicaSet (in dev-team) pushes an Argo CD Application object (guestbook) into the selected cluster(s).


Verify
- ManagedClusterSet & Binding

        kubectl --context kind-hub get managedclusterset
        kubectl --context kind-hub get managedclustersetbinding -n dev-team

- Which clusters are in the set

        kubectl --context kind-hub get managedcluster -l cluster.open-cluster-management.io/clusterset=location-es


- ClusterClaims on each spoke

        kubectl --context kind-east get clusterclaim
        kubectl --context kind-west get clusterclaim

- Placement & Decisions (on Hub)

        kubectl --context kind-hub get placement -A
        kubectl --context kind-hub get placementdecisions -A


- ManifestWorkReplicaSet & generated ManifestWorks (on Hub)

        kubectl --context kind-hub -n dev-team get manifestworkreplicaset
        kubectl --context kind-hub get manifestwork -A

- Workload on the selected spoke (e.g., east)
    
-  Check the deployed namespace and pods (adjust namespace if your template creates a specific one)
    
        kubectl --context kind-east get ns
        kubectl --context kind-east get deploy,pod -A | grep nginx

- Argo CD Application on the spoke (if applied)

        kubectl --context kind-east -n argocd get applications.argoproj.io
