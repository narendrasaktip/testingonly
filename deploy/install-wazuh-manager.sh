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
# CEK RAM & DISK
# =========================
echo -e "${YELLOW}[1/9] Mengecek spesifikasi sistem...${NC}"

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
AVAIL_DISK=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

if [ "$TOTAL_RAM" -lt 6000 ]; then
    echo -e "${RED}[WARNING] RAM kurang dari 6GB (${TOTAL_RAM} MB).${NC}"
    echo -e "${YELLOW}Disarankan minimal 8GB untuk OpenSearch/Wazuh.${NC}"
    read -p "Lanjutkan? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
else
    echo -e "${GREEN}[OK] RAM mencukupi (${TOTAL_RAM} MB).${NC}"
fi

if [ "$AVAIL_DISK" -lt 15 ]; then
    echo -e "${RED}[WARNING] Disk tersedia kurang dari 15GB (${AVAIL_DISK}GB).${NC}"
    echo -e "${YELLOW}OpenSearch indexing membutuhkan minimal 15-20GB free.${NC}"
    read -p "Lanjutkan? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
else
    echo -e "${GREEN}[OK] Disk mencukupi (${AVAIL_DISK}GB free).${NC}"
fi

# =========================
# FIX UBUNTU CDROM REPO
# =========================
echo -e "\n${YELLOW}[2/9] Membersihkan repository CD-ROM Ubuntu...${NC}"

if grep -q "cdrom" /etc/apt/sources.list 2>/dev/null; then
    sed -i '/cdrom/d' /etc/apt/sources.list
    echo -e "${GREEN}[OK] Repository CD-ROM dihapus.${NC}"
else
    echo -e "${GREEN}[OK] Repository CD-ROM tidak ditemukan.${NC}"
fi

# =========================
# UPDATE SYSTEM
# =========================
echo -e "\n${YELLOW}[3/9] Update repository sistem...${NC}"

apt clean
apt update --fix-missing -y

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] apt update gagal.${NC}"
    exit 1
fi

# =========================
# INSTALL DEPENDENCIES
# =========================
echo -e "\n${YELLOW}[4/9] Install dependency dasar...${NC}"

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
echo -e "\n${YELLOW}[5/9] Konfigurasi vm.max_map_count...${NC}"

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
echo -e "\n${YELLOW}[6/9] Mengunduh Wazuh installer resmi...${NC}"

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
echo -e "\n${YELLOW}[7/11] Menjalankan instalasi Wazuh All-in-One...${NC}"
echo -e "${CYAN}Proses ini dapat memakan waktu 10-30 menit.${NC}"
echo -e "${CYAN}Wazuh version: ${WAZUH_VERSION}${NC}"

bash wazuh-install.sh -a -i || true

# =========================
# FIREWALL
# =========================
echo -e "\n${YELLOW}[8/11] Konfigurasi firewall...${NC}"

if command -v ufw &>/dev/null; then
    ufw allow 1514/tcp comment "Wazuh agent" 2>/dev/null || true
    ufw allow 1515/tcp comment "Wazuh registration" 2>/dev/null || true
    ufw allow 443/tcp comment "Wazuh dashboard" 2>/dev/null || true
    ufw allow 9200/tcp comment "Wazuh indexer API" 2>/dev/null || true
    echo -e "${GREEN}[OK] Firewall rules ditambahkan (1514, 1515, 443, 9200).${NC}"
else
    echo -e "${YELLOW}[SKIP] ufw tidak tersedia — pastikan port 1514, 1515, 443 terbuka.${NC}"
fi

# =========================
# CEK HASIL INSTALL
# =========================
echo -e "\n${YELLOW}[9/11] Memeriksa hasil instalasi...${NC}"

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
echo -e "\n${YELLOW}[10/11] Deploy DFX custom decoders, rules, ossec.conf...${NC}"

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

# Set permissions
chown -R wazuh:wazuh "$RULES_DST" "$DECODER_DST" 2>/dev/null || true
chmod 660 "$RULES_DST"/*.xml "$DECODER_DST"/*.xml 2>/dev/null || true
chown wazuh:wazuh "${WAZUH_DIR}/etc/ossec.conf" 2>/dev/null || true

# =========================
# VALIDATE & RESTART
# =========================
echo -e "\n${YELLOW}[11/11] Validasi rules & restart manager...${NC}"

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
IP_ADDR=$(hostname -I | awk '{print $1}')

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
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Login dashboard: https://${IP_ADDR}"
echo "  2. Register agent:  /var/ossec/bin/manage_agents"
echo "  3. Deploy ke agent: audit.rules + ossec-agent-linux.conf"
echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"