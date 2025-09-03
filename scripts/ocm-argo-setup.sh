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
STEPS_TOTAL=20
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
    kind delete cluster --name hub 2>/dev/null || true
    kind delete cluster --name east 2>/dev/null || true
    kind delete cluster --name west 2>/dev/null || true
    exit 1
}

# Set up error handling
trap cleanup_on_failure ERR

# ===========================================
# ARCHITECTURE AND OS DETECTION
# ===========================================
get_arch() {
    case $(uname -m) in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) 
            log_error "Unsupported architecture: $(uname -m)"
            exit 1 ;;
    esac
}

get_os() {
    case $(uname -s) in
        Linux) echo "linux" ;;
        Darwin) echo "darwin" ;;
        *) 
            log_error "Unsupported OS: $(uname -s)"
            exit 1 ;;
    esac
}

detect_distro() {
    case "$OSTYPE" in
        linux-gnu*) 
            if [ -f /etc/arch-release ]; then echo "arch"
            elif [ -f /etc/debian_version ]; then echo "debian"
            elif [ -f /etc/redhat-release ]; then echo "rhel"
            elif [ -f /etc/fedora-release ]; then echo "fedora"
            else echo "linux" 
            fi ;;
        darwin*) echo "mac" ;;
        *) echo "unknown" ;;
    esac
}

ARCH=$(get_arch)
OS_ARCH=$(get_os)
DISTRO=$(detect_distro)

log_info "Detected OS: $DISTRO, Architecture: $ARCH"

# ===========================================
# VALIDATION FUNCTIONS
# ===========================================
# validate_prerequisites() {
#     log_info "Validating system prerequisites..."
    
#     # Check available memory (minimum 8GB recommended)
#     local mem_gb
#     if command -v free >/dev/null 2>&1; then
#         mem_gb=$(free -g | awk '/^Mem:/{print $2}')
#         if [ "$mem_gb" -lt 8 ]; then
#             log_warn "Only ${mem_gb}GB RAM detected. 8GB+ recommended for stable operation."
#         else
#             log_info "Memory check passed: ${mem_gb}GB available"
#         fi
#     fi
    
#     # Check available disk space (minimum 10GB)
#     local disk_gb
#     disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
#     if [ "$disk_gb" -lt 10 ]; then
#         log_warn "Only ${disk_gb}GB disk space available. 10GB+ recommended."
#     else
#         log_info "Disk space check passed: ${disk_gb}GB available"
#     fi
    
#     # Check if required ports are available
#     check_port_availability $HUB_API_PORT "Hub cluster API"
#     check_port_availability $EAST_API_PORT "East cluster API"
#     check_port_availability $WEST_API_PORT "West cluster API"
# }

check_port_availability() {
    local port=$1
    local description=$2
    
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":$port "; then
            log_error "Port $port is already in use (needed for $description)"
            exit 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":$port "; then
            log_error "Port $port is already in use (needed for $description)"
            exit 1
        fi
    else
        log_warn "Cannot check port availability (ss/netstat not found)"
    fi
}

check_docker_running() {
    if $DOCKER_REQUIRED; then
        if ! docker info >/dev/null 2>&1; then
            log_error "Docker daemon is not running. Please start Docker first."
            exit 1
        fi
        log_info "Docker daemon is running"
    fi
}

# ===========================================
# PACKAGE INSTALLATION HELPERS
# ===========================================
install_package() {
    local pkg=$1
    log_info "Installing package: $pkg"
    case $DISTRO in
        arch) sudo pacman -Sy --noconfirm $pkg ;;
        debian) sudo apt-get update && sudo apt-get install -y $pkg ;;
        rhel) sudo yum install -y $pkg ;;
        fedora) sudo dnf install -y $pkg ;;
        mac) brew install $pkg ;;
        *) 
            log_error "Unsupported OS for package: $pkg"
            exit 1 ;;
    esac
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Installing Docker..."
        case $DISTRO in
            arch|rhel|fedora) 
                install_package docker
                sudo systemctl enable --now docker ;;
            debian)
                install_package apt-transport-https
                install_package ca-certificates
                install_package curl
                install_package software-properties-common
                
                # Add Docker's official GPG key and repository
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
                sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
                sudo apt-get update && sudo apt-get install -y docker-ce
                sudo systemctl enable --now docker ;;
            mac) 
                log_info "Installing Docker Desktop for Mac..."
                brew install --cask docker ;;
        esac
        
        # Add current user to docker group (Linux only)
        if [ "$OS_ARCH" = "linux" ]; then
            sudo usermod -aG docker "$USER"
            log_warn "Added user to docker group. You may need to log out and back in."
        fi
    else
        log_info "Docker already installed."
    fi
}

install_binary() {
    local name=$1
    local url=$2
    local version=$3
    
    if ! command -v "$name" >/dev/null 2>&1; then
        log_info "Installing $name $version..."
        local temp_file="/tmp/${name}-${version}"
        
        if curl -fsSL -o "$temp_file" "$url"; then
            chmod +x "$temp_file"
            sudo mv "$temp_file" "/usr/local/bin/$name"
            log_info "$name installed successfully"
        else
            log_error "Failed to download $name from $url"
            exit 1
        fi
    else
        local installed_version
        installed_version=$($name version 2>/dev/null || $name --version 2>/dev/null || echo "unknown")
        log_info "$name already installed (version: $installed_version)"
    fi
}

# ===========================================
# SPECIALIZED INSTALLATION FUNCTIONS
# ===========================================
install_kind() {
    local url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS_ARCH}-${ARCH}"
    install_binary "kind" "$url" "$KIND_VERSION"
}

install_kubectl() {
    local stable_version
    stable_version=$(curl -fsSL https://storage.googleapis.com/kubernetes-release/release/stable.txt)
    local url="https://storage.googleapis.com/kubernetes-release/release/${stable_version}/bin/${OS_ARCH}/${ARCH}/kubectl"
    install_binary "kubectl" "$url" "$stable_version"
}

install_clusteradm() {
    local url="https://github.com/open-cluster-management-io/clusteradm/releases/latest/download/clusteradm_${OS_ARCH}_${ARCH}"
    if [ "$OS_ARCH" = "darwin" ]; then
        url="https://github.com/open-cluster-management-io/clusteradm/releases/latest/download/clusteradm_${OS_ARCH}_${ARCH}.tar.gz"
    fi
    install_binary "clusteradm" "$url" "latest"
}

install_helm() {
    if ! command -v helm >/dev/null 2>&1; then
        log_info "Installing Helm ${HELM_VERSION}..."
        local temp_dir="/tmp/helm-${HELM_VERSION}"
        local archive_name="helm-${HELM_VERSION}-${OS_ARCH}-${ARCH}.tar.gz"
        local url="https://get.helm.sh/${archive_name}"
        
        mkdir -p "$temp_dir"
        if curl -fsSL -o "${temp_dir}/${archive_name}" "$url"; then
            tar -zxf "${temp_dir}/${archive_name}" -C "$temp_dir"
            sudo mv "${temp_dir}/${OS_ARCH}-${ARCH}/helm" /usr/local/bin/
            rm -rf "$temp_dir"
            log_info "Helm installed successfully"
        else
            log_error "Failed to download Helm"
            exit 1
        fi
    else
        local helm_version
        helm_version=$(helm version --short 2>/dev/null || echo "unknown")
        log_info "Helm already installed ($helm_version)"
    fi
}

install_cilium_cli() {
    if command -v cilium >/dev/null 2>&1; then
        local cilium_version
        cilium_version=$(cilium version --client 2>/dev/null | grep "cilium-cli" | awk '{print $2}' || echo "unknown")
        log_info "Cilium CLI already installed ($cilium_version)"
        return
    fi

    log_info "Installing Cilium CLI..."
    
    local version
    if [ -n "$CILIUM_CLI_VERSION" ]; then
        version="$CILIUM_CLI_VERSION"
    else
        version=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    fi
    
    log_info "Installing Cilium CLI version: $version"
    
    local temp_dir="/tmp/cilium-${version}"
    local archive_name="cilium-${OS_ARCH}-${ARCH}.tar.gz"
    local url="https://github.com/cilium/cilium-cli/releases/download/${version}/${archive_name}"
    
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    if curl -fsSL -O "${url}" && curl -fsSL -O "${url}.sha256sum"; then
        # Verify checksum
        if [ "$OS_ARCH" = "darwin" ]; then
            shasum -a 256 -c "${archive_name}.sha256sum"
        else
            sha256sum --check "${archive_name}.sha256sum"
        fi
        
        sudo tar xzf "$archive_name" -C /usr/local/bin
        cd - >/dev/null
        rm -rf "$temp_dir"
        log_info "Cilium CLI installed successfully"
    else
        log_error "Failed to download or verify Cilium CLI"
        exit 1
    fi
}

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
#progress "Validating prerequisites"
#validate_prerequisites
check_docker_running

progress "Installing prerequisites"
$DOCKER_REQUIRED && install_docker
install_kind
install_kubectl
install_clusteradm
install_helm
install_cilium_cli

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
- role: worker
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
        cilium clustermesh enable --context "$ctx" --service-type=NodePort --wait
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
# ===========================================
# Example Manifest
# ===========================================
# ===========================================

kubectl apply -f $BASE_DIR/examples/location-es/clusterclaim-east.yaml --context kind-east
kubectl apply -f $BASE_DIR/examples/location-es/clusterclaim-west.yaml --context kind-west

kubectl apply -f $BASE_DIR/examples/location-es/managedclusterset.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/location-es/managedclustersetbinding.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/location-es/placement.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/location-es/manifestworkreplicaset.yaml --context kind-$HUB_CLUSTER_NAME


kubectl apply -f $BASE_DIR/examples/argocd/rbac-appset.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/argocd/configmap.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/argocd/placement.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/argocd/applicationset.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f $BASE_DIR/examples/argocd/application.yaml --context kind-$HUB_CLUSTER_NAME

