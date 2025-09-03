# Multi-Cluster Management with OCM and ArgoCD

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.25+-blue.svg)](https://kubernetes.io/)
[![OCM](https://img.shields.io/badge/OCM-Latest-green.svg)](https://open-cluster-management.io/)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-Latest-orange.svg)](https://argoproj.github.io/argo-cd/)

A comprehensive demonstration of multi-cluster Kubernetes management using **Open Cluster Management (OCM)** and **ArgoCD**, featuring automated cluster provisioning, service mesh connectivity with Cilium, and GitOps-based application deployment across multiple clusters.


### Key Features

- **🎯 Multi-Cluster Management**: Complete OCM setup with hub-spoke topology
- **🚀 GitOps Deployment**: ArgoCD for automated application deployment
- **🌐 Service Mesh**: Cilium cluster mesh for cross-cluster connectivity
- **⚖️ Load Balancing**: MetalLB for LoadBalancer services
- **🔀 Ingress Management**: nginx-ingress controllers on all clusters
- **📋 Resource Distribution**: ManifestWorkReplicaSet for scalable deployments
- **🏷️ Cluster Labeling**: Location-based cluster selection and placement

## 🚀 Quick Start

### Prerequisites

Before running the setup script, ensure you have the following available on your system:

- **Operating System**: Linux (Ubuntu/Debian, Arch, RHEL/Fedora) or macOS
- **Memory**: At least 8GB RAM (16GB recommended)
- **CPU**: 4+ cores recommended
- **Disk**: 20GB+ available space
- **Network**: Internet connectivity for downloading container images
- **Permissions**: sudo access for package installation

### Automatic Installation

The project includes an automated setup script that handles all prerequisites and cluster configuration:

```bash
# Clone the repository
git clone https://github.com/RajivBB/argo-mc-starter.git
cd argo-mc-starter

# Make the script executable
chmod +x scripts/ocm-argo-setup.sh

# Run the complete setup
./scripts/ocm-argo-setup.sh
```

### What the Script Does

The automated setup performs the following operations:

1. **📦 Prerequisites Installation**
   - Detects your operating system
   - Installs Docker, Kind, kubectl, clusteradm, and Cilium CLI
   - Sets up Helm repository for Cilium

2. **🏗️ Cluster Creation**
   - Creates 3 KinD clusters (hub, east, west)
   - Configures unique pod/service subnets for each cluster
   - Sets up proper API server endpoints for cross-cluster communication

3. **🔗 Network Setup**
   - Installs Cilium CNI with cluster mesh capabilities
   - Configures MetalLB for LoadBalancer services
   - Deploys ingress-nginx controllers

4. **🎯 OCM Configuration**
   - Initializes OCM hub on the hub cluster
   - Joins spoke clusters to the hub
   - Accepts and configures managed clusters
   - Enables ArgoCD addon for all clusters

5. **📋 Resource Management**
   - Creates ManagedClusterSets for logical cluster grouping
   - Configures Placement policies for workload distribution
   - Sets up ManifestWorkReplicaSet for scaled deployments

## 📚 Usage Examples

### Verify Cluster Status

After the setup completes, verify your clusters are ready:

```bash
# Check all clusters are running
kind get clusters

# Verify OCM managed clusters
kubectl --context kind-hub get managedclusters

# Check ArgoCD addon status
kubectl --context kind-hub get managedclusteraddons -A
```

### Deploy Applications Across Clusters

The setup includes example configurations for multi-cluster deployments:

```bash
# Deploy a sample application using ManifestWorkReplicaSet
kubectl apply -f examples/location-es/manifestworkreplicaset.yaml --context kind-hub

# Check deployment status across clusters
kubectl get pods --all-namespaces --context kind-east
kubectl get pods --all-namespaces --context kind-west
```

### Access ArgoCD UI

```bash
# Get ArgoCD admin password
kubectl --context kind-hub -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Port forward to access UI
kubectl --context kind-hub port-forward svc/argocd-server -n argocd 8080:443

# Access ArgoCD at https://localhost:8080
# Username: admin
# Password: (from previous command)
```

### Test Cross-Cluster Connectivity

```bash
# Check Cilium cluster mesh status
cilium clustermesh status --context kind-hub
cilium clustermesh status --context kind-east
cilium clustermesh status --context kind-west

# Test cross-cluster service discovery
kubectl apply -f examples/location-es/serviceexport.yaml --context kind-east
```

## 🛠️ Configuration

### Cluster Customization

You can modify the cluster configuration by editing the variables at the top of `ocm-argo.sh`:

```bash
# Cluster names and contexts
HUB_CLUSTER_NAME="hub"
SPOKE_CONTEXTS=("kind-east" "kind-west")
SPOKE_CLUSTER_NAMES=("east" "west")
SPOKE_CLUSTERS=("east" "west")
SPOKE_CLUSTER_IDS=(2 3)
```

### Network Configuration

Each cluster uses isolated network ranges to prevent conflicts:

- **Hub Cluster**: Pods `10.12.0.0/16`, Services `10.13.0.0/16`
- **East Cluster**: Pods `10.16.0.0/16`, Services `10.17.0.0/16`
- **West Cluster**: Pods `10.18.0.0/16`, Services `10.19.0.0/16`

## 📂 Project Structure

```
├── scripts/
│   ├── ocm-argo.sh              # Main setup script
│   └── install_metallb.sh       # MetalLB installation script
├── examples/
│   ├── location-es/             # Location-based examples
│   │   ├── clusterclaim-east.yaml
│   │   ├── clusterclaim-west.yaml
│   │   ├── managedclusterset.yaml
│   │   ├── managedclustersetbinding.yaml
│   │   ├── placement.yaml
│   │   └── manifestworkreplicaset.yaml
│   └── argocd/                  # ArgoCD configuration examples
│       ├── rbac-appset.yaml
│       ├── configmap.yaml
│       ├── placement.yaml
│       ├── applicationset.yaml
│       └── application.yaml
└── charts/                      # Helm charts
    └── nginx-ingress/
```

## 🧪 Testing

### Validate OCM Setup

```bash
# Check managed cluster status
kubectl --context kind-hub get managedclusters -o wide

# Verify cluster labels
kubectl --context kind-hub get managedclusters --show-labels

# Test placement decisions
kubectl --context kind-hub get placementdecisions -A
```

### Validate ArgoCD Integration

```bash
# Check ArgoCD addon status
kubectl --context kind-hub get managedclusteraddons -A

# Verify ArgoCD agents on spoke clusters
kubectl --context kind-east get pods -n argocd
kubectl --context kind-west get pods -n argocd
```

### Validate Cilium Mesh

```bash
# Test cluster mesh connectivity
cilium connectivity test --context kind-hub --multi-cluster kind-east
cilium connectivity test --context kind-hub --multi-cluster kind-west
```

## 🔧 Troubleshooting

### Common Issues

**Cluster Creation Fails**
- Ensure Docker is running: `sudo systemctl start docker`
- Check available resources: `docker system df`
- Verify KinD version: `kind version`

**OCM Join Fails**
- Check network connectivity between clusters
- Verify API server endpoints are accessible
- Review cluster token expiration

**Cilium Issues**
- Check CNI installation: `kubectl get pods -n kube-system`
- Verify cluster mesh status: `cilium status --context <cluster-context>`
- Review Cilium logs: `kubectl logs -n kube-system -l k8s-app=cilium`

### Cleanup

To completely remove all clusters and resources:

```bash
# Delete all KinD clusters
kind delete cluster --name hub
kind delete cluster --name east  
kind delete cluster --name west

# Remove downloaded binaries (optional)
sudo rm -f /usr/local/bin/{kind,kubectl,clusteradm,cilium}
```

## 🤝 Contributing

We welcome contributions from the community! Here's how you can help:

### Getting Started

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/amazing-feature`
3. **Make your changes**
4. **Test thoroughly** using the provided examples
5. **Commit your changes**: `git commit -m 'Add amazing feature'`
6. **Push to the branch**: `git push origin feature/amazing-feature`
7. **Open a Pull Request**

### Contribution Areas

- **📚 Documentation**: Improve setup guides, add tutorials
- **🔧 Scripts**: Enhance automation, add error handling
- **💡 Examples**: Create new deployment scenarios
- **🐛 Bug Fixes**: Report and fix issues
- **✨ Features**: Add new multi-cluster capabilities

### Development Setup

```bash
# Clone your fork
git clone https://github.com/your-username/your-repo-name.git
cd your-repo-name

# Test changes locally
./scripts/ocm-argo.sh

# Run examples
kubectl apply -f examples/location-es/ --context kind-hub
```


## 📖 Documentation

- [Open Cluster Management Documentation](https://open-cluster-management.io/docs/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Cilium Cluster Mesh Guide](https://docs.cilium.io/en/stable/gettingstarted/clustermesh/)
- [KinD Documentation](https://kind.sigs.k8s.io/)

## 🙏 Acknowledgments

- [Open Cluster Management Community](https://github.com/open-cluster-management-io)
- [ArgoCD Project](https://github.com/argoproj/argo-cd)
- [Cilium Project](https://github.com/cilium/cilium)
- [Kubernetes SIGs](https://github.com/kubernetes-sigs)


---

⭐ **Star this repository** if you find it helpful! Your support helps us continue improving this project.