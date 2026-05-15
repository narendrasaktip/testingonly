#!/bin/bash
# Fix CRLF jika file dari Google Drive / Windows
sed -i 's/\r$//' "${BASH_SOURCE[0]}" 2>/dev/null || true
set -euo pipefail

# ==============================================================================
# WAZUH AGENT AUTO INSTALLER — Linux
# PRE-RUN: Jika script error "/bin/bash^M: bad interpreter", jalankan dulu:
#   sed -i 's/\r$//' install-wazuh-agent-linux.sh
# Ubuntu 22.04 / 24.04 | Debian 11/12 | RHEL/Rocky/Alma 8/9
#
# Usage:
#   sudo bash install-wazuh-agent-linux.sh
#
# What this does:
#   1. Install Wazuh agent + register to manager
#   2. Install & configure auditd + baseline audit.rules
#   3. Install Sysmon for Linux (optional, if available)
#   4. Deploy custom ossec-agent-linux.conf
#   5. Start agent & verify connection
#
# Expected folder structure (relative to this script):
#   deploy/
#   ├── install-wazuh-agent-linux.sh   ← this script
#   ├── ossec-agent-linux.conf
#   └── audit.rules
#
# Last updated: 2026-05-16
# ==============================================================================

# =========================
# CONFIGURATION
# =========================
WAZUH_VERSION="4.14"  # Match manager version (current: 4.14.5)
WAZUH_MANAGER=""          # Will be prompted if empty
WAZUH_AGENT_GROUP="default"
LOG_FILE="/var/log/wazuh-agent-install-$(date +%Y%m%d-%H%M%S).log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =========================
# WARNA
# =========================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

exec > >(tee -a "$LOG_FILE") 2>&1

clear

echo -e "${CYAN}"
echo "========================================================"
echo "     WAZUH AGENT INSTALLER — Linux"
echo "     Version: Wazuh ${WAZUH_VERSION}"
echo "========================================================"
echo -e "${NC}"
echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"

# =========================
# VALIDASI ROOT
# =========================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Jalankan script menggunakan sudo/root.${NC}"
    echo "  sudo bash install-wazuh-agent-linux.sh"
    exit 1
fi

# =========================
# INPUT MANAGER IP
# =========================
if [ -z "$WAZUH_MANAGER" ]; then
    echo ""
    read -p "Masukkan IP Wazuh Manager: " WAZUH_MANAGER
    if [ -z "$WAZUH_MANAGER" ]; then
        echo -e "${RED}[ERROR] Manager IP tidak boleh kosong.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}[OK] Manager IP: ${WAZUH_MANAGER}${NC}"

# =========================
# DETECT DISTRO
# =========================
echo -e "\n${YELLOW}[1/8] Detect distribusi Linux...${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID}"
    DISTRO_VERSION="${VERSION_ID}"
else
    echo -e "${RED}[ERROR] Tidak bisa detect distribusi (/etc/os-release not found).${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Distribusi: ${DISTRO_ID} ${DISTRO_VERSION}${NC}"

# Determine package manager
if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
else
    echo -e "${RED}[ERROR] Package manager tidak dikenali (apt/yum/dnf).${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] Package manager: ${PKG_MGR}${NC}"

# =========================
# INSTALL AUDITD
# =========================
echo -e "\n${YELLOW}[2/8] Install auditd...${NC}"

if command -v auditctl &>/dev/null; then
    echo -e "${GREEN}[OK] auditd sudah terinstall.${NC}"
else
    if [ "$PKG_MGR" = "apt" ]; then
        apt-get update -qq
        apt-get install -y auditd audispd-plugins
    else
        $PKG_MGR install -y audit audit-libs
    fi
    echo -e "${GREEN}[OK] auditd terinstall.${NC}"
fi

# Enable & start auditd
systemctl enable auditd 2>/dev/null || true
systemctl start auditd 2>/dev/null || true

# =========================
# DEPLOY AUDIT.RULES
# =========================
echo -e "\n${YELLOW}[3/8] Deploy baseline audit.rules...${NC}"

AUDIT_RULES_SRC="${SCRIPT_DIR}/audit.rules"
AUDIT_RULES_DST="/etc/audit/rules.d/audit.rules"

if [ -f "$AUDIT_RULES_SRC" ]; then
    # Backup existing rules
    if [ -f "$AUDIT_RULES_DST" ]; then
        cp "$AUDIT_RULES_DST" "${AUDIT_RULES_DST}.bak-$(date +%s)"
        echo -e "${CYAN}  Backup: ${AUDIT_RULES_DST}.bak-*${NC}"
    fi

    cp "$AUDIT_RULES_SRC" "$AUDIT_RULES_DST"
    chmod 640 "$AUDIT_RULES_DST"

    # Load rules
    augenrules --load 2>/dev/null || auditctl -R "$AUDIT_RULES_DST" 2>/dev/null || true

    # Verify
    RULE_COUNT=$(auditctl -l 2>/dev/null | grep -c "key=" || echo "0")
    echo -e "${GREEN}[OK] audit.rules deployed (${RULE_COUNT} rules with keys loaded).${NC}"
else
    echo -e "${YELLOW}[SKIP] audit.rules tidak ditemukan di ${AUDIT_RULES_SRC}${NC}"
    echo -e "${YELLOW}       Download dari repo dan taruh di folder yang sama.${NC}"
fi

# =========================
# INSTALL SYSMON FOR LINUX
# =========================
echo -e "\n${YELLOW}[4/8] Install Sysmon for Linux (optional)...${NC}"

if command -v sysmon &>/dev/null; then
    echo -e "${GREEN}[OK] Sysmon sudah terinstall.${NC}"
else
    # Sysmon for Linux requires sysinternalsebpf package
    if [ "$PKG_MGR" = "apt" ]; then
        # Add Microsoft repo
        if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]; then
            wget -q https://packages.microsoft.com/config/${DISTRO_ID}/${DISTRO_VERSION}/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb 2>/dev/null
            if [ -f /tmp/packages-microsoft-prod.deb ]; then
                dpkg -i /tmp/packages-microsoft-prod.deb
                apt-get update -qq
                apt-get install -y sysmonforlinux 2>/dev/null && {
                    echo -e "${GREEN}[OK] Sysmon for Linux terinstall.${NC}"
                    # Start with default config (log to syslog)
                    sysmon -accepteula -i 2>/dev/null || true
                } || {
                    echo -e "${YELLOW}[SKIP] Sysmon install gagal — lanjut tanpa Sysmon.${NC}"
                    echo -e "${YELLOW}       Detection tetap jalan via auditd + syslog.${NC}"
                }
                rm -f /tmp/packages-microsoft-prod.deb
            else
                echo -e "${YELLOW}[SKIP] Gagal download Microsoft repo — lanjut tanpa Sysmon.${NC}"
            fi
        else
            apt-get install -y sysmonforlinux 2>/dev/null && {
                echo -e "${GREEN}[OK] Sysmon for Linux terinstall.${NC}"
                sysmon -accepteula -i 2>/dev/null || true
            } || {
                echo -e "${YELLOW}[SKIP] Sysmon install gagal.${NC}"
            }
        fi
    else
        # RHEL/CentOS — try from Microsoft repo
        rpm -q packages-microsoft-prod &>/dev/null || \
            rpm -Uvh "https://packages.microsoft.com/config/${DISTRO_ID}/${DISTRO_VERSION}/packages-microsoft-prod.rpm" 2>/dev/null || true
        $PKG_MGR install -y sysmonforlinux 2>/dev/null && {
            echo -e "${GREEN}[OK] Sysmon for Linux terinstall.${NC}"
            sysmon -accepteula -i 2>/dev/null || true
        } || {
            echo -e "${YELLOW}[SKIP] Sysmon tidak tersedia untuk distro ini.${NC}"
        }
    fi
fi

# =========================
# INSTALL WAZUH AGENT
# =========================
echo -e "\n${YELLOW}[5/8] Install Wazuh Agent...${NC}"

if [ -f /var/ossec/bin/wazuh-control ]; then
    echo -e "${GREEN}[OK] Wazuh agent sudah terinstall.${NC}"
else
    if [ "$PKG_MGR" = "apt" ]; then
        # Add Wazuh repository
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import 2>/dev/null && chmod 644 /usr/share/keyrings/wazuh.gpg
        echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
        apt-get update -qq

        WAZUH_MANAGER="${WAZUH_MANAGER}" WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP}" \
            apt-get install -y wazuh-agent
    else
        # RHEL/CentOS
        rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH 2>/dev/null || true
        cat > /etc/yum.repos.d/wazuh.repo << 'REPO'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
REPO
        WAZUH_MANAGER="${WAZUH_MANAGER}" WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP}" \
            $PKG_MGR install -y wazuh-agent
    fi

    echo -e "${GREEN}[OK] Wazuh agent terinstall.${NC}"
fi

# =========================
# DEPLOY OSSEC.CONF
# =========================
echo -e "\n${YELLOW}[6/8] Deploy custom ossec.conf...${NC}"

OSSEC_CONF_SRC="${SCRIPT_DIR}/ossec-agent-linux.conf"
OSSEC_CONF_DST="/var/ossec/etc/ossec.conf"

if [ -f "$OSSEC_CONF_SRC" ]; then
    # Backup original
    cp "$OSSEC_CONF_DST" "${OSSEC_CONF_DST}.bak-$(date +%s)" 2>/dev/null || true

    # Copy and patch manager IP
    cp "$OSSEC_CONF_SRC" "$OSSEC_CONF_DST"
    sed -i "s|192.168.1.107|${WAZUH_MANAGER}|g" "$OSSEC_CONF_DST"
    sed -i "s|MANAGER_IP|${WAZUH_MANAGER}|g" "$OSSEC_CONF_DST"

    chown root:wazuh "$OSSEC_CONF_DST"
    chmod 640 "$OSSEC_CONF_DST"

    echo -e "${GREEN}[OK] ossec.conf deployed (manager=${WAZUH_MANAGER}).${NC}"
else
    echo -e "${YELLOW}[SKIP] ossec-agent-linux.conf tidak ditemukan.${NC}"
    echo -e "${YELLOW}       Konfigurasi manager IP manual di ${OSSEC_CONF_DST}${NC}"

    # At minimum, set manager IP in existing config
    sed -i "s|<address>.*</address>|<address>${WAZUH_MANAGER}</address>|" "$OSSEC_CONF_DST" 2>/dev/null || true
fi

# =========================
# START AGENT
# =========================
echo -e "\n${YELLOW}[7/8] Start Wazuh agent...${NC}"

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent

sleep 3

if systemctl is-active --quiet wazuh-agent; then
    echo -e "${GREEN}[OK] Wazuh agent running.${NC}"
else
    echo -e "${RED}[WARNING] Agent belum aktif. Cek log:${NC}"
    echo "  journalctl -u wazuh-agent -n 20"
    echo "  cat /var/ossec/logs/ossec.log | tail -20"
fi

# =========================
# VERIFY
# =========================
echo -e "\n${YELLOW}[8/8] Verifikasi...${NC}"

echo ""
echo -e "${CYAN}Wazuh Agent:${NC}"
/var/ossec/bin/wazuh-control status 2>/dev/null || true

echo ""
echo -e "${CYAN}Auditd:${NC}"
RULE_COUNT=$(auditctl -l 2>/dev/null | grep -c "key=" || echo "0")
AUDIT_STATUS=$(systemctl is-active auditd 2>/dev/null || echo "inactive")
echo "  Status: ${AUDIT_STATUS}"
echo "  Rules with keys: ${RULE_COUNT}"

echo ""
echo -e "${CYAN}Sysmon:${NC}"
if command -v sysmon &>/dev/null; then
    echo "  Status: installed"
    systemctl is-active sysmon 2>/dev/null && echo "  Service: active" || echo "  Service: check manually"
else
    echo "  Status: not installed (detection via auditd + syslog)"
fi

# =========================
# SUMMARY
# =========================
echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  AGENT INSTALL SELESAI!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo -e "${YELLOW}Manager:${NC}     ${WAZUH_MANAGER}"
echo -e "${YELLOW}Agent ID:${NC}    $(cat /var/ossec/etc/client.keys 2>/dev/null | awk '{print $1}' | head -1 || echo 'belum registered')"
echo -e "${YELLOW}Auditd:${NC}      ${AUDIT_STATUS} (${RULE_COUNT} keyed rules)"
echo -e "${YELLOW}Sysmon:${NC}      $(command -v sysmon &>/dev/null && echo 'installed' || echo 'not installed')"
echo ""
echo -e "${CYAN}Jika agent belum muncul di dashboard:${NC}"
echo "  1. Cek koneksi: nc -zv ${WAZUH_MANAGER} 1514"
echo "  2. Cek log:     tail -20 /var/ossec/logs/ossec.log"
echo "  3. Restart:     systemctl restart wazuh-agent"
echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"
