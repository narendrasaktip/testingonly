#!/bin/bash

# ==============================================================================
# WAZUH AGENT AUTO INSTALLER
# Ubuntu / Debian
# ==============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear

echo -e "${CYAN}"
echo "========================================================"
echo "            WAZUH AGENT INSTALLER"
echo "========================================================"
echo -e "${NC}"

# =========================
# VALIDASI ROOT
# =========================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Jalankan script dengan sudo/root.${NC}"
    echo ""
    echo "Contoh:"
    echo "sudo bash install-agent.sh"
    exit 1
fi

# =========================
# INPUT IP WAZUH SERVER
# =========================
echo -e "${YELLOW}Masukkan IP Wazuh Server:${NC}"
read -rp "IP Server: " WAZUH_SERVER

if [ -z "$WAZUH_SERVER" ]; then
    echo -e "${RED}[ERROR] IP server tidak boleh kosong.${NC}"
    exit 1
fi

# =========================
# INPUT NAMA AGENT
# =========================
DEFAULT_AGENT_NAME=$(hostname)

echo ""
echo -e "${YELLOW}Masukkan nama agent:${NC}"
read -rp "Nama Agent [$DEFAULT_AGENT_NAME]: " AGENT_NAME

AGENT_NAME=${AGENT_NAME:-$DEFAULT_AGENT_NAME}

# =========================
# UPDATE SYSTEM
# =========================
echo -e "\n${YELLOW}[1/6] Update repository sistem...${NC}"

apt update -y

# =========================
# INSTALL DEPENDENCY
# =========================
echo -e "\n${YELLOW}[2/6] Install dependency...${NC}"

apt install -y curl apt-transport-https lsb-release gnupg

# =========================
# IMPORT GPG KEY
# =========================
echo -e "\n${YELLOW}[3/6] Menambahkan repository Wazuh...${NC}"

curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
gpg --dearmor -o /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
> /etc/apt/sources.list.d/wazuh.list

# =========================
# INSTALL AGENT
# =========================
echo -e "\n${YELLOW}[4/6] Menginstall Wazuh Agent...${NC}"

apt update -y

WAZUH_MANAGER="$WAZUH_SERVER" \
WAZUH_AGENT_NAME="$AGENT_NAME" \
apt install wazuh-agent -y

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] Install wazuh-agent gagal.${NC}"
    exit 1
fi

# =========================
# ENABLE & START SERVICE
# =========================
echo -e "\n${YELLOW}[5/6] Menjalankan service wazuh-agent...${NC}"

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent

sleep 3

# =========================
# CEK STATUS
# =========================
echo -e "\n${YELLOW}[6/6] Memeriksa status agent...${NC}"

if systemctl is-active --quiet wazuh-agent; then

    echo -e "${GREEN}"
    echo "========================================================"
    echo "         WAZUH AGENT BERHASIL DIINSTALL!"
    echo "========================================================"
    echo -e "${NC}"

    echo -e "${CYAN}Informasi Agent:${NC}"
    echo "--------------------------------------------------------"

    echo -e "${YELLOW}Agent Name :${NC} $AGENT_NAME"
    echo -e "${YELLOW}Server IP  :${NC} $WAZUH_SERVER"

    echo "--------------------------------------------------------"

    echo -e "${GREEN}Status:${NC}"
    systemctl status wazuh-agent --no-pager

    echo ""
    echo -e "${CYAN}Cek agent di dashboard Wazuh:${NC}"
    echo "Dashboard -> Agents"

else

    echo -e "${RED}[ERROR] Service wazuh-agent gagal berjalan.${NC}"

    echo ""
    echo -e "${YELLOW}Cek log:${NC}"

    journalctl -u wazuh-agent -xe --no-pager
fi
