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

# =============================================================================
# LOG COLLECTION FUNCTIONS
# =============================================================================

# Helper: append XML block before </ossec_config>
append_log_block() {
    local CONF="$1" BLOCK="$2"
    sed -i '/<\/ossec_config>/d' "$CONF"
    printf '%s\n' "$BLOCK" >> "$CONF"
    echo "" >> "$CONF"
    echo "</ossec_config>" >> "$CONF"
}

# Mode 2: Wildcard — kirim semua /var/log/
log_collect_wildcard() {
    local CONF="$1"
    append_log_block "$CONF" "$(cat <<'XML'

  <!-- ========== WILDCARD: All logs ========== -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/*.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/*/*.log</location>
  </localfile>
XML
)"
    echo -e "${GREEN}[OK] Wildcard mode — /var/log/*.log + /var/log/*/*.log enabled.${NC}"
}

# Mode 3: Auto-detect — scan /var/log, enable yang ditemukan
log_collect_autodetect() {
    local CONF="$1"
    local TMPFILE="/tmp/wazuh-autodetect.xml"
    local FOUND=0
    echo "  <!-- ========== AUTO-DETECTED LOGS ========== -->" > "$TMPFILE"
    echo -e "${CYAN}Scanning /var/log & known service paths...${NC}"

    # Known service targets: format|path|label
    local TARGETS=(
        "apache|/var/log/apache2/access.log|Apache access"
        "apache|/var/log/apache2/error.log|Apache error"
        "apache|/var/log/httpd/access_log|Apache access (RHEL)"
        "apache|/var/log/httpd/error_log|Apache error (RHEL)"
        "syslog|/var/log/nginx/access.log|Nginx access"
        "syslog|/var/log/nginx/error.log|Nginx error"
        "syslog|/usr/local/lsws/logs/error.log|LiteSpeed error"
        "apache|/usr/local/lsws/logs/access.log|LiteSpeed access"
        "syslog|/usr/local/cpanel/logs/access_log|cPanel access"
        "syslog|/usr/local/cpanel/logs/error_log|cPanel error"
        "syslog|/usr/local/cpanel/logs/login_log|cPanel login"
        "syslog|/var/log/chkservd.log|cPanel chkservd"
        "syslog|/var/log/modsec_audit.log|ModSecurity"
        "syslog|/var/log/mysql/error.log|MySQL"
        "syslog|/var/log/postgresql/postgresql-main.log|PostgreSQL"
        "syslog|/var/log/mongodb/mongod.log|MongoDB"
        "syslog|/var/log/mail.log|Mail"
        "syslog|/var/log/exim4/mainlog|Exim"
        "syslog|/var/log/dovecot.log|Dovecot"
        "syslog|/var/log/vsftpd.log|vsftpd"
        "syslog|/var/log/proftpd/proftpd.log|ProFTPD"
        "syslog|/var/log/pure-ftpd/transfer.log|Pure-FTPd"
        "syslog|/var/log/docker.log|Docker"
        "syslog|/var/log/ufw.log|UFW"
        "syslog|/var/log/fail2ban.log|Fail2ban"
        "json|/var/log/suricata/eve.json|Suricata"
        "syslog|/var/log/snort/alert|Snort"
        "syslog|/var/log/openvpn/openvpn.log|OpenVPN"
        "syslog|/var/log/squid/access.log|Squid"
        "syslog|/var/log/plesk/panel.log|Plesk"
        "syslog|/opt/webmin/miniserv.log|Webmin"
        "syslog|/var/log/secure|RHEL secure"
        "syslog|/var/log/messages|RHEL messages"
        "syslog|/var/log/sysmon.log|Sysmon Linux"
    )

    for target in "${TARGETS[@]}"; do
        IFS='|' read -r fmt path label <<< "$target"
        if [ -f "$path" ]; then
            echo -e "  ${GREEN}[+] ${label}: ${path}${NC}"
            cat >> "$TMPFILE" <<ENTRY
  <localfile>
    <log_format>${fmt}</log_format>
    <location>${path}</location>
  </localfile>
ENTRY
            ((FOUND++)) || true
        fi
    done

    # Pick up remaining /var/log/*.log not already in base config
    for f in /var/log/*.log; do
        [ -f "$f" ] || continue
        local base
        base=$(basename "$f")
        # Skip files already in core config or detected above
        case "$base" in
            syslog|auth.log|kern.log|dpkg.log|ufw.log|fail2ban.log|mail.log|docker.log|sysmon.log) continue ;;
        esac
        if ! grep -q "$f" "$CONF" 2>/dev/null; then
            echo -e "  ${GREEN}[+] Extra: ${f}${NC}"
            cat >> "$TMPFILE" <<ENTRY
  <localfile>
    <log_format>syslog</log_format>
    <location>${f}</location>
  </localfile>
ENTRY
            ((FOUND++)) || true
        fi
    done

    if [ "$FOUND" -gt 0 ]; then
        append_log_block "$CONF" "$(cat "$TMPFILE")"
        echo -e "${GREEN}[OK] Auto-detect: ${FOUND} additional log sources enabled.${NC}"
    else
        echo -e "${GREEN}[OK] No additional logs found beyond core.${NC}"
    fi
    rm -f "$TMPFILE"
}

# Mode 4: Custom — pilih kategori manual
log_collect_custom() {
    local CONF="$1"
    local TMPFILE="/tmp/wazuh-custom-logs.xml"
    echo "  <!-- ========== CUSTOM SELECTED LOGS ========== -->" > "$TMPFILE"
    local SELECTED=0

    echo ""
    echo -e "${CYAN}Pilih kategori (pisah koma, contoh: 1,3,8):${NC}"
    echo ""
    echo "   1) Web Server    — Apache, Nginx, LiteSpeed"
    echo "   2) cPanel / WHM"
    echo "   3) WAF           — ModSecurity"
    echo "   4) Database      — MySQL, PostgreSQL, MongoDB"
    echo "   5) Mail          — mail.log, Exim, Dovecot"
    echo "   6) FTP           — vsftpd, ProFTPD, Pure-FTPd"
    echo "   7) Container     — Docker, Kubernetes"
    echo "   8) Firewall/IDS  — UFW, Suricata, Snort, Fail2ban"
    echo "   9) VPN/Proxy     — OpenVPN, Squid"
    echo "  10) Panel         — Plesk, Webmin"
    echo "  11) RHEL/CentOS   — secure, messages"
    echo "  12) Sysmon Linux"
    echo "  13) System Health  — df, netstat, last (commands)"
    echo ""
    read -p "Kategori: " SELECTIONS

    IFS=',' read -ra CATS <<< "$SELECTIONS"
    for c in "${CATS[@]}"; do
        c=$(echo "$c" | tr -d ' ')
        case "$c" in
            1) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/access.log</location>
  </localfile>
  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/error.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/nginx/access.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/nginx/error.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/usr/local/lsws/logs/error.log</location>
  </localfile>
  <localfile>
    <log_format>apache</log_format>
    <location>/usr/local/lsws/logs/access.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Web Server${NC}"; ((SELECTED++)) || true ;;
            2) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/usr/local/cpanel/logs/access_log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/usr/local/cpanel/logs/error_log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/usr/local/cpanel/logs/login_log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/chkservd.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] cPanel/WHM${NC}"; ((SELECTED++)) || true ;;
            3) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/modsec_audit.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] WAF/ModSecurity${NC}"; ((SELECTED++)) || true ;;
            4) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/mysql/error.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/postgresql/postgresql-main.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/mongodb/mongod.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Database${NC}"; ((SELECTED++)) || true ;;
            5) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/mail.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/exim4/mainlog</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/dovecot.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Mail Server${NC}"; ((SELECTED++)) || true ;;
            6) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/vsftpd.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/proftpd/proftpd.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/pure-ftpd/transfer.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] FTP${NC}"; ((SELECTED++)) || true ;;
            7) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/docker.log</location>
  </localfile>
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/containers/*.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Container${NC}"; ((SELECTED++)) || true ;;
            8) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/ufw.log</location>
  </localfile>
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/snort/alert</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/fail2ban.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Firewall/IDS${NC}"; ((SELECTED++)) || true ;;
            9) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/openvpn/openvpn.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/squid/access.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] VPN/Proxy${NC}"; ((SELECTED++)) || true ;;
            10) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/plesk/panel.log</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/opt/webmin/miniserv.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Panel/Mgmt${NC}"; ((SELECTED++)) || true ;;
            11) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/secure</location>
  </localfile>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] RHEL/CentOS${NC}"; ((SELECTED++)) || true ;;
            12) cat >> "$TMPFILE" <<'EOF'
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/sysmon.log</location>
  </localfile>
EOF
               echo -e "  ${GREEN}[+] Sysmon Linux${NC}"; ((SELECTED++)) || true ;;
            13) cat >> "$TMPFILE" <<'CMDEOF'
  <localfile>
    <log_format>command</log_format>
    <command>df -P</command>
    <frequency>360</frequency>
  </localfile>
  <localfile>
    <log_format>full_command</log_format>
    <command>netstat -tulpn | sed 's/\([[:alnum:]]\+\)\ \+[[:digit:]]\+\ \+[[:digit:]]\+\ \+\(.*\):\([[:digit:]]*\)\ \+\([0-9\.\:\*]\+\).\+\ \([[:digit:]]*\/[[:alnum:]\-]*\).*/\1 \2 == \3 == \4 \5/' | sort -k 4 -g | sed 's/ == \(.*\) ==/:\1/' | sed 1,2d</command>
    <alias>netstat listening ports</alias>
    <frequency>360</frequency>
  </localfile>
  <localfile>
    <log_format>full_command</log_format>
    <command>last -n 20</command>
    <frequency>360</frequency>
  </localfile>
CMDEOF
               echo -e "  ${GREEN}[+] System Health${NC}"; ((SELECTED++)) || true ;;
            *) echo -e "  ${YELLOW}[?] Kategori '$c' tidak dikenal — skip${NC}" ;;
        esac
    done

    if [ "$SELECTED" -gt 0 ]; then
        append_log_block "$CONF" "$(cat "$TMPFILE")"
        echo -e "${GREEN}[OK] Custom: ${SELECTED} categories enabled.${NC}"
    else
        echo -e "${YELLOW}[OK] No categories selected — using template.${NC}"
    fi
    rm -f "$TMPFILE"
}

# Main menu for log collection mode
configure_log_collection() {
    local CONF="$1"
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  LOG COLLECTION MODE${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "  1) Template — Core logs saja (audit, syslog, auth, kern)"
    echo "  2) All      — Wildcard /var/log/*.log (kirim semua)"
    echo "  3) Auto     — Scan /var/log & auto-enable yang ada"
    echo "  4) Custom   — Pilih kategori manual"
    echo ""
    read -p "Pilih mode [1-4, default=1]: " LOG_MODE
    LOG_MODE=${LOG_MODE:-1}

    case $LOG_MODE in
        2) log_collect_wildcard "$CONF" ;;
        3) log_collect_autodetect "$CONF" ;;
        4) log_collect_custom "$CONF" ;;
        *) echo -e "${GREEN}[OK] Template mode — core logs only.${NC}" ;;
    esac
}

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
# ENVIRONMENT (prevent interactive prompts)
# =========================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
if [ -f /etc/needrestart/needrestart.conf ]; then
    sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

# =========================
# DETECT DISTRO
# =========================
echo -e "\n${YELLOW}[1/9] Detect distribusi Linux...${NC}"

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
# PRE-FLIGHT: APT LOCK & CONNECTIVITY
# =========================
echo -e "\n${YELLOW}[2/9] Pre-flight checks...${NC}"

# Free APT lock (apt-based only)
if [ "$PKG_MGR" = "apt" ]; then
    systemctl stop unattended-upgrades 2>/dev/null || true
    killall -9 unattended-upgr 2>/dev/null || true
    killall -9 apt-get 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
    rm -f /var/lib/apt/lists/lock 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo -e "${YELLOW}  Waiting for dpkg lock...${NC}"
        sleep 3
    done
    echo -e "${GREEN}[OK] APT lock free.${NC}"
fi

# Test connectivity to manager
echo -e "${CYAN}Testing koneksi ke manager ${WAZUH_MANAGER}...${NC}"
if command -v nc &>/dev/null; then
    if nc -zv "${WAZUH_MANAGER}" 1514 -w 5 2>/dev/null; then
        echo -e "${GREEN}[OK] Port 1514 reachable.${NC}"
    else
        echo -e "${YELLOW}[WARNING] Port 1514 tidak reachable dari agent ini.${NC}"
        echo -e "${YELLOW}  Cek: cloud firewall, manager running, IP benar.${NC}"
        echo -e "${YELLOW}  Agent tetap diinstall — bisa manual register nanti.${NC}"
    fi
    if nc -zv "${WAZUH_MANAGER}" 1515 -w 5 2>/dev/null; then
        echo -e "${GREEN}[OK] Port 1515 reachable (auto-enrollment OK).${NC}"
    else
        echo -e "${YELLOW}[WARNING] Port 1515 tidak reachable — auto-enrollment mungkin gagal.${NC}"
        echo -e "${YELLOW}  Fallback: manual register via manage_agents.${NC}"
    fi
else
    echo -e "${YELLOW}[SKIP] nc tidak tersedia — skip connectivity check.${NC}"
fi

# =========================
# INSTALL AUDITD
# =========================
echo -e "\n${YELLOW}[3/9] Install auditd...${NC}"

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
echo -e "\n${YELLOW}[4/9] Deploy baseline audit.rules...${NC}"

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
echo -e "\n${YELLOW}[5/9] Install Sysmon for Linux (optional)...${NC}"

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
echo -e "\n${YELLOW}[6/9] Install Wazuh Agent...${NC}"

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
echo -e "\n${YELLOW}[7/9] Deploy custom ossec.conf...${NC}"

OSSEC_CONF_SRC="${SCRIPT_DIR}/ossec-agent-linux.conf"
OSSEC_CONF_DST="/var/ossec/etc/ossec.conf"

if [ -f "$OSSEC_CONF_SRC" ]; then
    # Backup original
    cp "$OSSEC_CONF_DST" "${OSSEC_CONF_DST}.bak-$(date +%s)" 2>/dev/null || true

    # Copy and patch manager IP
    cp "$OSSEC_CONF_SRC" "$OSSEC_CONF_DST"
    sed -i "s|192.168.1.107|${WAZUH_MANAGER}|g" "$OSSEC_CONF_DST"
    sed -i "s|MANAGER_IP|${WAZUH_MANAGER}|g" "$OSSEC_CONF_DST"
    # Patch enrollment manager_address too
    sed -i "s|<manager_address>.*</manager_address>|<manager_address>${WAZUH_MANAGER}</manager_address>|g" "$OSSEC_CONF_DST"

    chown root:wazuh "$OSSEC_CONF_DST"
    chmod 640 "$OSSEC_CONF_DST"

    echo -e "${GREEN}[OK] ossec.conf deployed (manager=${WAZUH_MANAGER}).${NC}"

    # Smart log collection configuration
    configure_log_collection "$OSSEC_CONF_DST"

    # Re-apply permissions after log config changes
    chown root:wazuh "$OSSEC_CONF_DST"
    chmod 640 "$OSSEC_CONF_DST"
else
    echo -e "${YELLOW}[SKIP] ossec-agent-linux.conf tidak ditemukan.${NC}"
    echo -e "${YELLOW}       Konfigurasi manager IP manual di ${OSSEC_CONF_DST}${NC}"

    # At minimum, set manager IP in existing config
    sed -i "s|<address>.*</address>|<address>${WAZUH_MANAGER}</address>|" "$OSSEC_CONF_DST" 2>/dev/null || true
fi

# =========================
# START AGENT
# =========================
echo -e "\n${YELLOW}[8/9] Start Wazuh agent...${NC}"

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
echo -e "\n${YELLOW}[9/9] Verifikasi...${NC}"

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
