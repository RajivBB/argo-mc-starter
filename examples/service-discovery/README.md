# Multi-Cluster Service Export Examples

This guide shows how to deploy applications in one cluster and make them available in another using **Cilium ClusterMesh** with **Kubernetes ServiceExport/ServiceImport**.

We demonstrate two workloads:

- **NGINX Deployment** (basic example)  
- **WordPress Helm Chart** (advanced example)  

---

## NGINX Example (Basic)

### 1. Deploy NGINX in the source cluster

    kubectl apply -f deployment.yaml --context kind-east

### 2. Export the NGINX service

    kubectl apply -f nginx-serviceexport.yaml --context kind-east

- Note:

  - Cilium automatically creates a ServiceImport in the connected cluster(s), but only if the same namespace exists in those clusters.
  - If the namespace does not exist, you must create it manually before the ServiceImport will appear.



### 3. Verify ServiceImport in the destination cluster

    kubectl get serviceimports -A --context kind-west

### 4. Expose the service with Ingress

    kubectl apply -f ingress.yaml --context kind-west

#### Add the required annotation to the Ingress:
  
    nginx.ingress.kubernetes.io/service-upstream: "true"

### 5. Test access

    kubectl get ingress -A  --context kind-west

-------------------------------------------------------------

## WordPress Example (Advanced)

### 1. Deploy WordPress Helm chart in the source cluster

    helm install wordpress wordpress-25.0.1.tgz -n wordpress --create-namespace --kube-context kind-east

    or 

    kubectl apply -f service-discovery/applicationset.yaml


### 2. Export the WordPress service

    kubectl apply -f wp-serviceexport.yaml --context kind-east

### 3. Verify ServiceImport in the destination cluster

    kubectl get serviceimports.multicluster.x-k8s.io -n wordpress --context kind-west

### 4. Expose with Ingress in the destination cluster

    kubectl apply -f ingress.yaml --context kind-west

#### Add the required annotation to the Ingress:
  
    nginx.ingress.kubernetes.io/service-upstream: "true"

### 5. Test access

    kubectl get ingress -n wordpress --context kind-west

-------------------------------------------------

Update in the /etc/hosts:
    
    <LOADBALANCER-IP> wordpress.example.com





