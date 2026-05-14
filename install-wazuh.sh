#!/bin/bash

# ==============================================================================
# Script Instalasi Wazuh All-in-One (AIO)
# Untuk Ubuntu Server di VirtualBox
# Tested: Ubuntu 22.04 / 24.04
# ==============================================================================

# =========================
# WARNA TERMINAL
# =========================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# =========================
# HEADER
# =========================
echo -e "${CYAN}"
echo "========================================================"
echo "      WAZUH ALL-IN-ONE INSTALLER (LOCAL LAB)"
echo "========================================================"
echo -e "${NC}"

# =========================
# VALIDASI ROOT
# =========================
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Jalankan script sebagai root.${NC}"
  echo -e "${YELLOW}Contoh:${NC} sudo bash install-wazuh.sh"
  exit 1
fi

# =========================
# CEK RAM
# =========================
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')

echo -e "${YELLOW}[1/8] Mengecek RAM sistem...${NC}"

if [ "$TOTAL_RAM" -lt 6000 ]; then
    echo -e "${RED}[WARNING] RAM kurang dari 6GB.${NC}"
    echo -e "${RED}OpenSearch/Wazuh kemungkinan gagal atau lambat.${NC}"
    echo -e "${YELLOW}Disarankan minimal 8GB RAM VM.${NC}"
    sleep 5
else
    echo -e "${GREEN}[OK] RAM mencukupi (${TOTAL_RAM} MB).${NC}"
fi

# =========================
# FIX CDROM REPOSITORY
# =========================
echo -e "\n${YELLOW}[2/8] Membersihkan repository CD-ROM Ubuntu...${NC}"

if grep -q "cdrom" /etc/apt/sources.list 2>/dev/null; then
    sed -i '/cdrom/d' /etc/apt/sources.list
    echo -e "${GREEN}[OK] Repository CD-ROM berhasil dihapus.${NC}"
else
    echo -e "${GREEN}[OK] Tidak ada repository CD-ROM.${NC}"
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
    unzip \
    tar \
    wget \
    gnupg \
    apt-transport-https \
    software-properties-common \
    dos2unix

# =========================
# CONFIG KERNEL
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
# DOWNLOAD WAZUH INSTALLER
# =========================
echo -e "\n${YELLOW}[6/8] Mengunduh Wazuh installer resmi...${NC}"

cd /root || exit 1

rm -f wazuh-install.sh

curl -fsSL -o wazuh-install.sh \
https://packages.wazuh.com/4.x/wazuh-install.sh

# =========================
# VALIDASI DOWNLOAD
# =========================
if [ ! -f wazuh-install.sh ]; then
    echo -e "${RED}[ERROR] File installer gagal diunduh.${NC}"
    exit 1
fi

# FIX CRLF
dos2unix wazuh-install.sh >/dev/null 2>&1

# VALIDASI FILE
FIRST_LINE=$(head -n 1 wazuh-install.sh)

if ! echo "$FIRST_LINE" | grep -q "bash"; then
    echo -e "${RED}[ERROR] File hasil download bukan bash script.${NC}"
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
echo -e "${CYAN}Proses ini bisa memakan waktu 10-30 menit.${NC}"

bash wazuh-install.sh -a

# =========================
# VALIDASI HASIL INSTALL
# =========================
echo -e "\n${YELLOW}[8/8] Memeriksa hasil instalasi...${NC}"

if [ -f "/root/wazuh-install-files.tar" ]; then

    echo -e "${GREEN}"
    echo "========================================================"
    echo "          INSTALASI WAZUH BERHASIL!"
    echo "========================================================"
    echo -e "${NC}"

    echo -e "${CYAN}Credential login:${NC}"
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
    echo -e "${GREEN}Service status:${NC}"

    systemctl status wazuh-manager --no-pager
    systemctl status wazuh-dashboard --no-pager
    systemctl status wazuh-indexer --no-pager

else

    echo -e "${RED}[ERROR] Instalasi kemungkinan gagal.${NC}"

    echo ""
    echo -e "${YELLOW}Cek service:${NC}"

    systemctl status wazuh-manager --no-pager
    systemctl status wazuh-dashboard --no-pager
    systemctl status wazuh-indexer --no-pager

    echo ""
    echo -e "${YELLOW}Cek log:${NC}"
    echo "journalctl -xe"
fi
