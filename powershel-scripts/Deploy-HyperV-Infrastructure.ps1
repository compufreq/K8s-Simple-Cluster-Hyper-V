# Deploy-HyperV-Infrastructure.ps1
# Deploy Hyper-V infrastructure for Kubernetes cluster

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "cluster-config.json"
)

Write-Host "=== Deploying Hyper-V Infrastructure for Kubernetes ===" -ForegroundColor Cyan

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Load configuration
if (!(Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    Write-Host "Please run HyperV-K8s-Setup.ps1 first" -ForegroundColor Yellow
    exit 1
}

try {
    # Load and convert JSON to Hashtable
    $ConfigJson = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $Config = @{}

    # Convert PSCustomObject to Hashtable
    $ConfigJson.PSObject.Properties | ForEach-Object {
        $Config[$_.Name] = $_.Value
    }

    Write-Host "Configuration loaded successfully" -ForegroundColor Green
    Write-Host "Cluster Name: $($Config.ClusterName)" -ForegroundColor White
    Write-Host "Master IP: $($Config.MasterNodeIP)" -ForegroundColor White
} catch {
    Write-Error "Failed to load configuration: $_"
    exit 1
}

# Function to create virtual switch - UPDATED
function New-K8sNetworkSwitch {
    param(
        [string]$SwitchName,
        [string]$SwitchType = "Internal"
    )

    Write-Host "Creating virtual switch: $SwitchName" -ForegroundColor Yellow

    # Check if switch already exists
    $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existingSwitch) {
        Write-Host "Virtual switch '$SwitchName' already exists - skipping creation" -ForegroundColor Yellow

        # Check if NAT already exists
        $existingNat = Get-NetNat -Name "$SwitchName-NAT" -ErrorAction SilentlyContinue
        if ($existingNat) {
            Write-Host "NAT '$SwitchName-NAT' already exists - skipping NAT creation" -ForegroundColor Yellow
            return
        }
    } else {
        try {
            New-VMSwitch -Name $SwitchName -SwitchType $SwitchType
            Write-Host "Virtual switch '$SwitchName' created successfully" -ForegroundColor Green
        } catch {
            Write-Error "Failed to create virtual switch: $_"
            throw
        }
    }

    # Configure NAT for internal switch
    if ($SwitchType -eq "Internal") {
        $adapterName = "vEthernet ($SwitchName)"
        $gatewayIP = "192.168.100.1"
        $prefixLength = 24

        # Set IP address for the virtual adapter (if not already set)
        $existingIP = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $existingIP) {
            New-NetIPAddress -IPAddress $gatewayIP -PrefixLength $prefixLength -InterfaceAlias $adapterName -ErrorAction SilentlyContinue
        }

        # Create NAT (if not already exists)
        $natName = "$SwitchName-NAT"
        $existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
        if (-not $existingNat) {
            New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix "192.168.100.0/24" -ErrorAction SilentlyContinue
            Write-Host "NAT configuration completed for $SwitchName" -ForegroundColor Green
        } else {
            Write-Host "NAT '$natName' already exists" -ForegroundColor Yellow
        }
    }
}

# Function to create cloud-init configuration
function New-CloudInitConfig {
    param(
        [string]$VMName,
        [string]$Role,
        [string]$IPAddress,
        [string]$SSHPublicKey
    )

    $hostname = $VMName.ToLower()
    $gateway = "192.168.100.1"
    $dns = "8.8.8.8"

    $CloudInitConfig = @"
#cloud-config
hostname: $hostname
manage_etc_hosts: true

# User configuration
users:
  - name: k8sadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $SSHPublicKey
    shell: /bin/bash
    groups: sudo, docker
    lock_passwd: false
    passwd: `$6`$rounds=4096`$salt`$hashedpassword

# Network configuration
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - $IPAddress/24
      gateway4: $gateway
      nameservers:
        addresses:
          - $dns
          - 8.8.4.4

# Package updates and installations
package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release
  - jq
  - vim
  - htop
  - net-tools
  - openssh-server

# System configuration
runcmd:
  # Enable SSH
  - systemctl enable ssh
  - systemctl start ssh

  # Configure firewall
  - ufw --force enable
  - ufw allow ssh
  - ufw allow 6443/tcp  # Kubernetes API
  - ufw allow 2379:2380/tcp  # etcd
  - ufw allow 10250/tcp  # kubelet
  - ufw allow 10251/tcp  # kube-scheduler
  - ufw allow 10252/tcp  # kube-controller-manager
  - ufw allow 30000:32767/tcp  # NodePort services
  - ufw allow 443/tcp comment # Allow webhook HTTPS
  - ufw allow 8443/tcp comment # Allow webhook server (Gatekeeper)

  # Disable swap
  - swapoff -a
  - sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

  # Load kernel modules
  - modprobe overlay
  - modprobe br_netfilter
  - echo 'overlay' >> /etc/modules-load.d/k8s.conf
  - echo 'br_netfilter' >> /etc/modules-load.d/k8s.conf

  # Set kernel parameters
  - echo 'net.bridge.bridge-nf-call-iptables = 1' >> /etc/sysctl.d/k8s.conf
  - echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.d/k8s.conf
  - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/k8s.conf
  - sysctl --system

  # Create directories for later scripts
  - mkdir -p /opt/k8s-scripts
  - chown k8sadmin:k8sadmin /opt/k8s-scripts

# Final message
final_message: "Kubernetes node $hostname is ready for configuration"

# Power state
power_state:
  mode: reboot
  delay: "+1"
  message: "Rebooting after cloud-init completion"
"@

    return $CloudInitConfig
}

# Function to create VM
function New-K8sVM {
    param(
        [string]$VMName,
        [string]$Role,
        [string]$IPAddress,
        [PSCustomObject]$Config
    )

    Write-Host "Creating VM: $VMName (Role: $Role)" -ForegroundColor Yellow

    # Check if VM already exists
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        Write-Host "VM '$VMName' already exists" -ForegroundColor Green
        return
    }

    try {
        # Create VM
        $VM = New-VM -Name $VMName -MemoryStartupBytes $Config.VMMemory -Generation $Config.VMGeneration -Path $Config.VHDPath

        # Configure VM settings
        Set-VM -Name $VMName -ProcessorCount $Config.VMProcessor -DynamicMemory -MemoryMinimumBytes ($Config.VMMemory / 2) -MemoryMaximumBytes ($Config.VMMemory * 2)

        # Enable security features for Generation 2 VMs
        if ($Config.VMGeneration -eq 2) {
            if ($Config.EnableSecureBoot) {
                Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
            }

            if ($Config.EnableTPM) {
                Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
                Enable-VMTPM -VMName $VMName
            }
        }

        # Create and attach VHD
        $VHDPath = Join-Path $Config.VHDPath "$VMName.vhdx"
        New-VHD -Path $VHDPath -SizeBytes $Config.VMDiskSize -Dynamic
        Add-VMHardDiskDrive -VMName $VMName -Path $VHDPath

        # Connect to network switch
        Connect-VMNetworkAdapter -VMName $VMName -SwitchName $Config.NetworkSwitch

        # Generate and save cloud-init configuration
        $CloudInitConfig = New-CloudInitConfig -VMName $VMName -Role $Role -IPAddress $IPAddress -SSHPublicKey $Config.SSHPublicKey
        $CloudInitPath = Join-Path $Config.VHDPath "cloud-init-$VMName.yaml"
        $CloudInitConfig | Out-File -FilePath $CloudInitPath -Encoding UTF8

        Write-Host "VM '$VMName' created successfully" -ForegroundColor Green
        Write-Host "Cloud-init config saved to: $CloudInitPath" -ForegroundColor Green

        # Note about Ubuntu ISO
        Write-Host "Note: You need to manually attach Ubuntu Server $($Config.UbuntuVersion) ISO and boot the VM" -ForegroundColor Yellow
        Write-Host "Use the cloud-init config file during installation: $CloudInitPath" -ForegroundColor Yellow

    } catch {
        Write-Error "Failed to create VM '$VMName': $_"
        throw
    }
}

# Main deployment process
try {
    Write-Host "Starting infrastructure deployment..." -ForegroundColor Green

    # Create virtual network switch
    New-K8sNetworkSwitch -SwitchName $Config.NetworkSwitch -SwitchType "Internal"

    # Create master node
    $masterName = "$($Config.ClusterName)-master"
    New-K8sVM -VMName $masterName -Role "master" -IPAddress $Config.MasterNodeIP -Config $Config

    # Create worker nodes
    for ($i = 1; $i -le $Config.WorkerNodes; $i++) {
        if ($i -eq 4) {
            $workerName = "jenkins-server"
        } else {
            $workerName = "$($Config.ClusterName)-worker-$i"
        }
        $workerIP = "$($Config.WorkerNodeIPBase)$i"
        New-K8sVM -VMName $workerName -Role "worker" -IPAddress $workerIP -Config $Config
    }

    Write-Host "`n=== Infrastructure Deployment Summary ===" -ForegroundColor Cyan
    Write-Host "Virtual Switch: $($Config.NetworkSwitch)" -ForegroundColor White
    Write-Host "Master Node: $masterName ($($Config.MasterNodeIP))" -ForegroundColor White

    for ($i = 1; $i -le $Config.WorkerNodes; $i++) {
        if ($i -eq 4) {
            $workerName = "jenkins-server"
        } else {
            $workerName = "$($Config.ClusterName)-worker-$i"
        }
        $workerIP = "$($Config.WorkerNodeIPBase)$i"
        Write-Host "Worker Node: $workerName ($workerIP)" -ForegroundColor White
    }

    Write-Host "`n=== Next Steps ===" -ForegroundColor Green
    Write-Host "1. Download Ubuntu Server $($Config.UbuntuVersion) ISO to $($Config.ISOPath)" -ForegroundColor Yellow
    Write-Host "2. Start each VM and attach the Ubuntu ISO" -ForegroundColor Yellow
    Write-Host "3. Install Ubuntu using the generated cloud-init configurations" -ForegroundColor Yellow
    Write-Host "4. After all VMs are running, execute the security hardening script on each VM" -ForegroundColor Yellow

    Write-Host "`n=== Infrastructure deployment completed successfully! ===" -ForegroundColor Green

} catch {
    Write-Error "Infrastructure deployment failed: $_"
    exit 1
}