# ==============================================================================
# WAZUH AGENT AUTO INSTALLER — Windows
# Windows 10/11 | Windows Server 2016/2019/2022
#
# Usage (Run as Administrator):
#   .\install-wazuh-agent-windows.ps1
#   .\install-wazuh-agent-windows.ps1 -ManagerIP 192.168.1.107 -AgentType dc
#
# What this does:
#   1. Install Sysmon + SwiftOnSecurity config
#   2. Install Wazuh agent + register to manager
#   3. Deploy custom ossec.conf (workstation or DC)
#   4. Start agent & verify connection
#
# Parameters:
#   -ManagerIP   : Wazuh manager IP (prompted if not provided)
#   -AgentType   : "workstation" (default) or "dc" (Domain Controller)
#
# Expected folder structure (relative to this script):
#   deploy\
#   +-- install-wazuh-agent-windows.ps1   <- this script
#   +-- ossec-agent-windows-workstation.conf
#   +-- ossec-agent-windows-dc.conf
#
# Last updated: 2026-05-16
# ==============================================================================

param(
    [string]$ManagerIP = "",
    [ValidateSet("workstation", "dc")]
    [string]$AgentType = "workstation"
)

$ErrorActionPreference = "Stop"

# =========================
# CONFIGURATION
# =========================
$WazuhVersion = "4.14.5-1"  # Match manager version
$SysmonVersion = "15.15"  # Update as needed
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = "C:\wazuh-agent-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# =========================
# COLORS & HELPERS
# =========================
function Write-Step($step, $total, $msg) {
    Write-Host "`n[$step/$total] $msg" -ForegroundColor Yellow
}
function Write-OK($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}
function Write-Warn($msg) {
    Write-Host "[WARNING] $msg" -ForegroundColor Yellow
}
function Write-Err($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
}
function Write-Info($msg) {
    Write-Host "  $msg" -ForegroundColor Cyan
}

# Start transcript
Start-Transcript -Path $LogFile -Append | Out-Null

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "     WAZUH AGENT INSTALLER - Windows" -ForegroundColor Cyan
Write-Host "     Agent type: $AgentType" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Log file: $LogFile" -ForegroundColor Yellow

# =========================
# CHECK ADMIN
# =========================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "Script harus dijalankan sebagai Administrator!"
    Write-Host "  Right-click PowerShell -> Run as Administrator"
    exit 1
}

# =========================
# INPUT MANAGER IP
# =========================
if ([string]::IsNullOrEmpty($ManagerIP)) {
    $ManagerIP = Read-Host "Masukkan IP Wazuh Manager"
    if ([string]::IsNullOrEmpty($ManagerIP)) {
        Write-Err "Manager IP tidak boleh kosong."
        exit 1
    }
}

Write-OK "Manager IP: $ManagerIP"
Write-OK "Agent type: $AgentType"

$TotalSteps = 6

# =========================
# INSTALL SYSMON
# =========================
Write-Step 1 $TotalSteps "Install Sysmon..."

$SysmonExe = "C:\Windows\Sysmon64.exe"
$SysmonInstalled = Test-Path $SysmonExe

if ($SysmonInstalled) {
    Write-OK "Sysmon sudah terinstall."
} else {
    $TempDir = "$env:TEMP\sysmon-install"
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        # Download Sysmon
        Write-Info "Download Sysmon..."
        $SysmonZip = "$TempDir\Sysmon.zip"
        Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $SysmonZip -UseBasicParsing
        Expand-Archive -Path $SysmonZip -DestinationPath $TempDir -Force

        # Download SwiftOnSecurity config
        Write-Info "Download SwiftOnSecurity Sysmon config..."
        $SysmonConfig = "$TempDir\sysmonconfig.xml"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile $SysmonConfig -UseBasicParsing

        # Install Sysmon
        Write-Info "Installing Sysmon..."
        $SysmonInstaller = "$TempDir\Sysmon64.exe"
        if (-not (Test-Path $SysmonInstaller)) {
            $SysmonInstaller = "$TempDir\Sysmon.exe"
        }

        & $SysmonInstaller -accepteula -i $SysmonConfig 2>&1 | Out-Null

        if (Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue) {
            Write-OK "Sysmon installed & running."
        } elseif (Get-Service -Name "Sysmon" -ErrorAction SilentlyContinue) {
            Write-OK "Sysmon installed & running."
        } else {
            Write-Warn "Sysmon install mungkin gagal. Cek Event Viewer."
        }
    } catch {
        Write-Warn "Sysmon install gagal: $($_.Exception.Message)"
        Write-Info "Detection tetap jalan via Security Event Log."
    } finally {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =========================
# INSTALL WAZUH AGENT
# =========================
Write-Step 2 $TotalSteps "Install Wazuh Agent..."

$WazuhDir = "C:\Program Files (x86)\ossec-agent"
$WazuhInstalled = Test-Path "$WazuhDir\wazuh-agent.exe"

if ($WazuhInstalled) {
    Write-OK "Wazuh agent sudah terinstall."
} else {
    $TempDir = "$env:TEMP\wazuh-install"
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        $MsiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVersion.msi"
        $MsiFile = "$TempDir\wazuh-agent.msi"

        Write-Info "Download Wazuh agent MSI..."
        Write-Info "URL: $MsiUrl"
        Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiFile -UseBasicParsing

        if (-not (Test-Path $MsiFile)) {
            Write-Err "Download gagal."
            exit 1
        }

        Write-Info "Installing Wazuh agent..."
        $MsiArgs = @(
            "/i", $MsiFile,
            "/qn",
            "WAZUH_MANAGER=$ManagerIP",
            "WAZUH_AGENT_GROUP=default",
            "WAZUH_REGISTRATION_SERVER=$ManagerIP"
        )
        Start-Process -FilePath "msiexec.exe" -ArgumentList $MsiArgs -Wait -NoNewWindow

        if (Test-Path "$WazuhDir\wazuh-agent.exe") {
            Write-OK "Wazuh agent terinstall."
        } else {
            Write-Err "Instalasi gagal. Cek Event Viewer > Application."
            exit 1
        }
    } catch {
        Write-Err "Install gagal: $($_.Exception.Message)"
        exit 1
    } finally {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =========================
# DEPLOY OSSEC.CONF
# =========================
Write-Step 3 $TotalSteps "Deploy custom ossec.conf ($AgentType)..."

if ($AgentType -eq "dc") {
    $ConfSrc = Join-Path $ScriptDir "ossec-agent-windows-dc.conf"
} else {
    $ConfSrc = Join-Path $ScriptDir "ossec-agent-windows-workstation.conf"
}

$ConfDst = "$WazuhDir\ossec.conf"

if (Test-Path $ConfSrc) {
    # Backup
    $BackupPath = "$ConfDst.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
    if (Test-Path $ConfDst) {
        Copy-Item -Path $ConfDst -Destination $BackupPath -Force
        Write-Info "Backup: $BackupPath"
    }

    # Copy and patch Manager IP
    $Content = Get-Content -Path $ConfSrc -Raw
    $Content = $Content -replace "MANAGER_IP", $ManagerIP
    $Content = $Content -replace "192\.168\.1\.107", $ManagerIP
    Set-Content -Path $ConfDst -Value $Content -Encoding UTF8

    Write-OK "ossec.conf deployed (type=$AgentType, manager=$ManagerIP)."
} else {
    Write-Warn "Config file tidak ditemukan: $ConfSrc"
    Write-Info "Konfigurasi manager IP manual di $ConfDst"

    # At minimum patch manager IP
    if (Test-Path $ConfDst) {
        $Content = Get-Content -Path $ConfDst -Raw
        $Content = $Content -replace "<address>.*?</address>", "<address>$ManagerIP</address>"
        Set-Content -Path $ConfDst -Value $Content -Encoding UTF8
    }
}

# =========================
# ENABLE POWERSHELL SCRIPTBLOCK LOGGING
# =========================
Write-Step 4 $TotalSteps "Enable PowerShell ScriptBlock Logging..."

try {
    $RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $RegPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
    Write-OK "PowerShell ScriptBlock Logging enabled."
} catch {
    Write-Warn "Gagal enable ScriptBlock Logging: $($_.Exception.Message)"
    Write-Info "Enable manual via GPO: Computer Config > Admin Templates > PowerShell"
}

# =========================
# START AGENT
# =========================
Write-Step 5 $TotalSteps "Start Wazuh agent..."

try {
    # Restart service
    $svc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
    if ($svc) {
        Restart-Service -Name "WazuhSvc" -Force
        Start-Sleep -Seconds 3

        $svc = Get-Service -Name "WazuhSvc"
        if ($svc.Status -eq "Running") {
            Write-OK "Wazuh agent running."
        } else {
            Write-Warn "Agent status: $($svc.Status)"
        }
    } else {
        # Try net start
        net start WazuhSvc 2>&1 | Out-Null
        Write-OK "Wazuh agent started."
    }
} catch {
    Write-Warn "Gagal start agent: $($_.Exception.Message)"
    Write-Info "Manual start: net start WazuhSvc"
}

# =========================
# VERIFY
# =========================
Write-Step 6 $TotalSteps "Verifikasi..."

Write-Host ""
Write-Host "Wazuh Agent:" -ForegroundColor Cyan
$svc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Info "Status: $($svc.Status)"
} else {
    Write-Info "Status: NOT FOUND"
}

Write-Host ""
Write-Host "Sysmon:" -ForegroundColor Cyan
$sysmonSvc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if (-not $sysmonSvc) { $sysmonSvc = Get-Service -Name "Sysmon" -ErrorAction SilentlyContinue }
if ($sysmonSvc) {
    Write-Info "Status: $($sysmonSvc.Status)"
} else {
    Write-Info "Status: not installed"
}

Write-Host ""
Write-Host "PowerShell Logging:" -ForegroundColor Cyan
$psLogging = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -ErrorAction SilentlyContinue
if ($psLogging -and $psLogging.EnableScriptBlockLogging -eq 1) {
    Write-Info "ScriptBlock Logging: enabled"
} else {
    Write-Info "ScriptBlock Logging: not configured"
}

# =========================
# SUMMARY
# =========================
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  AGENT INSTALL SELESAI!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Manager:     $ManagerIP" -ForegroundColor Yellow
Write-Host "Agent type:  $AgentType" -ForegroundColor Yellow
Write-Host "Sysmon:      $(if ($sysmonSvc) { $sysmonSvc.Status } else { 'not installed' })" -ForegroundColor Yellow
Write-Host ""
Write-Host "Jika agent belum muncul di dashboard:" -ForegroundColor Cyan
Write-Host "  1. Cek koneksi: Test-NetConnection $ManagerIP -Port 1514"
Write-Host "  2. Cek log:     Get-Content '$WazuhDir\ossec.log' -Tail 20"
Write-Host "  3. Restart:     Restart-Service WazuhSvc"
Write-Host "Log file: $LogFile" -ForegroundColor Yellow

Stop-Transcript | Out-Null
