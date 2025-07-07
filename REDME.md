Based on the search results and the complete deployment setup, here are the detailed script running steps in the correct order:

## **Phase 1: Infrastructure Preparation (Windows Host)**

### **Step 1: Initial Setup**
```powershell
# Navigate to project directory
cd k8s-deployment

# Run initial configuration setup
.\scripts\HyperV-K8s-Setup.ps1
```
**What it does:**
- Installs PowerShell modules
- Generates SSH keys if needed
- Creates cluster configuration JSON
- Sets up directory structure

### **Step 2: VM Infrastructure Deployment**
```powershell
# Deploy Hyper-V infrastructure
.\scripts\Deploy-HyperV-Infrastructure.ps1
```
**What it does:**
- Creates virtual network switch with NAT
- Creates master and worker VMs
- Generates cloud-init configurations
- Sets up VM networking and storage

### **Step 3: Manual VM Setup**
```bash
# Download Ubuntu Server 22.04 LTS ISO
# Follow the OS_Installation Document for the OS Preparation Part
# Ensure all VMs are accessible via SSH
```

## **Phase 2: Preparation Phase (All VMs)**

### **Step 4: Run the common-init on All Nodes**

on each VM do the following:

```bash
# On each VM (Master and Workers), run these commands:
sudo mkdir -p /opt/k8s-deployment
sudo chown -R k8sadmin:k8sadmin /opt/k8s-deployment
sudo chmod -R 755 /opt/k8s-deployment
mkdir -p /opt/k8s-deployment/scripts

# From your local machine move the script files to the Nodes
scp -r scripts/ k8sadmin@<machine-ip>:/opt/k8s-deployment/
# example: scp -r scripts/ k8sadmin@192.168.100.10:/opt/k8s-deployment/
sudo sed -i -e 's/\r$//' /opt/k8s-deployment/scripts/common-setup.sh
sudo sed -i -e 's/\r$//' /opt/k8s-deployment/scripts/master-init.sh
sudo chmod +x /opt/k8s-deployment/scripts/*.sh
```

```bash
# Run on Master VM
ssh k8sadmin@192.168.100.10  # Master
sudo /opt/k8s-deployment/scripts/common-setup.sh
```

```bash
# Run on Worker 1 VM
ssh k8sadmin@192.168.100.21  # Worker 1
sudo /opt/k8s-deployment/scripts/common-setup.sh
```

```bash
# Run on Worker 2 VM
ssh k8sadmin@192.168.100.22  # Worker 2
sudo /opt/k8s-deployment/scripts/common-setup.sh
```

```bash
# Run on Worker 3 VM
ssh k8sadmin@192.168.100.23  # Worker 3
sudo /opt/k8s-deployment/scripts/common-setup.sh
```
**What it does:**
- Installs and configures containerd for containers
- Remove and disable the swap functionality
- Installs and configures kubelet kubeadm kubectl
- Configures the firewall for the required ports


### **Step 5: Reboot All VMs**
```bash
# Reboot each VM to apply kernel parameters
sudo reboot
```

## **Phase 3: Cluster Initialization (Master Node Only)**

### **Step 6: Initialize Kubernetes Cluster**
```bash
# SSH to master node
ssh k8sadmin@192.168.100.10

# Initialize the cluster
sudo /opt/k8s-deployment/scripts/master-init.sh
```
**What it does:**
- Configure Kubeadm
- Initializes Kubernetes control plane
- Configure Flannel
- Install Kubernetes Metrics Server
- Install local-path provisiouner
- Install Helm
- Install Prometheus
- Install Grafana
- Install Argo-CD
- Automate CSR Approvals
- Generates worker join command

### **Step 7: Verify Master Node**
```bash
# Check cluster status
kubectl get nodes
kubectl get pods --all-namespaces
kubectl cluster-info
```
At start all the services the require pods will not work and be at pending status till you join the Worker Nodes to the cluster

- Copy and paste the printed join command on each worker node
- After joining all the required workers re-run the following commands till you see the status changed from Pending to Running
- if after a max of 5 minutes still some are Pending or any other status other than Running, then check the logs for troubleshooting.

#### You have installed Prometheus, Grafana, and Argo CD using Helm and Kubernetes manifests, and each service is exposed using a NodePort. Here’s how to access their dashboards from your local machine:-

- For each service, you need:

    - The NodePort assigned to the service
    - The IP address of a Kubernetes node (master or worker)

#### Run these commands on your Kubernetes master node:

- Prometheus:

````bash
kubectl get svc -n monitoring prometheus-server
````

- Grafana:

````bash
kubectl get svc -n monitoring grafana
````
- Argo CD:
````bash
kubectl get svc -n argocd argocd-server
````
Look for the NodePort value in the output, e.g.:

````text
NAME              TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
prometheus-server NodePort   10.104.39.54    <none>        80:31038/TCP   5m
grafana           NodePort   10.104.39.55    <none>        80:31811/TCP   5m
argocd-server     NodePort   10.104.39.56    <none>        80:32000/TCP   5m
````
Here, the numbers after the colon (e.g. 31038, 31811, 32000) are your NodePorts.

Get the Node IP:
````bash
kubectl get nodes -o wide
````
Use the INTERNAL-IP of any node (master or worker).

Access the URLs from Your Local Machine:

````text
http://<NODE_IP>:<NODE_PORT>

Example:

If your master node IP is 192.168.100.10 and the NodePort for Prometheus is 31038:

Prometheus: http://192.168.100.10:31038
Grafana: http://192.168.100.10:31811
Argo CD: http://192.168.100.10:32000
````


Firewall Considerations
Ensure your node’s firewall allows incoming TCP traffic on the NodePort range (default: 30000–32767). from the steps we did previously, where we got the IPs in the table the ports we need are there.

- Example for UFW:

````bash
sudo ufw allow 31038/tcp
sudo ufw allow 31811/tcp
sudo ufw allow 32000/tcp
sudo ufw reload
````

#### Login Credentials
- Grafana:

    - Username: admin
    - Password:
````bash
kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
````

- Argo CD:

    - Username: admin
    - Password:
````bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode ; echo
````

#### Summary Table
- Service	Example URL	How to Get Password
    - Prometheus	http://192.168.100.10:31038	No login required (default)
    - Grafana	http://192.168.100.10:31811	See command above for admin password
    - Argo CD	http://192.168.100.10:32000	See command above for admin password

- Now you can access all dashboards from your browser on your local machine. If you have issues, double-check NodePort values, node firewall rules, and that the pods are in Running state.

#### Follow these steps to connect your Prometheus instance to Grafana and enable cluster monitoring dashboards:

1. Get the Prometheus Service URL
    - First, determine the NodePort and IP for your Prometheus service:

````bash
kubectl get svc -n monitoring prometheus-server
````
The NodePort is the number after the colon in the PORT(S) column (e.g., 80:31038/TCP → 31038).
The Node IP is the internal IP of your master or worker node (e.g., 192.168.100.10).
````text
Example URL:
http://192.168.100.10:31038
````
2. Access the Grafana UI
    - Open your browser and go to:

````text
http://<NODE_IP>:<Grafana_NodePort>
For example: http://192.168.100.10:31811
````

3. Add Prometheus as a Data Source in Grafana
In the Grafana UI, click the gear icon (⚙️) in the left sidebar and select Data Sources.

4. Click Add data source.

5. Select Prometheus from the list.

6. In the HTTP section, set the URL to your Prometheus NodePort URL, e.g.:

````text
http://192.168.100.10:31038
````
7. Leave other settings at their defaults (unless you have special requirements).

8. Click Save & Test at the bottom.

You should see a green message: "Data source is working".

9. Import Kubernetes Dashboards
    - In Grafana, go to Dashboards → Import.
    - Use a popular Kubernetes dashboard ID (e.g., 315 for cluster monitoring).
    - Set the data source to the Prometheus you just added.
    - Click Import.


10. Troubleshooting
```text
If you get connection errors, check:
The NodePort and IP are correct and accessible from your machine.
Your firewall allows the NodePort.
The Prometheus pod is running and healthy.
Now your Grafana is connected to Prometheus and ready to visualize cluster metrics and dashboards!
```
Troubleshooting commands
```bash
# Check if kubelet service exists and is running
sudo systemctl status kubelet --no-pager

# If kubelet is not found, check if it's installed
which kubelet

# Check kubelet logs for errors
sudo journalctl -u kubelet --no-pager -n 50

# Check CRI-O status
sudo systemctl status crio

# Restart CRI-O if needed
sudo systemctl restart crio

# Test CRI-O connectivity
sudo crictl version

# List all containers
sudo crictl ps -a

# Check for kube containers specifically
sudo crictl ps -a | grep kube

# Check container logs if any are failing
sudo crictl logs <container-id>

# 1. Complete reset
sudo kubeadm reset --cri-socket unix:///var/run/crio/crio.sock -f
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/

# 2. Ensure CRI-O is running properly
sudo systemctl stop crio
sudo rm -rf /var/lib/containers/storage
sudo systemctl start crio
sudo systemctl status crio

# 3. Verify CRI-O socket
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock version

sudo systemctl restart kubelet

# Re-run initialization
sudo /opt/k8s-deployment/scripts/initialize-stable-k8s-cluster.sh

#-----Monitoring Process of initialization in a different terminal window-----

# In another terminal, monitor progress:
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps -a

# Check kubelet logs if needed:
sudo journalctl -u kubelet -f

# Check control plane pod status:
sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock pods

# Verify CRI-O Status:
sudo systemctl status crio
sudo crictl info

# Check Firewall Rules:
sudo ufw allow 6443/tcp  # Kubernetes API
sudo ufw allow 2379:2380/tcp  # etcd

# Validate Kernel Parameters:
sudo sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.ipv4.ip_forward=1

# check the kubernetes API server container
# Get the API server container ID:
sudo crictl ps -a | grep kube-apiserver

# View logs:
sudo crictl logs <CONTAINER_ID>

```
These steps will establish a complete, production-ready Kubernetes platform with GitOps, monitoring, and security best practices. The key is to implement these incrementally and validate each step before proceeding to the next.