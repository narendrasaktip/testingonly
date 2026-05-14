#!/bin/bash

# ==============================================================================
# WAZUH ALL-IN-ONE AUTO INSTALLER
# Ubuntu Server 22.04 / 24.04
# VirtualBox Local Lab Edition
# ==============================================================================

# =========================
# WARNA TERMINAL
# =========================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear

echo -e "${CYAN}"
echo "========================================================"
echo "         WAZUH AIO INSTALLER - LOCAL LAB"
echo "========================================================"
echo -e "${NC}"

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
# CEK RAM
# =========================
echo -e "${YELLOW}[1/8] Mengecek spesifikasi RAM...${NC}"

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')

if [ "$TOTAL_RAM" -lt 6000 ]; then
    echo -e "${RED}[WARNING] RAM kurang dari 6GB.${NC}"
    echo -e "${YELLOW}Disarankan minimal 8GB untuk OpenSearch/Wazuh.${NC}"
    sleep 5
else
    echo -e "${GREEN}[OK] RAM mencukupi (${TOTAL_RAM} MB).${NC}"
fi

# =========================
# FIX UBUNTU CDROM REPO
# =========================
echo -e "\n${YELLOW}[2/8] Membersihkan repository CD-ROM Ubuntu...${NC}"

if grep -q "cdrom" /etc/apt/sources.list 2>/dev/null; then
    sed -i '/cdrom/d' /etc/apt/sources.list
    echo -e "${GREEN}[OK] Repository CD-ROM dihapus.${NC}"
else
    echo -e "${GREEN}[OK] Repository CD-ROM tidak ditemukan.${NC}"
fi

# =========================
# UPDATE SYSTEM
# =========================
echo -e "\n${YELLOW}[3/8] Update repository sistem...${NC}"

apt clean
apt update --fix-missing -y

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] apt update gagal.${NC}"
    exit 1
fi

# =========================
# INSTALL DEPENDENCIES
# =========================
echo -e "\n${YELLOW}[4/8] Install dependency dasar...${NC}"

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
echo -e "\n${YELLOW}[5/8] Konfigurasi vm.max_map_count...${NC}"

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
echo -e "\n${YELLOW}[6/8] Mengunduh Wazuh installer resmi...${NC}"

cd /root || exit 1

rm -f wazuh-install.sh

WAZUH_URL="https://packages.wazuh.com/4.7/wazuh-install.sh"

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
echo -e "\n${YELLOW}[7/8] Menjalankan instalasi Wazuh All-in-One...${NC}"
echo -e "${CYAN}Proses ini dapat memakan waktu 10-30 menit.${NC}"

bash wazuh-install.sh -a

# =========================
# CEK HASIL INSTALL
# =========================
echo -e "\n${YELLOW}[8/8] Memeriksa hasil instalasi...${NC}"

if [ -f "/root/wazuh-install-files.tar" ]; then

    echo -e "${GREEN}"
    echo "========================================================"
    echo "             INSTALASI BERHASIL!"
    echo "========================================================"
    echo -e "${NC}"

    echo -e "${CYAN}Credential Login:${NC}"
    echo "--------------------------------------------------------"

    tar -axf /root/wazuh-install-files.tar \
    wazuh-install-files/wazuh-passwords.txt -O 2>/dev/null

    echo "--------------------------------------------------------"

    IP_ADDR=$(hostname -I | awk '{print $1}')

    echo -e "${YELLOW}Dashboard URL:${NC}"
    echo -e "${GREEN}https://${IP_ADDR}${NC}"

    echo ""
    echo -e "${YELLOW}Jika browser warning SSL:${NC}"
    echo "Advanced -> Proceed"

    echo ""
    echo -e "${CYAN}Status Service:${NC}"

    systemctl status wazuh-manager --no-pager
    systemctl status wazuh-dashboard --no-pager
    systemctl status wazuh-indexer --no-pager

else

    echo -e "${RED}[ERROR] Instalasi kemungkinan gagal.${NC}"

    echo ""
    echo -e "${YELLOW}Cek service manual:${NC}"

    systemctl status wazuh-manager --no-pager
    systemctl status wazuh-dashboard --no-pager
    systemctl status wazuh-indexer --no-pager

    echo ""
    echo -e "${YELLOW}Cek log error:${NC}"
    echo "journalctl -xe"
fi
