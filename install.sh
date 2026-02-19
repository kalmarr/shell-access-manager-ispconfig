#!/bin/bash
# ============================================================
# Shell Access Manager for ISPConfig - Installer
# Usage: sudo ./install.sh
# ============================================================

set -euo pipefail

INSTALL_DIR="/usr/local/shell-access-manager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Root required: sudo $0"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Shell Access Manager - Install              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# --- Dependencies ---
echo "1/6 Checking dependencies..."
MISSING=()
for cmd in curl jq mysql at; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  Installing missing packages: ${MISSING[*]}"
    apt-get update -qq
    for pkg in "${MISSING[@]}"; do
        case "$pkg" in
            mysql) apt-get install -y -qq mariadb-client || apt-get install -y -qq mysql-client ;;
            at)    apt-get install -y -qq at ;;
            *)     apt-get install -y -qq "$pkg" ;;
        esac
    done
fi
echo "  ✅ Dependencies OK"

# --- Copy files ---
echo "2/6 Installing to: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -v "$SCRIPT_DIR"/lib-functions.sh "$INSTALL_DIR/"
cp -v "$SCRIPT_DIR"/enable-shell-user.sh "$INSTALL_DIR/"
cp -v "$SCRIPT_DIR"/disable-shell-user.sh "$INSTALL_DIR/"
cp -v "$SCRIPT_DIR"/monitor-idle-users.sh "$INSTALL_DIR/"
cp -v "$SCRIPT_DIR"/status.sh "$INSTALL_DIR/"

if [ ! -f "$INSTALL_DIR/shell-access-manager.conf" ]; then
    cp -v "$SCRIPT_DIR"/shell-access-manager.conf.example "$INSTALL_DIR/shell-access-manager.conf"
    echo "  ⚠️  IMPORTANT: Edit the config: $INSTALL_DIR/shell-access-manager.conf"
else
    echo "  ℹ️  Config already exists, not overwriting"
fi

chmod +x "$INSTALL_DIR"/*.sh
chmod 600 "$INSTALL_DIR/shell-access-manager.conf"
echo "  ✅ Files installed"

# --- State directory ---
echo "3/6 State directory..."
mkdir -p /var/lib/shell-access-manager
echo "  ✅ /var/lib/shell-access-manager created"

# --- Log file ---
echo "4/6 Log setup..."
touch /var/log/shell-access-manager.log
chmod 640 /var/log/shell-access-manager.log
echo "  ✅ /var/log/shell-access-manager.log"

# --- Logrotate ---
echo "5/6 Logrotate..."
cat > /etc/logrotate.d/shell-access-manager << 'LOGROTATE'
/var/log/shell-access-manager.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
LOGROTATE
echo "  ✅ Logrotate configured"

# --- Crontab ---
echo "6/6 Crontab..."
CRON_LINE="*/10 * * * * ${INSTALL_DIR}/monitor-idle-users.sh > /dev/null 2>&1"

if crontab -l 2>/dev/null | grep -q "monitor-idle-users.sh"; then
    echo "  ℹ️  Cron job already exists"
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "  ✅ Cron job added (every 10 minutes)"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Installation complete!                                  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                             ║"
echo "║  📋 NEXT STEPS:                                             ║"
echo "║                                                             ║"
echo "║  1. Create ISPConfig Remote API user:                       ║"
echo "║     Panel -> System -> Remote Users -> Add                  ║"
echo "║     - Username: shell_manager                               ║"
echo "║     - Functions: Sites Shell-User functions                 ║"
echo "║                                                             ║"
echo "║  2. Edit configuration:                                     ║"
echo "║     nano $INSTALL_DIR/shell-access-manager.conf"
echo "║     -> Set API_PASS                                         ║"
echo "║     -> Set NOTIFY_EMAIL                                     ║"
echo "║                                                             ║"
echo "║  3. Test:                                                   ║"
echo "║     $INSTALL_DIR/status.sh"
echo "║     $INSTALL_DIR/enable-shell-user.sh <user> 1"
echo "║     $INSTALL_DIR/disable-shell-user.sh <user>"
echo "║                                                             ║"
echo "║  4. Symlinks (optional):                                    ║"
echo "║     ln -s $INSTALL_DIR/enable-shell-user.sh /usr/local/bin/shell-enable"
echo "║     ln -s $INSTALL_DIR/disable-shell-user.sh /usr/local/bin/shell-disable"
echo "║     ln -s $INSTALL_DIR/status.sh /usr/local/bin/shell-status"
echo "║                                                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
