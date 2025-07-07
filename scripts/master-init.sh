#!/bin/bash
set -e
set -euo pipefail

# --- Ensure containerd uses pause:3.10 and correct cgroup settings ---

# Install yq for YAML patching
apt-get update
wget https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

systemctl restart containerd
systemctl enable containerd

# --- Kubeadm configuration ---
cat <<EOF | tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.100.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.2
controlPlaneEndpoint: "192.168.100.10:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
EOF

# --- Initialize the cluster ---
kubeadm init --config=kubeadm-config.yaml

# --- Set up kubectl for the current user ---
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# --- Flannel CNI with Privileged Mode and seccompProfile: Unconfined ---
curl -sSL -o /tmp/kube-flannel.yml https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

yq -i '
  (select(.kind == "DaemonSet" and .metadata.name == "kube-flannel-ds")
    | .spec.template.spec.containers[] |=
      (select(.name == "kube-flannel")
        | .securityContext.privileged = true
        | .securityContext.seccompProfile.type = "Unconfined"
      )
  ) // .
' /tmp/kube-flannel.yml

kubectl apply -f /tmp/kube-flannel.yml

# --- Install Metrics Server with insecure TLS for kubelet (safe for internal clusters) ---
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# --- Install local-path provisioner for dynamic storage ---
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# --- Install Helm (if not already present) ---
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- Add Helm repos ---
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# --- Create namespaces ---
kubectl create namespace monitoring || true
kubectl create namespace argocd || true

# --- Install Prometheus with persistence and NodePort ---
helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --set server.persistentVolume.enabled=true \
  --set server.persistentVolume.size=8Gi \
  --set server.service.type=NodePort \
  --set alertmanager.persistentVolume.enabled=true \
  --set alertmanager.persistentVolume.size=2Gi

# --- Install Grafana with persistence and NodePort ---
helm install grafana grafana/grafana \
  --namespace monitoring \
  --set persistence.enabled=true \
  --set persistence.size=10Gi \
  --set service.type=NodePort

# --- Install Argo CD (latest stable) and expose UI via NodePort ---
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd patch svc argocd-server -p '{"spec": {"type": "NodePort"}}'

# --- Automated CSR Approval for Kubelet IP SANs ---
for i in {1..20}; do
  CSRS=$(kubectl get csr --no-headers | awk '/Pending/ {print $1}')
  for csr in $CSRS; do
    kubectl certificate approve "$csr"
  done
  sleep 5
done

# --- Print join command for workers ---
kubeadm token create --print-join-command