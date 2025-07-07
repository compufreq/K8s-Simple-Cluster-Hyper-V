Based on the search results, here's how to download Ubuntu Server 22.04 ISO, install it on your VMs, and ensure SSH access:

## **Download Ubuntu Server 22.04 ISO**

### **Step 1: Download the ISO**
```powershell
# On Windows host, download Ubuntu Server 22.04.5 LTS
# Navigate to your ISO directory
cd C:\Hyper-V\ISOs

# Download using PowerShell
Invoke-WebRequest -Uri "https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso" -OutFile "ubuntu-24.04.2-live-server-amd64.iso"
```

**Alternative download locations:**
- Main: https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-live-server-amd64.iso (2.992 GB)

### **Step 2: Verify Download**
```powershell
# Check file size (should be ~2.992 GB)
Get-ChildItem "ubuntu-24.04.2-live-server-amd64.iso"
```

## **Install Ubuntu on Each VM**

### **Step 3: Boot VMs and Install Ubuntu**

For each VM (master and 3 workers):

```powershell
# Start Hyper-V Manager
virtmgmt.msc

# For each VM:
# 1. Right-click VM → Settings
# 2. DVD Drive → Image file → Browse to ubuntu-22.04.5-live-server-amd64.iso
# 3. Start the VM
# 4. Connect to VM console
```

### **Step 4: Ubuntu Installation Process**

During Ubuntu installation:

1. **Language Selection:** English
2. **Keyboard Layout:** Your layout
3. **Network Configuration:**
   - Use the static IPs from cloud-init configs
      - subnet: 192.168.100.0/24
      - Gateway: 192.168.100.1
      - DNS: 8.8.8.8, 8.8.4.4
   - Master:
      - Address: 192.168.100.10
      - hostname: secure-k8s-cluster-master
   - Worker 1:
      - Address: 192.168.100.21
      - hostname: secure-k8s-cluster-worker-1
   - Worker 2:
      - Address: 192.168.100.22
      - hostname: secure-k8s-cluster-worker-2
   - Worker 3:
      - Address: 192.168.100.23
      - hostname: secure-k8s-cluster-worker-3

4. **Storage Configuration:** Use entire disk
5. **Profile Setup:**
   - Name: k8sadmin
   - Server name: Use hostnames from cloud-init that can be found under: C:\Hyper-V\VHDs
   - Username: k8sadmin
   - Password: (set a secure password)

6. **SSH Setup:** ✅ **Install OpenSSH server**
7. **Import SSH Identity:** Import from GitHub/Launchpad (optional)
8. **Featured Server Snaps:** Skip for now

### **Post-Installation SSH Configuration (if not configured)**

After Ubuntu installation completes on each VM:

```bash
# SSH into each VM to configure
ssh k8sadmin@192.168.100.10  # Master
ssh k8sadmin@192.168.100.21  # Worker 1
ssh k8sadmin@192.168.100.22  # Worker 2
ssh k8sadmin@192.168.100.23  # Worker 3
```

### **Check SSH Access Configuration**

On each VM, ensure SSH is properly configured:

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install OpenSSH server (if not already installed)
sudo apt install -y openssh-server

# Check SSH status
sudo systemctl status ssh

# Enable SSH to start on boot
sudo systemctl enable ssh

# Configure firewall to allow SSH
sudo ufw allow ssh
sudo ufw --force enable

# Verify SSH is listening
sudo ss -tlnp | grep :22
```

### **Configure SSH Keys (Recommended - if not configured)**

```bash
# On Windows host, copy your SSH public key to each VM
# Replace with your actual public key
$sshKey = Get-Content "$env:USERPROFILE\.ssh\id_rsa.pub"

# For each VM, add the SSH key
ssh k8sadmin@192.168.100.10 "mkdir -p ~/.ssh && echo '$sshKey' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

### **Test SSH Connectivity**

```bash
# Test SSH access from Windows host to each VM
ssh k8sadmin@192.168.100.10 "hostname && ip addr show eth0"
ssh k8sadmin@192.168.100.21 "hostname && ip addr show eth0"
ssh k8sadmin@192.168.100.22 "hostname && ip addr show eth0"
ssh k8sadmin@192.168.100.23 "hostname && ip addr show eth0"
```

## **Troubleshooting SSH Issues**

### **If SSH Connection Fails:**

```bash
# On each VM, check SSH service
sudo systemctl status ssh
sudo systemctl restart ssh

# Check firewall
sudo ufw status
sudo ufw allow 22/tcp

# Verify network connectivity
ping 192.168.100.1  # Gateway
ping 8.8.8.8        # Internet

# Check SSH configuration
sudo nano /etc/ssh/sshd_config
# Ensure these settings:
# Port 22
# PasswordAuthentication yes (initially)
# PubkeyAuthentication yes
# PermitRootLogin no
```

### **Network Connectivity Issues:**

```powershell
# On Windows host, check Hyper-V network
Get-VMSwitch
Get-NetNat

# If NAT is missing, recreate it
New-NetNat -Name "K8s-Internal-Switch-NAT" -InternalIPInterfaceAddressPrefix "192.168.100.0/24"
```

## **Verification Checklist**

- ✅ **Ubuntu 22.04.5 LTS installed on all 4 VMs**
- ✅ **Static IP addresses configured:**
   - Master: 192.168.100.10
   - Worker 1: 192.168.100.21
   - Worker 2: 192.168.100.22
   - Worker 3: 192.168.100.23

- ✅ **SSH access working from Windows host to all VMs**
- ✅ **Internet connectivity working on all VMs**
- ✅ **User 'k8sadmin' created with sudo privileges**
- ✅ **OpenSSH server installed and running**

Once all VMs are accessible via SSH, you can proceed with the security hardening script on each node.