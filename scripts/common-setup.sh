#!/bin/bash
set -e

# Load kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Set sysctl params
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Install containerd with systemd cgroup driver
apt-get update && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
mkdir -p /etc/containerd
apt-get install -y containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# sed -i 's/systemd_cgroup = false/systemd_cgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Disable swap
# Disable all swap
swapoff -a
# Verify no swap is active
swapon --show
# Now try to remove
rm -f /swap.img
# Comment out swap entries in /etc/fstab
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Add Kubernetes repo
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/kubernetes.gpg
echo "deb https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# Open required firewall ports (UFW)
ufw allow 6443/tcp   # Kubernetes API server
ufw allow 2379:2380/tcp  # etcd server client API
ufw allow 10250/tcp  # Kubelet API
ufw allow 10251/tcp  # kube-scheduler
ufw allow 10252/tcp  # kube-controller-manager
ufw allow 8472/udp   # Flannel VXLAN
ufw allow from 10.244.0.0/16  # Flannel pod network
sudo ufw allow 30000:32767/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 8285/udp # Allow Flannel UDP backend traffic
sudo ufw allow out 8285/udp
sudo ufw allow out 8472/udp # Allow Flannel VXLAN backend traffic
sudo ufw allow from 10.244.0.0/16 # Allow traffic from pod network CIDR (default Flannel: 10.244.0.0/16)
sudo ufw allow out to 10.244.0.0/16 # Allow traffic from pod network CIDR (default Flannel: 10.244.0.0/16)
sudo ufw allow from 10.244.0.0/16 to any port 6443 # Allow pod network to Kubernetes API server
sudo ufw allow out to 10.244.0.0/16 port 6443 # Allow pod network to Kubernetes API server
ufw reload

# Enable NTP for time sync
systemctl enable --now systemd-timesyncd

# --- Kubelet Certificate with IP SANs Automation ---
# Backup and remove old kubelet certs to force new CSR with IP SANs (if any existed)
sudo cp -r /var/lib/kubelet/pki /var/lib/kubelet/pki.bak.$(date +%Y%m%d%H%M) || true
sudo cp /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.bak.$(date +%Y%m%d%H%M) || true
sudo rm -f /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key

# Ensure nodeIP is set in kubelet config
NODE_IP=$(hostname -I | awk '{print $1}')
if ! grep -q "nodeIP:" /var/lib/kubelet/config.yaml; then
  echo "nodeIP: $NODE_IP" | sudo tee -a /var/lib/kubelet/config.yaml
fi

sudo systemctl restart kubelet