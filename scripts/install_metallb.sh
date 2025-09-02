#!/bin/bash

set -e

context=$1
cluster_name=$2

if [ -z "$context" ] || [ -z "$cluster_name" ]; then
    echo "[ERROR] Usage: $0 <kube-context> <cluster-name>"
    exit 1
fi

echo "[INFO] Installing MetalLB on $cluster_name ($context)"

# Apply MetalLB manifests
kubectl --context "$context" apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.5/config/manifests/metallb-native.yaml
sleep 5

# Wait for MetalLB controller pod to be ready
echo "[INFO] Waiting for MetalLB controller pod to be ready..."
while true; do
    ready=$(kubectl --context "$context" get pod -n metallb-system -l component=controller | grep controller | awk '{print $2}')
    if [ "$ready" == "1/1" ]; then
        break
    fi
    echo "Metallb status :: $ready, sleeping for 10 seconds..."
    sleep 10
done

# Wait for webhook-service to be created
echo "[INFO] Waiting for webhook-service to become available..."
kubectl --context "$context" wait --for=condition=Available --timeout=60s deployment/controller -n metallb-system || {
    echo "[WARN] Webhook deployment not marked available, sleeping 10s just in case..."
    sleep 10
}

# Give DNS / webhook time to settle
echo "[INFO] Sleeping 10s to ensure webhook is reachable..."
sleep 10

# Detect Docker network for KinD
network=$(docker network inspect -f '{{.IPAM.Config}}' kind | awk '{print $1}' | cut -f 1,2 -d '.' | cut -f 1 -d '{' --complement)
if [ -z "$network" ]; then
    network="172.18"
fi

# Assign unique IP pool per cluster
if [ "$cluster_name" == "hub" ]; then
    ip_range="$network.254.200-$network.254.210"
elif [ "$cluster_name" == "east" ]; then
    ip_range="$network.254.211-$network.254.220"
elif [ "$cluster_name" == "west" ]; then
    ip_range="$network.254.221-$network.254.230"
else
    ip_range="$network.254.240-$network.254.250"
fi

echo "[INFO] Configuring IPAddressPool for $cluster_name with range: $ip_range"

# Apply IPAddressPool and L2Advertisement
cat <<EOF | kubectl --context "$context" apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-pool
  namespace: metallb-system
spec:
  addresses:
  - $ip_range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-l2
  namespace: metallb-system
EOF

echo "[INFO] MetalLB installed successfully on $cluster_name"
