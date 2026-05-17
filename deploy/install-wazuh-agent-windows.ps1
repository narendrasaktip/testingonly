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

# =============================================================================
# LOG COLLECTION FUNCTIONS
# =============================================================================

function Get-LogBlock {
    param([string[]]$Channels)
    $xml = ""
    foreach ($ch in $Channels) {
        $xml += @"

  <localfile>
    <location>$ch</location>
    <log_format>eventchannel</log_format>
  </localfile>
"@
    }
    return $xml
}

function Add-LogChannels {
    param([string]$ConfPath, [string[]]$Channels, [string]$Label)
    $block = "`n  <!-- ========== SMART: $Label ========== -->"
    $block += Get-LogBlock -Channels $Channels
    $content = Get-Content -Path $ConfPath -Raw
    $content = $content -replace "</ossec_config>", "$block`n`n</ossec_config>"
    Set-Content -Path $ConfPath -Value $content -Encoding UTF8
    Write-OK "$Label — $($Channels.Count) channels enabled."
}

function Configure-LogCollection {
    param([string]$ConfPath)

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  LOG COLLECTION MODE" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) Template  - Default channels saja (Sysmon, Security, dll)"
    Write-Host "  2) All       - Enable semua commented channels"
    Write-Host "  3) Auto      - Detect installed roles & enable matching"
    Write-Host "  4) Custom    - Pilih kategori manual"
    Write-Host ""
    $mode = Read-Host "Pilih mode [1-4, default=1]"
    if ([string]::IsNullOrEmpty($mode)) { $mode = "1" }

    switch ($mode) {
        "2" { LogCollect-All -ConfPath $ConfPath }
        "3" { LogCollect-AutoDetect -ConfPath $ConfPath }
        "4" { LogCollect-Custom -ConfPath $ConfPath }
        default { Write-OK "Template mode — default channels only." }
    }
}

function LogCollect-All {
    param([string]$ConfPath)
    # Uncomment ALL commented <localfile> blocks
    $content = Get-Content -Path $ConfPath -Raw
    # Remove XML comment markers around localfile blocks
    $pattern = '<!--\s*((?:<localfile>[\s\S]*?</localfile>\s*)+)\s*-->'
    $content = [regex]::Replace($content, $pattern, '$1')
    Set-Content -Path $ConfPath -Value $content -Encoding UTF8
    Write-OK "All mode — semua commented channels di-enable."
    Write-Warn "Volume bisa tinggi! Monitor event/sec di manager."
}

function LogCollect-AutoDetect {
    param([string]$ConfPath)
    $detected = @()

    Write-Info "Scanning installed roles & features..."

    # Check for Windows Server roles (Get-WindowsFeature only on Server OS)
    $isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1

    if ($isServer) {
        try {
            $features = Get-WindowsFeature -ErrorAction SilentlyContinue | Where-Object { $_.Installed }
            $featureNames = $features.Name

            # DHCP Server
            if ($featureNames -contains "DHCP") {
                Write-Info "[+] DHCP Server detected"
                $detected += "DhcpAdminEvents"
                $detected += "Microsoft-Windows-Dhcp-Server/Operational"
            }

            # AD Certificate Services
            if ($featureNames -contains "ADCS-Cert-Authority" -or $featureNames -contains "AD-Certificate") {
                Write-Info "[+] AD Certificate Services detected"
                $detected += "Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational"
            }

            # File Server / SMB
            if ($featureNames -contains "FS-FileServer") {
                Write-Info "[+] File Server role detected"
                $detected += "Microsoft-Windows-SMBServer/Operational"
            }

            # ADFS
            if ($featureNames -contains "ADFS-Federation") {
                Write-Info "[+] AD FS detected"
                $detected += "AD FS/Admin"
            }

            # DFS Replication
            if ($featureNames -contains "FS-DFS-Replication") {
                Write-Info "[+] DFS Replication detected"
                $detected += "DFS Replication"
            }

            # NPS / RADIUS
            if ($featureNames -contains "NPAS") {
                Write-Info "[+] Network Policy Server detected"
                $detected += "Microsoft-Windows-NetworkPolicy/Operational"
            }

            # Hyper-V
            if ($featureNames -contains "Hyper-V") {
                Write-Info "[+] Hyper-V detected"
                $detected += "Microsoft-Windows-Hyper-V-VMMS-Admin"
            }

            # IIS
            if ($featureNames -contains "Web-Server") {
                Write-Info "[+] IIS Web Server detected"
                $detected += "Microsoft-Windows-IIS-Logging/Operational"
            }
        } catch {
            Write-Warn "Get-WindowsFeature gagal: $($_.Exception.Message)"
        }
    }

    # Universal checks (works on workstation + server)
    # Print Spooler running = PrintNightmare risk
    $spooler = Get-Service -Name "Spooler" -ErrorAction SilentlyContinue
    if ($spooler -and $spooler.Status -eq "Running") {
        Write-Info "[+] Print Spooler running (PrintNightmare risk)"
        # Already in template, just note it
    }

    # WinRM enabled
    $winrm = Get-Service -Name "WinRM" -ErrorAction SilentlyContinue
    if ($winrm -and $winrm.Status -eq "Running") {
        Write-Info "[+] WinRM active — lateral movement channel already in template"
    }

    # Docker
    $docker = Get-Service -Name "docker" -ErrorAction SilentlyContinue
    if ($docker) {
        Write-Info "[+] Docker detected"
        $detected += "Microsoft-Windows-Containers-Wcifs/Operational"
    }

    # AppLocker (check if policies exist)
    $applockerPolicy = Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2" -ErrorAction SilentlyContinue
    if ($applockerPolicy) {
        Write-Info "[+] AppLocker policies detected"
        $detected += "Microsoft-Windows-AppLocker/EXE and DLL"
        $detected += "Microsoft-Windows-AppLocker/MSI and Script"
    }

    if ($detected.Count -gt 0) {
        Add-LogChannels -ConfPath $ConfPath -Channels $detected -Label "Auto-detected roles"
    } else {
        Write-OK "No additional roles detected — template is sufficient."
    }
}

function LogCollect-Custom {
    param([string]$ConfPath)
    $selected = @()

    Write-Host ""
    Write-Host "Pilih kategori (pisah koma, contoh: 1,3,5):" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   1) DHCP Server        - IP-MAC leases, rogue device"
    Write-Host "   2) AD Cert Services   - ESC1-ESC8, certifried"
    Write-Host "   3) File Server / SMB  - Share access tracking"
    Write-Host "   4) AD FS              - Golden SAML, federation"
    Write-Host "   5) DFS Replication    - Multi-DC SYSVOL sync"
    Write-Host "   6) NPS / RADIUS       - Network auth"
    Write-Host "   7) Hyper-V            - VM management events"
    Write-Host "   8) IIS Web Server     - Web request logging"
    Write-Host "   9) Docker/Container   - Container lifecycle"
    Write-Host "  10) AppLocker          - Application whitelist"
    Write-Host "  11) DNS Client         - DNS query logging"
    Write-Host "  12) SMB Client         - Outbound SMB (lateral movement)"
    Write-Host "  13) KDC Operational    - Kerberos Key Distribution"
    Write-Host ""
    $choices = Read-Host "Kategori"

    $cats = $choices -split "," | ForEach-Object { $_.Trim() }
    foreach ($c in $cats) {
        switch ($c) {
            "1" {
                $selected += "DhcpAdminEvents"
                $selected += "Microsoft-Windows-Dhcp-Server/Operational"
                Write-Info "[+] DHCP Server"
            }
            "2" {
                $selected += "Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational"
                Write-Info "[+] AD Certificate Services"
            }
            "3" {
                $selected += "Microsoft-Windows-SMBServer/Operational"
                Write-Info "[+] File Server / SMB"
            }
            "4" {
                $selected += "AD FS/Admin"
                Write-Info "[+] AD FS"
            }
            "5" {
                $selected += "DFS Replication"
                Write-Info "[+] DFS Replication"
            }
            "6" {
                $selected += "Microsoft-Windows-NetworkPolicy/Operational"
                Write-Info "[+] NPS / RADIUS"
            }
            "7" {
                $selected += "Microsoft-Windows-Hyper-V-VMMS-Admin"
                Write-Info "[+] Hyper-V"
            }
            "8" {
                $selected += "Microsoft-Windows-IIS-Logging/Operational"
                Write-Info "[+] IIS"
            }
            "9" {
                $selected += "Microsoft-Windows-Containers-Wcifs/Operational"
                Write-Info "[+] Docker/Container"
            }
            "10" {
                $selected += "Microsoft-Windows-AppLocker/EXE and DLL"
                $selected += "Microsoft-Windows-AppLocker/MSI and Script"
                Write-Info "[+] AppLocker"
            }
            "11" {
                $selected += "Microsoft-Windows-DNS-Client/Operational"
                Write-Info "[+] DNS Client"
            }
            "12" {
                $selected += "Microsoft-Windows-SMBClient/Operational"
                Write-Info "[+] SMB Client"
            }
            "13" {
                $selected += "Microsoft-Windows-Kerberos-Key-Distribution-Center/Operational"
                Write-Info "[+] KDC Operational"
            }
            default {
                Write-Warn "Kategori '$c' tidak dikenal — skip"
            }
        }
    }

    if ($selected.Count -gt 0) {
        Add-LogChannels -ConfPath $ConfPath -Channels $selected -Label "Custom selection"
    } else {
        Write-OK "No categories selected — using template."
    }
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

    # Test connectivity to manager
    Write-Info "Testing koneksi ke manager..."
    try {
        $tcp1514 = Test-NetConnection -ComputerName $ManagerIP -Port 1514 -WarningAction SilentlyContinue
        if ($tcp1514.TcpTestSucceeded) {
            Write-OK "Port 1514 reachable."
        } else {
            Write-Warn "Port 1514 tidak reachable. Cek cloud firewall."
        }
        $tcp1515 = Test-NetConnection -ComputerName $ManagerIP -Port 1515 -WarningAction SilentlyContinue
        if ($tcp1515.TcpTestSucceeded) {
            Write-OK "Port 1515 reachable (auto-enrollment OK)."
        } else {
            Write-Warn "Port 1515 tidak reachable — auto-enrollment mungkin gagal."
            Write-Info "Fallback: manual register via manage_agents."
        }
    } catch {
        Write-Warn "Connectivity check gagal: $($_.Exception.Message)"
    }

    # Smart log collection configuration
    Configure-LogCollection -ConfPath $ConfDst

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
