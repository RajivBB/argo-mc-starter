#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# CONFIGURATION
# ===========================================
HUB_CLUSTER_NAME="hub"
SPOKE_CONTEXTS=("kind-east" "kind-west")
SPOKE_CLUSTER_NAMES=("east" "west")
SPOKE_CLUSTERS=("east" "west")
SPOKE_CLUSTER_IDS=(2 3) # Hub = 1, Spokes = 2,3
DOCKER_REQUIRED=true
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
ALL_CONTEXTS=("kind-${HUB_CLUSTER_NAME}" "${SPOKE_CONTEXTS[@]}")

# Network configuration
HUB_POD_SUBNET="10.12.0.0/16"
HUB_SVC_SUBNET="10.13.0.0/16"
HUB_API_PORT=6443
EAST_POD_SUBNET="10.16.0.0/16"
EAST_SVC_SUBNET="10.17.0.0/16"
EAST_API_PORT=9443
WEST_POD_SUBNET="10.18.0.0/16"
WEST_SVC_SUBNET="10.19.0.0/16"
WEST_API_PORT=10443

# Version configuration
KIND_VERSION="v0.23.0"
HELM_VERSION="v3.14.0"
CILIUM_CLI_VERSION="" # Will be auto-detected

# Progress tracking
STEPS_TOTAL=12
CURRENT_STEP=0

# ===========================================
# UTILITY FUNCTIONS
# ===========================================
progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo "=================================================="
    echo "[PROGRESS] Step $CURRENT_STEP/$STEPS_TOTAL: $1"
    echo "=================================================="
}

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARNING] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

cleanup_on_failure() {
    log_error "Setup failed. Cleaning up clusters..."
    kind delete cluster --name $HUB_CLUSTER_NAME 2>/dev/null || true
    kind delete cluster --name east 2>/dev/null || true
    kind delete cluster --name west 2>/dev/null || true
    exit 1
}

# Set up error handling
trap cleanup_on_failure ERR


# ===========================================
# NETWORK UTILITIES
# ===========================================
get_ip_address() {
    local ip
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case $ID in
            ubuntu)
                ip=$(hostname -I | awk '{print $1}')
                ;;
            arch|manjaro)
                ip=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -1)
                ;;
            *)
                # Try multiple methods as fallback
                if command -v hostname >/dev/null 2>&1; then
                    ip=$(hostname -I | awk '{print $1}')
                elif command -v ip >/dev/null 2>&1; then
                    ip=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1 | head -1)
                fi
                ;;
        esac
    fi
    
    # Validate IP address
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip"
    else
        log_error "Unable to determine valid IP address. Got: $ip"
        exit 1
    fi
}

# ===========================================
# WAITING AND VERIFICATION FUNCTIONS
# ===========================================
wait_for_pods() {
    local context=$1
    local namespace=$2
    local selector=$3
    local timeout=${4:-300}
    
    log_info "Waiting for pods in $namespace (selector: $selector) to be ready..."
    if kubectl --context "$context" wait --for=condition=Ready pods \
        --selector="$selector" \
        --namespace="$namespace" \
        --timeout="${timeout}s" 2>/dev/null; then
        log_info "Pods are ready in $namespace"
    else
        log_warn "Timeout waiting for pods in $namespace, continuing anyway..."
    fi
}

wait_for_namespace() {
    local context=$1
    local namespace=$2
    local timeout=${3:-60}
    
    log_info "Waiting for namespace $namespace to be created..."
    local count=0
    while ! kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1; do
        if [ $count -ge $timeout ]; then
            log_error "Timeout waiting for namespace $namespace"
            exit 1
        fi
        sleep 1
        count=$((count + 1))
    done
    log_info "Namespace $namespace is ready"
}

# ===========================================
# MAIN INSTALLATION WORKFLOW
# ===========================================


# Get host IP for cluster API servers
HOST_IP=$(get_ip_address)
log_info "Using host IP: $HOST_IP"

# ===========================================
# CLUSTER CREATION
# ===========================================
create_cluster() {
    local name=$1
    local pod_subnet=$2
    local svc_subnet=$3
    local api_addr=$4
    local api_port=$5

    if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
        log_info "Cluster $name already exists. Skipping..."
        return
    fi

    log_info "Creating cluster $name..."
    cat <<EOF | kind create cluster --name "$name" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: "$pod_subnet"
  serviceSubnet: "$svc_subnet"
  disableDefaultCNI: true
  apiServerAddress: "$api_addr"
  apiServerPort: $api_port
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      certSANs:
      - "$api_addr"
      - "127.0.0.1"
EOF

    # Wait for nodes to be ready
   # wait_for_nodes "kind-$name"
}

progress "Creating hub cluster"
create_cluster "$HUB_CLUSTER_NAME" "$HUB_POD_SUBNET" "$HUB_SVC_SUBNET" "$HOST_IP" "$HUB_API_PORT"

progress "Creating spoke clusters"
create_cluster "${SPOKE_CLUSTERS[0]}" "$EAST_POD_SUBNET" "$EAST_SVC_SUBNET" "$HOST_IP" "$EAST_API_PORT"
create_cluster "${SPOKE_CLUSTERS[1]}" "$WEST_POD_SUBNET" "$WEST_SVC_SUBNET" "$HOST_IP" "$WEST_API_PORT"

# ===========================================
# MCS API INSTALLATION
# ===========================================
install_mcs_crds() {
    local context=$1
    
    if [[ -z "$context" ]]; then
        log_error "No context provided to install_mcs_crds"
        return 1
    fi
    
    log_info "Installing MCS API CRDs on cluster context: $context"

    if kubectl --context "$context" get crd serviceexports.multicluster.x-k8s.io >/dev/null 2>&1; then
        log_info "MCS API CRDs already installed on $context. Skipping..."
    else
        log_info "Applying MCS API CRDs on $context..."
        kubectl --context "$context" apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/refs/heads/master/config/crd/multicluster.x-k8s.io_serviceexports.yaml
        kubectl --context "$context" apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/refs/heads/master/config/crd/multicluster.x-k8s.io_serviceimports.yaml
    fi
}

progress "Installing MCS API CRDs"
install_mcs_crds "kind-$HUB_CLUSTER_NAME"
for ctx in "${SPOKE_CONTEXTS[@]}"; do
    install_mcs_crds "$ctx"
done

# ===========================================
# CILIUM INSTALLATION
# ===========================================
install_cilium() {
    local context=$1
    local cluster_name=$2
    local cluster_id=$3

    log_info "Installing Cilium on $cluster_name (ID: $cluster_id)..."
    kubectl config use-context "$context"

    # Add Cilium Helm repository
    if ! helm repo list | grep -q "cilium"; then
        log_info "Adding Cilium Helm repository..."
        helm repo add cilium https://helm.cilium.io/
    fi
    helm repo update cilium

    # Create Cilium values file
    cat <<EOF > "/tmp/cilium-values-${cluster_name}.yaml"
cluster:
  name: $cluster_name
  id: $cluster_id

clustermesh:
  useAPIServer: true
  maxConnectedClusters: 255
  enableEndpointSliceSynchronization: false
  enableMCSAPISupport: true
  annotations: {}
  config:
    enabled: false
    domain: mesh.cilium.io
    clusters: []

# Enable Hubble for observability
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

# Performance and reliability settings
operator:
  replicas: 1

# Enable IP masquerading for cross-cluster communication
enableIPv4Masquerade: true
enableIPv6Masquerade: false
EOF

    # Install Cilium
    helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --values "/tmp/cilium-values-${cluster_name}.yaml" \
        --wait --timeout 10m

    # Wait for Cilium to be ready
    wait_for_pods "$context" "kube-system" "k8s-app=cilium" 300
    
    # Clean up values file
    rm -f "/tmp/cilium-values-${cluster_name}.yaml"
    
    log_info "Cilium installation completed on $cluster_name"
}

progress "Installing Cilium CNI"
install_cilium "kind-$HUB_CLUSTER_NAME" "$HUB_CLUSTER_NAME" 1
install_cilium "kind-${SPOKE_CLUSTERS[0]}" "${SPOKE_CLUSTERS[0]}" "${SPOKE_CLUSTER_IDS[0]}"
install_cilium "kind-${SPOKE_CLUSTERS[1]}" "${SPOKE_CLUSTERS[1]}" "${SPOKE_CLUSTER_IDS[1]}"

# ===========================================
# CERT MANAGER INSTALLATION
# ===========================================
install_cert_manager_spokes() {
    progress "Installing cert-manager in spoke clusters"
    
    for ctx in "${SPOKE_CONTEXTS[@]}"; do
        log_info "Installing cert-manager in $ctx"
        
        # Apply CRDs first
        kubectl --context "$ctx" apply -f "$BASE_DIR/charts/cert-manager/cert-manager.crds.yaml"
        
        # Install chart
        helm upgrade --install cert-manager \
            "$BASE_DIR/charts/cert-manager/cert-manager-v1.18.2.tgz" \
            --kube-context "$ctx" \
            --namespace cert-manager \
            --create-namespace \
            --set installCRDs=false
    done
}


# ===========================================
# METALLB INSTALLATION
# ===========================================
progress "Installing MetalLB"
log_info "Installing MetalLB on all clusters..."

# Check if MetalLB installation script exists
if [ -f "$BASE_DIR/scripts/install_metallb.sh" ]; then
    # Hub
    "$BASE_DIR/scripts/install_metallb.sh" "kind-$HUB_CLUSTER_NAME" "hub"

    # Spokes
    for i in "${!SPOKE_CONTEXTS[@]}"; do
        context="${SPOKE_CONTEXTS[$i]}"
        cluster="${SPOKE_CLUSTER_NAMES[$i]}"
        "$BASE_DIR/scripts/install_metallb.sh" "$context" "$cluster"
    done
else
    log_warn "MetalLB installation script not found at $BASE_DIR/scripts/install_metallb.sh"
    log_warn "Skipping MetalLB installation"
fi

# ===========================================
# INGRESS-NGINX INSTALLATION
# ===========================================
install_ingress_nginx() {
    local context=$1
    log_info "Installing ingress-nginx on cluster: $context"

    if kubectl --context "$context" get ns ingress-nginx >/dev/null 2>&1; then
        log_info "ingress-nginx already installed on $context. Skipping..."
        return
    fi

    local chart_path="$BASE_DIR/charts/nginx-ingress/ingress-nginx-4.13.2.tgz"
    if [ -f "$chart_path" ]; then
        log_info "Installing ingress-nginx Helm chart on $context..."
        helm upgrade --install ingress-nginx "$chart_path" \
            --kube-context "$context" \
            --namespace ingress-nginx \
            --create-namespace \
            --wait --timeout 5m
    else
        log_warn "ingress-nginx chart not found at $chart_path"
        log_info "Installing from official repository..."
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
        helm repo update ingress-nginx
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --kube-context "$context" \
            --namespace ingress-nginx \
            --create-namespace \
            --wait --timeout 5m
    fi

    wait_for_pods "$context" "ingress-nginx" "app.kubernetes.io/name=ingress-nginx" 300
}

progress "Installing ingress-nginx"
for ctx in "${ALL_CONTEXTS[@]}"; do
    install_ingress_nginx "$ctx"
done

# ===========================================
# ARGOCD INSTALLATION
# ===========================================
progress "Installing ArgoCD on hub cluster"
kubectl config use-context "kind-$HUB_CLUSTER_NAME"

if ! kubectl get namespace argocd >/dev/null 2>&1; then
    kubectl create namespace argocd
fi

log_info "Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

wait_for_namespace "kind-$HUB_CLUSTER_NAME" "argocd"
wait_for_pods "kind-$HUB_CLUSTER_NAME" "argocd" "app.kubernetes.io/name=argocd-server" 600

# ===========================================
# OCM HUB INITIALIZATION
# ===========================================
progress "Initializing OCM hub"
kubectl config use-context "kind-$HUB_CLUSTER_NAME"

if ! kubectl get ns open-cluster-management >/dev/null 2>&1; then
    log_info "Initializing OCM hub..."
    clusteradm init --wait
else
    log_info "OCM hub already initialized"
fi

wait_for_namespace "kind-$HUB_CLUSTER_NAME" "open-cluster-management"

# ===========================================
# SPOKE CLUSTER JOINING
# ===========================================
progress "Joining spoke clusters to hub"

# Get hub connection details
HUB_API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
log_info "Hub API server: $HUB_API_SERVER"

# Get join token
TOKEN=$(clusteradm get token | grep -oP 'token=\K[^ ]+' | head -1)
if [ -z "$TOKEN" ]; then
    log_error "Failed to get OCM join token"
    exit 1
fi
log_info "Retrieved OCM join token"

# Join spoke clusters
for i in "${!SPOKE_CONTEXTS[@]}"; do
    CTX=${SPOKE_CONTEXTS[$i]}
    CLUSTER_NAME=${SPOKE_CLUSTER_NAMES[$i]}
    
    kubectl config use-context "$CTX"
    if ! kubectl get ns open-cluster-management-agent >/dev/null 2>&1; then
        log_info "Joining $CLUSTER_NAME ($CTX) to hub..."
        clusteradm join \
            --hub-token "$TOKEN" \
            --hub-apiserver "$HUB_API_SERVER" \
            --wait \
            --cluster-name "$CLUSTER_NAME" \
            --force-internal-endpoint-lookup \
            --context "$CTX"
    else
        log_info "$CLUSTER_NAME ($CTX) is already joined to hub. Skipping..."
    fi
done

# ===========================================
# ACCEPT MANAGED CLUSTERS
# ===========================================
progress "Accepting managed clusters"
kubectl config use-context "kind-$HUB_CLUSTER_NAME"

log_info "Accepting managed clusters..."
clusteradm accept --clusters "${SPOKE_CLUSTERS[0]},${SPOKE_CLUSTERS[1]}" --wait

# Verify managed clusters are accepted
verify_managed_clusters() {
    local hub_context="kind-$HUB_CLUSTER_NAME"
    log_info "Verifying managed clusters are accepted..."
    
    for cluster in "${SPOKE_CLUSTER_NAMES[@]}"; do
        local ready=false
        for i in {1..60}; do  # 5 minutes timeout
            local status
            status=$(kubectl --context "$hub_context" get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "")
            if [ "$status" = "True" ]; then
                log_info "Cluster $cluster is ready and available"
                ready=true
                break
            fi
            log_info "Waiting for cluster $cluster to be ready... ($i/60)"
            sleep 5
        done
        
        if [ "$ready" = false ]; then
            log_error "Cluster $cluster failed to join properly"
            kubectl --context "$hub_context" get managedcluster "$cluster" -o yaml
            exit 1
        fi
    done
}

verify_managed_clusters



# ===========================================
# LABEL MANAGED CLUSTERS WITH CLUSTERSET
# ===========================================
label_managed_clusters() {
    local hub_context="kind-$HUB_CLUSTER_NAME"
    echo "[INFO] Labeling ManagedClusters in hub cluster ($hub_context) with clusterset: location-es"
    for cluster in "${SPOKE_CLUSTER_NAMES[@]}"; do
        echo "[INFO] Adding label to ManagedCluster: $cluster"
        kubectl --context "$hub_context" label managedcluster "$cluster" \
            cluster.open-cluster-management.io/clusterset=location-es --overwrite
    done
    echo "[INFO] Labels applied successfully. Verifying..."
    kubectl --context "$hub_context" get managedclusters --show-labels
}

label_managed_clusters


echo "[INFO] Enabling ManifestWorkReplicaSet feature in ClusterManager..."
# Patch the ClusterManager CR to add the feature gate under workConfiguration
kubectl patch clustermanager cluster-manager --type='merge' -p '{
  "spec": {
    "workConfiguration": {
      "featureGates": [
        {
          "feature": "ManifestWorkReplicaSet",
          "mode": "Enable"
        }
      ]
    }
  }
}'
echo "[INFO] Patch applied. Verifying..."
# Verify the feature gate is enabled
kubectl get clustermanager cluster-manager -o yaml | grep -A3 "feature: ManifestWorkReplicaSet" || {
  echo "[ERROR] Feature not found in ClusterManager spec!"
  exit 1
}
echo "[INFO] ManifestWorkReplicaSet feature enabled successfully."




# ===========================================
# OCM ARGOCD ADDON
# ===========================================
progress "Installing OCM ArgoCD addon"
kubectl config use-context "kind-$HUB_CLUSTER_NAME"

log_info "Installing OCM hub addon manager..."
clusteradm install hub-addon --names argocd

log_info "Enabling ArgoCD addon for managed clusters..."
clusteradm addon enable --names argocd --clusters "${SPOKE_CLUSTERS[0]},${SPOKE_CLUSTERS[1]}"

# Wait for addons to be ready
sleep 30
for cluster in "${SPOKE_CLUSTER_NAMES[@]}"; do
    log_info "Waiting for ArgoCD addon to be ready on $cluster..."
    kubectl wait --for=condition=Available \
        managedclusteraddon/argocd \
        -n "$cluster" \
        --timeout=300s || log_warn "Timeout waiting for ArgoCD addon on $cluster"
done

# ===========================================
# CILIUM CLUSTERMESH
# ===========================================
enable_cilium_clustermesh() {
    log_info "Enabling Cilium Clustermesh connectivity..."

    # Enable clustermesh on all clusters
    for ctx in "${ALL_CONTEXTS[@]}"; do
        log_info "Enabling clustermesh on $ctx..."
        cilium clustermesh enable --context "$ctx" --service-type=NodePort
    done

    # Wait for clustermesh to be ready on all clusters
    for ctx in "${ALL_CONTEXTS[@]}"; do
        log_info "Waiting for clustermesh to be ready on $ctx..."
        cilium clustermesh status --context "$ctx" --wait || log_warn "Clustermesh status check failed for $ctx"
    done

    # Connect each cluster with every other cluster
    for ((i=0; i<${#ALL_CONTEXTS[@]}; i++)); do
        for ((j=i+1; j<${#ALL_CONTEXTS[@]}; j++)); do
            c1="${ALL_CONTEXTS[$i]}"
            c2="${ALL_CONTEXTS[$j]}"
            log_info "Connecting $c1 <--> $c2"
            cilium clustermesh connect --context "$c1" --destination-context "$c2" || log_warn "Failed to connect $ctx"
       done
    done
}

enable_cilium_clustermesh

# ===========================================
# Example Manifest
# ===========================================

## This file defines a ClusterClaim for a managed cluster in the "east" and "west" location.

 kubectl apply -f $BASE_DIR/examples/location-es/clusterclaims/clusterclaim-east.yaml --context kind-east
 kubectl apply -f $BASE_DIR/examples/location-es/clusterclaims/clusterclaim-west.yaml --context kind-west

## The following resources set up a ManagedClusterSet named "location-es", bind the "east" and "west" clusters to it,
## define a Placement policy to select these clusters, and create a ManifestWorkReplicaSet to deploy resources to them.
## The resources are applied to the hub cluster context. 

 kubectl apply -f $BASE_DIR/examples/location-es/manageclusters/managedclusterset.yaml --context kind-$HUB_CLUSTER_NAME
 kubectl apply -f $BASE_DIR/examples/location-es/manageclusters/managedclustersetbinding.yaml --context kind-$HUB_CLUSTER_NAME
 
 kubectl apply -f $BASE_DIR/examples/location-es/content-placement/placement.yaml --context kind-$HUB_CLUSTER_NAME
 kubectl apply -f $BASE_DIR/examples/location-es/workloads/manifestworkreplicaset.yaml --context kind-$HUB_CLUSTER_NAME
## The following resource sets up an ArgoCD Application using ManifestWorkReplicaSet to deploy applications to the clusters in the "location-es" ManagedClusterSet.
 kubectl apply -f $BASE_DIR/examples/location-es/workloads/application.yaml --context kind-$HUB_CLUSTER_NAME


## The following resources set up ArgoCD ApplicationSet to manage applications across the clusters in the "location-es" ManagedClusterSet.

 kubectl apply -f $BASE_DIR/examples/argocd/configmap.yaml --context kind-$HUB_CLUSTER_NAME
 kubectl apply -f $BASE_DIR/examples/argocd/placement.yaml --context kind-$HUB_CLUSTER_NAME
 kubectl apply -f $BASE_DIR/examples/argocd/applicationset.yaml --context kind-$HUB_CLUSTER_NAME



# ===========================================
# SETUP COMPLETE
# ===========================================
progress "Setup Complete!"
log_info "OCM ArgoCD setup completed successfully!"
echo "=================================================="