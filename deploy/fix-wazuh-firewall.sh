#!/bin/bash
# Fix CRLF jika file dari Google Drive / Windows
sed -i 's/\r$//' "${BASH_SOURCE[0]}" 2>/dev/null || true

# ==============================================================================
# WAZUH MANAGER — Firewall Fix & Port Validation
# Jalankan di Wazuh MANAGER server
#
# Usage:
#   sudo bash fix-wazuh-firewall.sh
#
# What this does:
#   1. Cek semua required ports listening
#   2. Open semua port via UFW + iptables
#   3. Disable conflicting firewalls
#   4. Validate dari localhost
#   5. Print test commands untuk agent
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Jalankan sebagai root/sudo.${NC}"
    exit 1
fi

PRIVATE_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "unknown")
MANAGER_IP="${PUBLIC_IP}"
REQUIRED_PORTS=(1514 1515 443 9200)

echo ""
echo "========================================="
echo " WAZUH FIREWALL FIX & PORT VALIDATION"
echo "========================================="
echo -e "${CYAN}Private IP: ${PRIVATE_IP}${NC}"
echo -e "${CYAN}Public IP:  ${PUBLIC_IP}${NC}"
echo -e "${CYAN}Agent harus connect ke: ${GREEN}${PUBLIC_IP}${NC}"
echo ""

# =========================
# STEP 1: Cek services running
# =========================
echo -e "${YELLOW}[1/5] Cek Wazuh services...${NC}"

SERVICES=("wazuh-manager" "wazuh-indexer" "wazuh-dashboard" "filebeat")
ALL_OK=true

for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "  ${GREEN}✓ ${svc} — running${NC}"
    else
        echo -e "  ${RED}✗ ${svc} — NOT running${NC}"
        ALL_OK=false
        # Try to start it
        echo -e "  ${YELLOW}  → Attempting to start ${svc}...${NC}"
        systemctl start "$svc" 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}  → ${svc} started OK${NC}"
        else
            echo -e "  ${RED}  → ${svc} FAILED to start${NC}"
        fi
    fi
done

# =========================
# STEP 2: Cek ports listening
# =========================
echo ""
echo -e "${YELLOW}[2/5] Cek ports listening...${NC}"

for port in "${REQUIRED_PORTS[@]}"; do
    LISTEN=$(ss -tlnp | grep ":${port} " || true)
    if [ -n "$LISTEN" ]; then
        PROC=$(echo "$LISTEN" | awk '{print $NF}' | head -1)
        echo -e "  ${GREEN}✓ Port ${port} — listening (${PROC})${NC}"
    else
        echo -e "  ${RED}✗ Port ${port} — NOT listening${NC}"
        ALL_OK=false
    fi
done

# Also check authd specifically
AUTHD_PID=$(pgrep -f "wazuh-authd" || true)
if [ -n "$AUTHD_PID" ]; then
    echo -e "  ${GREEN}✓ wazuh-authd — running (PID: ${AUTHD_PID})${NC}"
else
    echo -e "  ${RED}✗ wazuh-authd — NOT running${NC}"
    echo -e "  ${YELLOW}  → Check /var/ossec/etc/ossec.conf <auth> section${NC}"
fi

# =========================
# STEP 3: Open ports — UFW
# =========================
echo ""
echo -e "${YELLOW}[3/5] Fixing UFW rules...${NC}"

if command -v ufw &>/dev/null; then
    # Make sure UFW is active
    ufw --force enable 2>/dev/null || true

    ufw allow 22/tcp comment "SSH" 2>/dev/null || true
    ufw allow 1514/tcp comment "Wazuh agent" 2>/dev/null || true
    ufw allow 1515/tcp comment "Wazuh enrollment" 2>/dev/null || true
    ufw allow 443/tcp comment "Wazuh dashboard" 2>/dev/null || true
    ufw allow 9200/tcp comment "Wazuh indexer" 2>/dev/null || true

    echo -e "  ${GREEN}✓ UFW rules applied${NC}"
    ufw status numbered 2>/dev/null | head -20
else
    echo -e "  ${YELLOW}UFW not installed — skipping${NC}"
fi

# =========================
# STEP 4: Open ports — iptables (backup)
# =========================
echo ""
echo -e "${YELLOW}[4/5] Fixing iptables rules (backup)...${NC}"

for port in 22 1514 1515 443 9200; do
    # Check if rule already exists
    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        echo -e "  ${GREEN}+ iptables: port ${port} opened${NC}"
    else
        echo -e "  ${CYAN}= iptables: port ${port} already open${NC}"
    fi
done

# Save iptables (persist across reboot)
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
elif command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables.rules 2>/dev/null || true
fi

echo -e "  ${GREEN}✓ iptables rules applied${NC}"

# =========================
# STEP 5: Validate & print test commands
# =========================
echo ""
echo -e "${YELLOW}[5/5] Validation...${NC}"

# Test localhost connectivity
for port in "${REQUIRED_PORTS[@]}"; do
    if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
        echo -e "  ${GREEN}✓ localhost:${port} — OK${NC}"
    else
        echo -e "  ${RED}✗ localhost:${port} — FAILED${NC}"
    fi
done

# Auth config check
AUTH_PASS=$(grep -o '<use_password>[^<]*' /var/ossec/etc/ossec.conf 2>/dev/null | head -1 | sed 's/<use_password>//')
AUTH_DISABLED=$(grep -o '<disabled>[^<]*' /var/ossec/etc/ossec.conf 2>/dev/null | grep -A0 "auth" | head -1 || echo "unknown")

echo ""
echo "========================================="
echo " SUMMARY"
echo "========================================="
echo -e "${CYAN}Manager IP:        ${MANAGER_IP}${NC}"
echo -e "${CYAN}Auth password:     ${AUTH_PASS:-unknown}${NC}"
echo -e "${CYAN}Wazuh version:     $(cat /var/ossec/etc/ossec-init.conf 2>/dev/null | grep VERSION | cut -d'"' -f2 || echo 'unknown')${NC}"

echo ""
echo -e "${YELLOW}Dashboard login:${NC}"
echo -e "  URL:      ${GREEN}https://${MANAGER_IP}${NC}"
echo -e "  User:     ${GREEN}admin${NC}"
echo -e "  Password: ${GREEN}$(tar -xf /root/wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt -O 2>/dev/null | grep -A1 'indexer_username' | tail -1 | tr -d ' ' || echo 'check /root/wazuh-install-files.tar')${NC}"

echo ""
echo -e "${YELLOW}Test dari AGENT (copy-paste di agent):${NC}"
echo -e "${CYAN}  nc -zv ${MANAGER_IP} 1514 -w 5${NC}"
echo -e "${CYAN}  nc -zv ${MANAGER_IP} 1515 -w 5${NC}"
echo -e "${CYAN}  nc -zv ${MANAGER_IP} 443 -w 5${NC}"

echo ""
echo -e "${YELLOW}Kalau masih timeout dari agent = CLOUD PROVIDER FIREWALL.${NC}"
echo -e "${YELLOW}Buka di IDCloudHost console → VM → Firewall → allow 1514+1515 TCP.${NC}"

echo ""
echo -e "${YELLOW}Manual agent registration (bypass port 1515):${NC}"
echo -e "${CYAN}  # Di MANAGER:${NC}"
echo -e "${CYAN}  /var/ossec/bin/manage_agents -a any -n agent-linux-01${NC}"
echo -e "${CYAN}  /var/ossec/bin/manage_agents -e 001${NC}"
echo -e "${CYAN}  # Copy key, lalu di AGENT:${NC}"
echo -e "${CYAN}  /var/ossec/bin/manage_agents -i <KEY>${NC}"
echo -e "${CYAN}  systemctl restart wazuh-agent${NC}"
echo ""
echo "========================================="
