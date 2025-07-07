# HyperV-K8s-Setup.ps1
# Initial setup and configuration for Kubernetes on Hyper-V

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "cluster-config.json"
)

# Set execution policy for script execution
Set-ExecutionPolicy RemoteSigned -Force -Scope CurrentUser

Write-Host "=== Kubernetes Hyper-V Cluster Setup ===" -ForegroundColor Cyan

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Install required PowerShell modules
Write-Host "Installing required PowerShell modules..." -ForegroundColor Yellow

$modules = @("Hyper-V")
foreach ($module in $modules) {
    if (!(Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module" -ForegroundColor Green
        Install-Module -Name $module -Force -AllowClobber
    } else {
        Write-Host "Module $module already installed" -ForegroundColor Green
    }
}

Write-Host "All required modules installed successfully" -ForegroundColor Green

# Enable Hyper-V feature if not enabled
$hyperVFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hyperVFeature.State -ne "Enabled") {
    Write-Host "Enabling Hyper-V feature..." -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    Write-Warning "Hyper-V has been enabled. A restart may be required."
}

# Define comprehensive cluster configuration
$ClusterConfig = @{
    # Cluster basic settings
    ClusterName = "k8s-cluster"
    MasterNodes = 1
    WorkerNodes = 4

    # Network configuration
    NetworkCIDR = "10.244.0.0/16"
    ServiceCIDR = "10.96.0.0/12"
    NetworkSwitch = "K8s-Internal-Switch"
    VirtualNetworkSubnet = "192.168.100.0/24"
    MasterNodeIP = "192.168.100.10"
    WorkerNodeIPBase = "192.168.100.2"

    # VM specifications
    VMMemory = 8GB
    VMProcessor = 2
    VMDiskSize = 80GB
    VMGeneration = 2

    # Software versions (stable only)
    KubernetesVersion = "v1.32"
    CRIOVersion = "v1.32"
    UbuntuVersion = "24.04.02"

    # Security settings
    EnableSecureBoot = $true
    EnableTPM = $true

    # Storage configuration
    VHDPath = "C:\Hyper-V\VHDs"
    ISOPath = "C:\Hyper-V\ISOs"

    # SSH configuration
    SSHKeyPath = "$env:USERPROFILE\.ssh\id_rsa.pub"
}

# Create necessary directories
$directories = @($ClusterConfig.VHDPath, $ClusterConfig.ISOPath)
foreach ($dir in $directories) {
    if (!(Test-Path $dir)) {
        Write-Host "Creating directory: $dir" -ForegroundColor Green
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Check for SSH key
if (!(Test-Path $ClusterConfig.SSHKeyPath)) {
    Write-Warning "SSH public key not found at $($ClusterConfig.SSHKeyPath)"
    Write-Host "Generating SSH key pair..." -ForegroundColor Yellow

    $sshDir = Split-Path $ClusterConfig.SSHKeyPath -Parent
    if (!(Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    # Generate SSH key using ssh-keygen
    $keyName = "id_rsa"
    $keyPath = Join-Path $sshDir $keyName

    if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) {
        ssh-keygen -t rsa -b 4096 -f $keyPath -N '""' -C "k8s-cluster-key"
        Write-Host "SSH key pair generated successfully" -ForegroundColor Green
    } else {
        Write-Error "ssh-keygen not found. Please install OpenSSH or generate SSH keys manually."
        exit 1
    }
}

# Read SSH public key
try {
    $SSHPublicKey = Get-Content $ClusterConfig.SSHKeyPath -Raw
    $ClusterConfig.SSHPublicKey = $SSHPublicKey.Trim()
    Write-Host "SSH public key loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to read SSH public key: $_"
    exit 1
}

# Export configuration to JSON file
try {
    $ClusterConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigFile -Encoding UTF8
    Write-Host "Cluster configuration saved to: $ConfigFile" -ForegroundColor Green
} catch {
    Write-Error "Failed to save configuration: $_"
    exit 1
}

# Display configuration summary
Write-Host "`n=== Cluster Configuration Summary ===" -ForegroundColor Cyan
Write-Host "Cluster Name: $($ClusterConfig.ClusterName)" -ForegroundColor White
Write-Host "Master Nodes: $($ClusterConfig.MasterNodes)" -ForegroundColor White
Write-Host "Worker Nodes: $($ClusterConfig.WorkerNodes)" -ForegroundColor White
Write-Host "Kubernetes Version: $($ClusterConfig.KubernetesVersion)" -ForegroundColor White
Write-Host "Network Switch: $($ClusterConfig.NetworkSwitch)" -ForegroundColor White
Write-Host "VM Memory: $($ClusterConfig.VMMemory / 1GB) GB" -ForegroundColor White
Write-Host "VM Processors: $($ClusterConfig.VMProcessor)" -ForegroundColor White
Write-Host "VM Disk Size: $($ClusterConfig.VMDiskSize / 1GB) GB" -ForegroundColor White

Write-Host "`n=== Setup completed successfully! ===" -ForegroundColor Green
Write-Host "Next step: Run Deploy-HyperV-Infrastructure.ps1" -ForegroundColor Yellow
