#!/bin/bash

# ==============================================================================
# Script Perbantuan Instalasi Wazuh All-in-One (AIO)
# Dirancang untuk setup lokal di VirtualBox (Ubuntu/Debian & Rocky/RHEL)
# ==============================================================================

# Warna untuk output terminal agar mudah dibaca
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}========================================================"
echo -e "   Memulai Script Instalasi Wazuh All-in-One Lokal"
echo -e "========================================================${NC}"

# 1. Validasi Akses Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Harap jalankan script ini sebagai root (gunakan sudo bash).${NC}"
  exit 1
fi

# 2. Konfigurasi Kernel untuk OpenSearch (vm.max_map_count)
echo -e "\n${YELLOW}[1/4] Mengonfigurasi virtual memory kernel (vm.max_map_count)...${NC}"
CURRENT_MAX_MAP=$(sysctl -n vm.max_map_count 2>/dev/null)

if [ "$CURRENT_MAX_MAP" != "262144" ]; then
    sysctl -w vm.max_map_count=262144
    
    # Memastikan tidak ada double entry konfigurasi di sysctl.conf
    sed -i '/vm.max_map_count/d' /etc/sysctl.conf
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    echo -e "${GREEN}[OK] vm.max_map_count berhasil diatur menjadi 262144 secara permanen.${NC}"
else
    echo -e "${GREEN}[OK] vm.max_map_count sudah sesuai (262144). Skipping.${NC}"
fi

# 3. Deteksi Package Manager dan Update Repositori
echo -e "\n${YELLOW}[2/4] Memperbarui repositori sistem...${NC}"
if [ -x "$(command -v apt)" ]; then
    echo -e "${CYAN}Mendeteksi distro berbasis Debian/Ubuntu. Menjalankan apt update...${NC}"
    apt update -y
elif [ -x "$(command -v dnf)" ]; then
    echo -e "${CYAN}Mendeteksi distro berbasis RHEL/Rocky Linux. Menjalankan dnf check-update...${NC}"
    dnf check-update -y
else
    echo -e "${YELLOW}[WARNING] Package manager tidak dikenali (bukan apt/dnf). Mencoba melanjutkan...${NC}"
fi

# 4. Unduh dan Jalankan Script Resmi Wazuh Installation Assistant
echo -e "\n${YELLOW}[3/4] Mengunduh dan mengeksekusi Wazuh Installation Assistant...${NC}"
echo -e "${CYAN}Proses ini akan memakan waktu 5-15 menit tergantung spesifikasi VM dan internet.${NC}"

# Hapus file instalasi lama jika ada untuk mencegah konflik
if [ -f "wazuh-install.sh" ]; then
    rm -f wazuh-install.sh
fi

curl -sO https://packages.wazuh.com/4.x/wazuh-install.sh

if [ ! -f "wazuh-install.sh" ]; then
    echo -e "${RED}[ERROR] Gagal mengunduh wazuh-install.sh. Periksa koneksi internet VM Anda.${NC}"
    exit 1
fi

# Eksekusi instalasi otomatis All-in-One (-a)
bash wazuh-install.sh -a

# 5. Output Informasi Kredensial setelah instalasi selesai
echo -e "\n${YELLOW}[4/4] Memeriksa hasil instalasi...${NC}"
if [ -f "wazuh-install-files.tar" ]; then
    echo -e "${GREEN}========================================================"
    echo -e "        INSTALASI WAZUH ALL-IN-ONE BERHASIL!"
    echo -e "========================================================${NC}"
    echo -e "${CYAN}Silakan catat informasi kredensial login di bawah ini:${NC}"
    echo -e "--------------------------------------------------------"
    
    # Ekstrak file wazuh-passwords.txt langsung ke stdout layar terminal
    tar -axf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt -O 2>/dev/null
    
    echo -e "--------------------------------------------------------"
    
    # Mengambil IP Address lokal utama untuk memudahkan instruksi akses
    IP_ADDR=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I | awk '{print $1}')
    echo -e "${YELLOW}Akses Web Dashboard via Browser Anda:${NC}"
    echo -e "${GREEN}URL      : https://${IP_ADDR}${NC}"
    echo -e "${YELLOW}Username : admin${NC}"
    echo -e "--------------------------------------------------------"
    echo -e "${CYAN}Catatan: Jika browser memunculkan peringatan SSL/Sertifikat,${NC}"
    echo -e "${CYAN}pilih 'Advanced' lalu klik 'Proceed/Lanjutkan' (Self-signed certificate).${NC}"
    echo -e "========================================================"
else
    echo -e "${RED}[ERROR] File wazuh-install-files.tar tidak ditemukan.${NC}"
    echo -e "${RED}Kemungkinan terjadi kesalahan/interupsi saat script utama berjalan.${NC}"
    echo -e "${RED}Silakan cek log sistem atau jalankan ulang dengan resource RAM yang lebih besar.${NC}"
fi