#!/bin/bash
# Fix CRLF jika file dari Google Drive / Windows
sed -i 's/\r$//' "${BASH_SOURCE[0]}" 2>/dev/null || true
set -euo pipefail

# ==============================================================================
# WAZUH ALL-IN-ONE AUTO INSTALLER
# PRE-RUN: Jika script error "/bin/bash^M: bad interpreter", jalankan dulu:
#   sed -i 's/\r$//' install-wazuh-manager.sh
# Ubuntu Server 22.04 / 24.04
# VirtualBox Local Lab Edition
#
# Usage:
#   sudo bash install-wazuh-manager.sh
#
# What this does:
#   1. Install Wazuh Manager + Indexer + Dashboard (AIO)
#   2. Deploy DFX custom decoders, base rules, CVE rules, ossec.conf
#   3. Configure firewall (ufw)
#   4. Validate rules & restart manager
#   5. Print credentials & dashboard URL
#
# Expected folder structure (relative to this script):
#   deploy/
#   ├── install-wazuh-manager.sh     ← this script
#   ├── ossec-manager.conf
#   ├── decoder/
#   │   ├── linux-auditd.xml
#   │   └── linux-sysmon.xml
#   └── rules/
#       ├── 00_linux-auditd.xml
#       ├── 00_linux-sysmon-base-rules.xml
#       ├── 00_linux_sysmon-threat-detection.xml
#       └── 00_windows-sysmon.xml
#   ../../../wazuh-suricata-custom-rules/
#   ├── decoders/*.xml
#   └── rules/wazuh/*.xml
#
# Last updated: 2026-05-16
# ==============================================================================

# =========================
# CONFIGURATION
# =========================
WAZUH_VERSION="4.14"  # Change this when upgrading (current: 4.14.5)
LOG_FILE="/var/log/wazuh-install-$(date +%Y%m%d-%H%M%S).log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAZUH_DIR="/var/ossec"

# =========================
# WARNA TERMINAL
# =========================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Log everything
exec > >(tee -a "$LOG_FILE") 2>&1

clear

echo -e "${CYAN}"
echo "========================================================"
echo "         WAZUH AIO INSTALLER - LOCAL LAB"
echo "         Version: Wazuh ${WAZUH_VERSION}"
echo "========================================================"
echo -e "${NC}"
echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"

# =========================
# VALIDASI ROOT
# =========================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Jalankan script menggunakan sudo/root.${NC}"
    echo ""
    echo "Contoh:"
    echo "sudo bash install-wazuh.sh"
    exit 1
fi

# =========================
# PRE-FLIGHT CHECKS
# =========================
echo -e "${YELLOW}[1/12] Pre-flight checks...${NC}"

# --- RAM ---
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 3500 ]; then
    echo -e "${RED}[CRITICAL] RAM hanya ${TOTAL_RAM} MB — minimal 4GB untuk Wazuh AIO.${NC}"
    echo -e "${YELLOW}OpenSearch akan crash jika RAM < 4GB.${NC}"
    read -p "Lanjutkan paksa? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
elif [ "$TOTAL_RAM" -lt 6000 ]; then
    echo -e "${YELLOW}[WARNING] RAM ${TOTAL_RAM} MB — disarankan 8GB.${NC}"
else
    echo -e "${GREEN}[OK] RAM: ${TOTAL_RAM} MB${NC}"
fi

# --- Disk ---
AVAIL_DISK=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "$AVAIL_DISK" -lt 10 ]; then
    echo -e "${RED}[CRITICAL] Disk hanya ${AVAIL_DISK}GB free — minimal 15GB!${NC}"
    read -p "Lanjutkan paksa? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
elif [ "$AVAIL_DISK" -lt 15 ]; then
    echo -e "${YELLOW}[WARNING] Disk ${AVAIL_DISK}GB — disarankan 15-20GB free.${NC}"
else
    echo -e "${GREEN}[OK] Disk: ${AVAIL_DISK}GB free${NC}"
fi

# --- Internet / DNS ---
if ! ping -c 1 -W 3 packages.wazuh.com &>/dev/null; then
    if ! curl -s --max-time 5 https://packages.wazuh.com >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Tidak bisa reach packages.wazuh.com${NC}"
        echo -e "${YELLOW}Cek: internet, DNS (/etc/resolv.conf), firewall outbound.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK] Internet: packages.wazuh.com reachable${NC}"

# --- Port 443 ---
if ss -tlnp | grep -q ":443 " 2>/dev/null; then
    PORT443_PROC=$(ss -tlnp | grep ":443 " | awk '{print $NF}')
    echo -e "${RED}[WARNING] Port 443 sudah dipakai: ${PORT443_PROC}${NC}"
    echo -e "${YELLOW}Wazuh Dashboard butuh port 443. Service lain harus di-stop.${NC}"
    read -p "Stop service di port 443 dan lanjutkan? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Kill whatever is on 443
        fuser -k 443/tcp 2>/dev/null || true
        sleep 2
        echo -e "${GREEN}[OK] Port 443 freed.${NC}"
    else
        exit 1
    fi
else
    echo -e "${GREEN}[OK] Port 443: available${NC}"
fi

# --- Time sync ---
if command -v timedatectl &>/dev/null; then
    NTP_SYNC=$(timedatectl | grep -i "synchronized" | grep -c "yes" || echo "0")
    if [ "$NTP_SYNC" = "0" ]; then
        echo -e "${YELLOW}[WARNING] NTP not synced — fixing...${NC}"
        timedatectl set-ntp true 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || true
        sleep 2
    fi
    echo -e "${GREEN}[OK] Time: $(date)${NC}"
fi

# --- CPU cores ---
CPU_CORES=$(nproc)
if [ "$CPU_CORES" -lt 2 ]; then
    echo -e "${YELLOW}[WARNING] CPU cores: ${CPU_CORES} — disarankan minimal 2.${NC}"
else
    echo -e "${GREEN}[OK] CPU: ${CPU_CORES} cores${NC}"
fi

# --- Swap (prevent OOM kill during install) ---
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
if [ "$SWAP_TOTAL" -lt 1024 ]; then
    echo -e "${YELLOW}[FIX] Swap hanya ${SWAP_TOTAL}MB — membuat 4GB swap...${NC}"
    # Remove old swap file if exists
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile 2>/dev/null || true
    # Create 4GB swap
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    # Persist across reboot
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    # Optimize swappiness for server
    sysctl vm.swappiness=10
    sed -i '/vm.swappiness/d' /etc/sysctl.conf
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    NEW_SWAP=$(free -m | awk '/^Swap:/{print $2}')
    echo -e "${GREEN}[OK] Swap: ${NEW_SWAP}MB (prevents OpenSearch OOM kill)${NC}"
else
    echo -e "${GREEN}[OK] Swap: ${SWAP_TOTAL}MB${NC}"
fi

# =========================
# STOP UNATTENDED-UPGRADES & FREE APT LOCK
# =========================
echo -e "\n${YELLOW}[2/12] Stop unattended-upgrades & free APT lock...${NC}"

# Stop unattended-upgrades service
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true

# Kill any remaining apt/dpkg processes
killall -9 unattended-upgr 2>/dev/null || true
killall -9 apt-get 2>/dev/null || true
killall -9 dpkg 2>/dev/null || true

# Remove stale lock files
rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm -f /var/lib/apt/lists/lock 2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true

# Fix dpkg if interrupted
dpkg --configure -a 2>/dev/null || true

# Wait until truly free
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo -e "${YELLOW}  Waiting for dpkg lock...${NC}"
    sleep 3
done

# Disable needrestart interactive prompts (prevents install hang)
export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive
if [ -f /etc/needrestart/needrestart.conf ]; then
    sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

echo -e "${GREEN}[OK] APT lock free, unattended-upgrades & needrestart disabled.${NC}"

# =========================
# FIX UBUNTU CDROM REPO
# =========================
echo -e "\n${YELLOW}[3/12] Membersihkan repository CD-ROM Ubuntu...${NC}"

if grep -q "cdrom" /etc/apt/sources.list 2>/dev/null; then
    sed -i '/cdrom/d' /etc/apt/sources.list
    echo -e "${GREEN}[OK] Repository CD-ROM dihapus.${NC}"
else
    echo -e "${GREEN}[OK] Repository CD-ROM tidak ditemukan.${NC}"
fi

# =========================
# UPDATE SYSTEM
# =========================
echo -e "\n${YELLOW}[4/12] Update repository sistem...${NC}"

apt clean
apt update --fix-missing -y

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] apt update gagal.${NC}"
    exit 1
fi

# =========================
# INSTALL DEPENDENCIES
# =========================
echo -e "\n${YELLOW}[5/12] Install dependency dasar...${NC}"

apt install -y \
curl \
wget \
tar \
unzip \
gnupg \
dos2unix \
apt-transport-https \
software-properties-common

# =========================
# CONFIG vm.max_map_count
# =========================
echo -e "\n${YELLOW}[6/12] Konfigurasi vm.max_map_count...${NC}"

CURRENT_MAX_MAP=$(sysctl -n vm.max_map_count 2>/dev/null)

if [ "$CURRENT_MAX_MAP" != "262144" ]; then

    sysctl -w vm.max_map_count=262144

    sed -i '/vm.max_map_count/d' /etc/sysctl.conf
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf

    echo -e "${GREEN}[OK] vm.max_map_count berhasil diatur.${NC}"

else
    echo -e "${GREEN}[OK] vm.max_map_count sudah sesuai.${NC}"
fi

# =========================
# DOWNLOAD INSTALLER
# =========================
echo -e "\n${YELLOW}[7/12] Mengunduh Wazuh installer resmi...${NC}"

cd /root || exit 1

rm -f wazuh-install.sh

WAZUH_URL="https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh"

echo -e "${CYAN}URL: ${WAZUH_URL}${NC}"
curl -# -L "$WAZUH_URL" -o wazuh-install.sh

# =========================
# VALIDASI DOWNLOAD
# =========================
if [ ! -f wazuh-install.sh ]; then
    echo -e "${RED}[ERROR] File installer gagal diunduh.${NC}"
    exit 1
fi

FILE_SIZE=$(stat -c%s wazuh-install.sh)

if [ "$FILE_SIZE" -lt 1000 ]; then
    echo -e "${RED}[ERROR] Ukuran file installer tidak valid.${NC}"
    echo -e "${YELLOW}Kemungkinan download gagal / terkena HTML error.${NC}"
    head wazuh-install.sh
    exit 1
fi

dos2unix wazuh-install.sh >/dev/null 2>&1

FIRST_LINE=$(head -n 1 wazuh-install.sh)

if ! echo "$FIRST_LINE" | grep -q "bash"; then
    echo -e "${RED}[ERROR] File hasil download bukan bash script.${NC}"
    echo ""
    echo -e "${YELLOW}Isi awal file:${NC}"
    head wazuh-install.sh
    exit 1
fi

chmod +x wazuh-install.sh

echo -e "${GREEN}[OK] Installer berhasil diverifikasi.${NC}"

# =========================
# JALANKAN INSTALLER
# =========================
echo -e "\n${YELLOW}[8/12] Menjalankan instalasi Wazuh All-in-One...${NC}"
echo -e "${CYAN}Proses ini dapat memakan waktu 10-30 menit.${NC}"
echo -e "${CYAN}Wazuh version: ${WAZUH_VERSION}${NC}"

# Wait for APT lock to be released (prevent conflict with step 4)
echo -e "${CYAN}Waiting for APT lock...${NC}"
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
      fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 2
done
echo -e "${GREEN}[OK] APT lock free.${NC}"

# Remove previous failed installation if exists
if dpkg -l | grep -q "wazuh-indexer\|wazuh-manager\|wazuh-dashboard"; then
    echo -e "${YELLOW}Detected previous Wazuh install — removing...${NC}"
    systemctl stop wazuh-manager wazuh-indexer wazuh-dashboard filebeat 2>/dev/null || true
    apt-get remove --purge wazuh-indexer wazuh-manager wazuh-dashboard filebeat -y 2>/dev/null || true
    rm -rf /var/ossec /etc/wazuh-indexer /etc/filebeat /usr/share/wazuh-indexer /usr/share/wazuh-dashboard 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/wazuh.list 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    echo -e "${GREEN}[OK] Previous install removed.${NC}"
fi

bash wazuh-install.sh -a -i || true

# =========================
# FIREWALL
# =========================
echo -e "\n${YELLOW}[9/12] Konfigurasi firewall...${NC}"

if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment "SSH" 2>/dev/null || true
    ufw allow 1514/tcp comment "Wazuh agent" 2>/dev/null || true
    ufw allow 1515/tcp comment "Wazuh registration" 2>/dev/null || true
    ufw allow 443/tcp comment "Wazuh dashboard" 2>/dev/null || true
    ufw allow 9200/tcp comment "Wazuh indexer API" 2>/dev/null || true
    echo -e "${GREEN}[OK] UFW rules ditambahkan (22, 1514, 1515, 443, 9200).${NC}"
else
    echo -e "${YELLOW}[SKIP] ufw tidak tersedia.${NC}"
fi

# iptables backup (cloud VPS sometimes ignores ufw)
for PORT in 22 1514 1515 443 9200; do
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
done
echo -e "${GREEN}[OK] iptables rules ditambahkan (backup).${NC}"

# =========================
# CEK HASIL INSTALL
# =========================
echo -e "\n${YELLOW}[10/12] Memeriksa hasil instalasi...${NC}"

if ! systemctl is-active --quiet wazuh-manager 2>/dev/null; then
    echo -e "${RED}"
    echo "========================================================"
    echo "        INSTALASI GAGAL"
    echo "========================================================"
    echo -e "${NC}"

    echo -e "${YELLOW}Status service:${NC}"
    systemctl status wazuh-manager --no-pager 2>/dev/null | head -10
    systemctl status wazuh-indexer --no-pager 2>/dev/null | head -10

    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "  1. Cek log: journalctl -u wazuh-manager -n 50"
    echo "  2. Cek indexer: journalctl -u wazuh-indexer -n 50"
    echo "  3. Cek disk: df -h /"
    echo "  4. Cek RAM: free -h"
    echo "  5. Full log: cat ${LOG_FILE}"
    exit 1
fi

echo -e "${GREEN}[OK] Wazuh manager aktif.${NC}"

# =========================
# DEPLOY CUSTOM CONFIGS
# =========================
echo -e "\n${YELLOW}[11/12] Deploy DFX custom decoders, rules, ossec.conf...${NC}"

RULES_DST="${WAZUH_DIR}/etc/rules"
DECODER_DST="${WAZUH_DIR}/etc/decoders"
CUSTOM_RULES_SRC="${SCRIPT_DIR}/../../../wazuh-suricata-custom-rules"
DEPLOYED=0

# --- 1. Decoders from deploy/decoder/ ---
if [ -d "${SCRIPT_DIR}/decoder" ]; then
    echo -e "${CYAN}  [decoder] deploy/decoder/ → ${DECODER_DST}/${NC}"
    for f in "${SCRIPT_DIR}/decoder/"*.xml; do
        [ -f "$f" ] || continue
        cp -v "$f" "$DECODER_DST/"
        ((DEPLOYED++)) || true
    done
fi

# --- 2. Decoders from wazuh-suricata-custom-rules/decoders/ ---
if [ -d "${CUSTOM_RULES_SRC}/decoders" ]; then
    echo -e "${CYAN}  [decoder] wazuh-suricata-custom-rules/decoders/ → ${DECODER_DST}/${NC}"
    for f in "${CUSTOM_RULES_SRC}/decoders/"*.xml; do
        [ -f "$f" ] || continue
        cp -v "$f" "$DECODER_DST/"
        ((DEPLOYED++)) || true
    done
fi

# --- 3. Base rules from deploy/rules/ (00_* files) ---
if [ -d "${SCRIPT_DIR}/rules" ]; then
    echo -e "${CYAN}  [rules]   deploy/rules/00_* → ${RULES_DST}/${NC}"
    for f in "${SCRIPT_DIR}/rules/"00_*.xml; do
        [ -f "$f" ] || continue
        cp -v "$f" "$RULES_DST/"
        ((DEPLOYED++)) || true
    done
fi

# --- 4. Custom rules from wazuh-suricata-custom-rules/rules/wazuh/ ---
if [ -d "${CUSTOM_RULES_SRC}/rules/wazuh" ]; then
    echo -e "${CYAN}  [rules]   wazuh-suricata-custom-rules/rules/wazuh/ → ${RULES_DST}/${NC}"
    for f in "${CUSTOM_RULES_SRC}/rules/wazuh/"*.xml; do
        [ -f "$f" ] || continue
        cp -v "$f" "$RULES_DST/"
        ((DEPLOYED++)) || true
    done
fi

# --- 5. Custom ossec.conf ---
if [ -f "${SCRIPT_DIR}/ossec-manager.conf" ]; then
    echo -e "${CYAN}  [config]  ossec-manager.conf → ${WAZUH_DIR}/etc/ossec.conf${NC}"
    cp "${WAZUH_DIR}/etc/ossec.conf" "${WAZUH_DIR}/etc/ossec.conf.bak-$(date +%s)"
    cp "${SCRIPT_DIR}/ossec-manager.conf" "${WAZUH_DIR}/etc/ossec.conf"
    ((DEPLOYED++)) || true
    echo -e "${GREEN}[OK] ossec.conf deployed (backup created).${NC}"
fi

echo -e "${GREEN}[OK] ${DEPLOYED} files deployed.${NC}"

# --- 6. Enable Filebeat archives (index ALL logs, not just alerts) ---
FILEBEAT_YML="/etc/filebeat/filebeat.yml"
if [ -f "$FILEBEAT_YML" ]; then
    if grep -q "archives:" "$FILEBEAT_YML"; then
        # Change archives: enabled: false → true
        sed -i '/archives:/,/enabled:/{s/enabled: false/enabled: true/}' "$FILEBEAT_YML"
        echo -e "${GREEN}[OK] Filebeat archives enabled (wazuh-archives-* index aktif).${NC}"
        systemctl restart filebeat 2>/dev/null || true
    else
        echo -e "${YELLOW}[SKIP] archives section tidak ditemukan di filebeat.yml${NC}"
    fi
else
    echo -e "${YELLOW}[SKIP] filebeat.yml tidak ditemukan.${NC}"
fi

# Set permissions
chown -R wazuh:wazuh "$RULES_DST" "$DECODER_DST" 2>/dev/null || true
chmod 660 "$RULES_DST"/*.xml "$DECODER_DST"/*.xml 2>/dev/null || true
chown wazuh:wazuh "${WAZUH_DIR}/etc/ossec.conf" 2>/dev/null || true

# =========================
# VALIDATE & RESTART
# =========================
echo -e "\n${YELLOW}[12/12] Validasi rules & restart manager...${NC}"

if ${WAZUH_DIR}/bin/wazuh-analysisd -t 2>&1 | grep -qi "error"; then
    echo -e "${RED}[ERROR] Rule validation failed!${NC}"
    ${WAZUH_DIR}/bin/wazuh-analysisd -t
    echo -e "${YELLOW}Restoring ossec.conf backup...${NC}"
    LATEST_BAK=$(ls -t "${WAZUH_DIR}/etc/ossec.conf.bak-"* 2>/dev/null | head -1)
    if [ -n "$LATEST_BAK" ]; then
        cp "$LATEST_BAK" "${WAZUH_DIR}/etc/ossec.conf"
        echo -e "${YELLOW}Backup restored: ${LATEST_BAK}${NC}"
    fi
else
    echo -e "${GREEN}[OK] Rules validated successfully.${NC}"
    systemctl restart wazuh-manager
    echo -e "${GREEN}[OK] Wazuh manager restarted.${NC}"
fi

# =========================
# FINAL SUMMARY
# =========================
PRIVATE_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "$PRIVATE_IP")
IP_ADDR="${PUBLIC_IP}"

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  INSTALASI & DEPLOY SELESAI!${NC}"
echo -e "${GREEN}========================================================${NC}"

echo -e "${CYAN}Credential Login:${NC}"
echo "--------------------------------------------------------"
if [ -f "/root/wazuh-install-files.tar" ]; then
    tar -axf /root/wazuh-install-files.tar \
        wazuh-install-files/wazuh-passwords.txt -O 2>/dev/null
else
    echo -e "${YELLOW}Password file tidak ditemukan. Cek /root/ manual.${NC}"
fi
echo "--------------------------------------------------------"

echo ""
echo -e "${YELLOW}Dashboard:${NC}  https://${IP_ADDR}"
echo -e "${YELLOW}Deployed:${NC}   ${DEPLOYED} files (decoders + rules + config)"
echo ""
echo -e "${CYAN}IP Info:${NC}"
echo "  Private: ${PRIVATE_IP}"
echo "  Public:  ${PUBLIC_IP}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Login dashboard: https://${PUBLIC_IP}"
echo "  2. Register agent:  /var/ossec/bin/manage_agents"
echo "  3. Deploy ke agent: audit.rules + ossec-agent-linux.conf"
echo "  4. Pastikan cloud firewall allow port 1514, 1515 TCP!"
echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"