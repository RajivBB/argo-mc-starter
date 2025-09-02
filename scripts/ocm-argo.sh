#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# CONFIGURATION
# ===========================================
HUB_CLUSTER_NAME="hub"
SPOKE_CONTEXTS=("kind-east" "kind-west")     # KinD cluster names
SPOKE_CLUSTER_NAMES=("east" "west")            # OCM managed cluster names
SPOKE_CLUSTERS=("east" "west")
SPOKE_CLUSTER_IDS=(2 3) # Hub = 1, Spokes = 2,3
DOCKER_REQUIRED=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===========================================
# OS DETECTION
# ===========================================
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/arch-release ]; then
            echo "arch"
        elif [ -f /etc/debian_version ]; then
            echo "debian"
        elif [ -f /etc/redhat-release ]; then
            echo "rhel"
        elif [ -f /etc/fedora-release ]; then
            echo "fedora"
        else
            echo "unknown"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "mac"
    else
        echo "unknown"
    fi
}

OS=$(detect_os)
echo "[INFO] Detected OS: $OS"

# ===========================================
# INSTALLATION FUNCTIONS
# ===========================================
install_package() {
    local pkg=$1
    case $OS in
        arch)
            sudo pacman -Sy --noconfirm $pkg ;;
        debian)
            sudo apt-get update && sudo apt-get install -y $pkg ;;
        rhel)
            sudo yum install -y $pkg ;;
        fedora)
            sudo dnf install -y $pkg ;;
        mac)
            brew install $pkg ;;
        *)
            echo "[ERROR] Unsupported OS for package: $pkg"
            exit 1 ;;
    esac
}

install_docker() {
    if ! command -v docker &>/dev/null; then
        echo "[INFO] Installing Docker..."
        case $OS in
            arch)
                install_package docker
                sudo systemctl enable --now docker ;;
            debian)
                install_package apt-transport-https ca-certificates curl software-properties-common
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
                sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
                sudo apt-get update && sudo apt-get install -y docker-ce ;;
            rhel|fedora)
                install_package docker
                sudo systemctl enable --now docker ;;
            mac)
                brew install --cask docker ;;
        esac
    else
        echo "[INFO] Docker already installed."
    fi
}

install_binary() {
    local name=$1
    local url=$2
    if ! command -v $name &>/dev/null; then
        echo "[INFO] Installing $name..."
        curl -Lo $name $url
        chmod +x $name
        sudo mv $name /usr/local/bin/
    else
        echo "[INFO] $name already installed."
    fi
}

# ===========================================
# INSTALL TOOLS
# ===========================================
echo "[INFO] Checking prerequisites..."

$DOCKER_REQUIRED && install_docker

# kind
install_binary kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64

# kubectl
install_binary kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl

# clusteradm
install_binary clusteradm https://github.com/open-cluster-management-io/clusteradm/releases/latest/download/clusteradm_linux_amd64

# cilium CLI
install_binary cilium curl -LO https://raw.githubusercontent.com/cilium/cilium/1.18.1/Documentation/installation/kind-config.yaml


# ===========================================
# CREATE CLUSTERS (HUB + SPOKES)
# ===========================================
create_cluster() {
    local name=$1
    local podSubnet=$2
    local svcSubnet=$3
    local apiAddr=$4
    local apiPort=$5

    if kind get clusters | grep -q "^${name}$"; then
        echo "[INFO] Cluster $name already exists. Skipping..."
    else
        echo "[INFO] Creating cluster $name..."
        cat <<EOF | kind create cluster --name $name --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: "$podSubnet"
  serviceSubnet: "$svcSubnet"
  disableDefaultCNI: true
  apiServerAddress: "$apiAddr"
  apiServerPort: $apiPort
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      certSANs:
      - "$apiAddr"
      - "127.0.0.1"
- role: worker
EOF
    fi
}

echo "[INFO] Creating hub cluster..."
create_cluster $HUB_CLUSTER_NAME "10.12.0.0/16" "10.13.0.0/16" "$(hostname -I | awk '{print $1}')" 6443

echo "[INFO] Creating spoke clusters..."
create_cluster ${SPOKE_CLUSTERS[0]} "10.16.0.0/16" "10.17.0.0/16" "$(hostname -I | awk '{print $1}')" 9443
create_cluster ${SPOKE_CLUSTERS[1]} "10.18.0.0/16" "10.19.0.0/16" "$(hostname -I | awk '{print $1}')" 10443

# ===========================================
# INSTALL MCS-API CRDs ON HUB CLUSTER
# ===========================================

install_mcs_crds() {
    local context=${1:-}
    if [[ -z "$context" ]]; then
        echo "[ERROR] No context provided to install_mcs_crds"
        return 1
    fi
    echo "[INFO] Installing MCS API CRDs on cluster context: $context"

    if kubectl --context "$context" get crd serviceexports.multicluster.x-k8s.io &>/dev/null; then
        echo "[INFO] MCS API CRDs already installed on $context. Skipping..."
    else
        echo "[INFO] Applying MCS API CRDs on $context..."
        kubectl --context "$context" apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/refs/heads/master/config/crd/multicluster.x-k8s.io_serviceexports.yaml
        kubectl --context "$context" apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/refs/heads/master/config/crd/multicluster.x-k8s.io_serviceimports.yaml
    fi
}


install_mcs_crds "kind-$HUB_CLUSTER_NAME"
for ctx in "${SPOKE_CONTEXTS[@]}"; do
    install_mcs_crds "$ctx"
done





# ===========================================
# INSTALL CILIUM WITH UNIQUE IDs
# ===========================================
install_cilium() {
    local context=$1
    local clusterName=$2
    local clusterID=$3

    echo "[INFO] Installing Cilium on $clusterName..."
    kubectl config use-context $context

    cat <<EOF > cilium-values.yaml
cluster:
  name: $clusterName
  id: $clusterID

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
EOF

    helm upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      -f cilium-values.yaml
}

install_cilium kind-$HUB_CLUSTER_NAME $HUB_CLUSTER_NAME 1
install_cilium kind-${SPOKE_CLUSTERS[0]} ${SPOKE_CLUSTERS[0]} ${SPOKE_CLUSTER_IDS[0]}
install_cilium kind-${SPOKE_CLUSTERS[1]} ${SPOKE_CLUSTERS[1]} ${SPOKE_CLUSTER_IDS[1]}



# ===========================================
# INSTALL METALLB ON ALL CLUSTERS
# ===========================================

# ===========================================
# Install MetalLB on all clusters
# ===========================================
echo "[INFO] Installing MetalLB on all clusters..."

# Hub
"$SCRIPT_DIR/install_metallb.sh" "kind-$HUB_CLUSTER_NAME" "hub"

#./scripts/install_metallb.sh 

# Spokes
for i in "${!SPOKE_CONTEXTS[@]}"; do
    context="${SPOKE_CONTEXTS[$i]}"
    cluster="${SPOKE_CLUSTER_NAMES[$i]}"
    $SCRIPT_DIR/install_metallb.sh "$context" "$cluster"
done

# ===========================================
# INSTALL ARGOCD ON HUB
# ===========================================
echo "[INFO] Installing ArgoCD on hub cluster..."
kubectl config use-context kind-$HUB_CLUSTER_NAME
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# ===========================================
# INITIALIZE OCM HUB
# ===========================================

echo "[INFO] Initializing OCM hub..."
kubectl config use-context kind-$HUB_CLUSTER_NAME
if ! kubectl get ns open-cluster-management &>/dev/null; then
    clusteradm init --wait
fi

# ===========================================
# JOIN SPOKE CLUSTERS
# ===========================================
HUB_API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(clusteradm get token | grep -oP 'token=\K[^ ]+')

for i in "${!SPOKE_CONTEXTS[@]}"; do
    CTX=${SPOKE_CONTEXTS[$i]}
    CLUSTER_NAME=${SPOKE_CLUSTER_NAMES[$i]}
    kubectl config use-context $CTX
    if ! kubectl get ns open-cluster-management-agent &>/dev/null; then
        echo "[INFO] Joining $CLUSTER_NAME ($CTX) to hub..."
        clusteradm join \
            --hub-token "$TOKEN" \
            --hub-apiserver "$HUB_API_SERVER" \
            --wait \
            --cluster-name "$CLUSTER_NAME" \
            --force-internal-endpoint-lookup \
            --context $CTX
    else
        echo "[INFO] $CLUSTER_NAME ($CTX) is already joined to hub. Skipping..."
    fi
done

# ===========================================
# ACCEPT MANAGED CLUSTERS
# ===========================================
kubectl config use-context $HUB_CLUSTER_NAME
clusteradm accept --clusters ${SPOKE_CLUSTERS[0]},${SPOKE_CLUSTERS[1]} --wait


# ===========================================
# INSTALL OCM AND ARGOCD ADDON

# ===========================================
#
kubectl config use-context kind-$HUB_CLUSTER_NAME
echo "[INFO] Installing OCM hub addon..."
clusteradm install hub-addon --names argocd

echo "[INFO] Enabling argocd addon for managed clusters..."
clusteradm addon enable --names argocd --clusters ${SPOKE_CLUSTERS[0]},${SPOKE_CLUSTERS[1]}

echo "[SUCCESS] Setup complete!"



# ===========================================
# ENABLE CILIUM CLUSTERMESH
# ===========================================

enable_cilium_clustermesh() {
    echo "[INFO] Enabling Cilium Clustermesh connectivity..."

    # Enable clustermesh on all clusters
    for ctx in "${ALL_CONTEXTS[@]}"; do
        cilium clustermesh enable --context "$ctx"
    done

    # Connect each cluster with every other cluster
    for ((i=0; i<${#ALL_CONTEXTS[@]}; i++)); do
        for ((j=i+1; j<${#ALL_CONTEXTS[@]}; j++)); do
            c1="${ALL_CONTEXTS[$i]}"
            c2="${ALL_CONTEXTS[$j]}"
            echo "[INFO] Connecting $c1 <--> $c2"
            cilium clustermesh connect --context "$c1" --destination-context "$c2"
        done
    done

    echo "[INFO] Cilium Clustermesh connectivity established among all clusters."
}

enable_cilium_clustermesh



# ===========================================
# LABEL MANAGED CLUSTERS WITH CLUSTERSET
# ===========================================
label_managed_clusters() {
    echo "[INFO] Labeling ManagedClusters with clusterset: location-es"

    for cluster in "${SPOKE_CLUSTER_NAMES[@]}"; do
        echo "[INFO] Adding label to ManagedCluster: $cluster"
        kubectl label managedcluster "$cluster" \
            cluster.open-cluster-management.io/clusterset=location-es --overwrite
    done

    echo "[INFO] Labels applied successfully. Verifying..."
    kubectl get managedclusters --show-labels
}


# ===========================================
# Example Manifest
# ===========================================
# ===========================================

kubectl apply -f example/location-es/clusterclaim-east.yaml --context kind-$SPOKE_CLUSTERS[0]
kubectl apply -f example/location-es/clusterclaim-west.yaml --context kind-$SPOKE_CLUSTERS[1]

kubectl apply -f examples/location-es/managedclusterset.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f examples/location-es/managedclustersetbinding.yaml --context kind-$HUB_CLUSTER_NAME

kubectl apply -f examples/location-es/placement.yaml --context kind-$HUB_CLUSTER_NAME
kubectl apply -f examples/location-es/manifestworkreplicaset.yaml --context kind-$HUB_CLUSTER