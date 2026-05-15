#!/bin/bash
# ============================================================
# Shell Timer - ISPConfig Integration Installer
# 
# ZERO ISPConfig files modified!
# Uses Apache mod_substitute to inject JS.
# Survives ISPConfig updates without any action needed.
#
# Usage: sudo ./install.sh [install|uninstall|status]
# ============================================================

set -euo pipefail

ISPCONFIG_WEB="/usr/local/ispconfig/interface/web"
SHELL_TIMER_DIR="${ISPCONFIG_WEB}/shell_timer"
SHELL_MANAGER_DIR="/usr/local/shell-access-manager"
APACHE_CONF="/etc/apache2/conf-available/shell-timer.conf"
SUDOERS_FILE="/etc/sudoers.d/shell-timer"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; CYAN='\e[36m'; NC='\e[0m'
log_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
log_err()  { echo -e "  ${RED}✗${NC} $*"; }
log_info() { echo -e "  ${CYAN}→${NC} $*"; }

# ============================================================
# INSTALL
# ============================================================
do_install() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Shell Timer - ISPConfig Integration                 ║"
    echo "║  Zero ISPConfig file modifications!                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    # --- Checks ---
    [ ! -d "$ISPCONFIG_WEB" ] && { log_err "ISPConfig not found: $ISPCONFIG_WEB"; exit 1; }
    [ ! -d "$SHELL_MANAGER_DIR" ] && { log_err "Shell Access Manager not found: $SHELL_MANAGER_DIR"; exit 1; }

    # --- 1. Deploy web files ---
    echo "1. Web fájlok telepítése..."
    mkdir -p "$SHELL_TIMER_DIR"
    
    local src="${SCRIPT_DIR}/shell_timer"
    [ ! -d "$src" ] && src="${SCRIPT_DIR}/../shell_timer"
    [ ! -d "$src" ] && { log_err "Source files not found"; exit 1; }

    cp "$src/api.php"       "$SHELL_TIMER_DIR/"
    cp "$src/timer.js"      "$SHELL_TIMER_DIR/"
    cp "$src/dashboard.php" "$SHELL_TIMER_DIR/"
    chown -R ispconfig:ispconfig "$SHELL_TIMER_DIR"
    chmod 755 "$SHELL_TIMER_DIR"
    chmod 644 "$SHELL_TIMER_DIR"/*
    log_ok "Fájlok: $SHELL_TIMER_DIR/"

    # --- 2. Apache mod_substitute ---
    echo ""
    echo "2. Apache konfiguráció..."
    
    # Enable mod_substitute if not already
    if ! apache2ctl -M 2>/dev/null | grep -q substitute; then
        a2enmod substitute >/dev/null 2>&1
        log_ok "Apache mod_substitute engedélyezve"
    else
        log_ok "Apache mod_substitute már aktív"
    fi

    # Create Apache config that injects timer.js via the ISPConfig vhost
    # We use conf-available which is a standard Apache include dir
    cat > "$APACHE_CONF" << 'APACHECONF'
# Shell Timer - ISPConfig Integration
# Injects timer.js into ISPConfig panel pages
# This file is NOT touched by ISPConfig updates.
#
# How it works:
#   mod_substitute replaces </head> with <script>+</head>
#   in HTML responses served on port 8080 (ISPConfig panel).

<IfModule mod_substitute.c>
    # Only apply to ISPConfig panel (port 8080)
    # Applied via ISPConfig vhost - see below
</IfModule>
APACHECONF
    log_ok "Apache config: $APACHE_CONF"

    # Inject into ISPConfig vhost (port 8080)
    local VHOST="/etc/apache2/sites-available/ispconfig.vhost"
    local VHOST_CONF=""
    
    # Find the actual ISPConfig vhost file
    if [ -f "$VHOST" ]; then
        VHOST_CONF="$VHOST"
    elif [ -f "/etc/apache2/sites-available/ispconfig.conf" ]; then
        VHOST_CONF="/etc/apache2/sites-available/ispconfig.conf"
    elif [ -f "/etc/apache2/sites-enabled/000-ispconfig.vhost" ]; then
        VHOST_CONF="/etc/apache2/sites-enabled/000-ispconfig.vhost"
    fi

    if [ -n "$VHOST_CONF" ]; then
        if grep -q "shell-timer-integration" "$VHOST_CONF" 2>/dev/null; then
            log_ok "ISPConfig vhost már konfigurálva"
        else
            # Backup
            cp "$VHOST_CONF" "${VHOST_CONF}.bak.$(date +%Y%m%d%H%M%S)"
            
            # Insert mod_substitute directive before </VirtualHost>
            # SetEnv no-gzip 1 + INFLATE;SUBSTITUTE;DEFLATE chain: ezek nélkül
            # az ISPConfig panel gzip-pelt HTML-jén a Substitute nem hat.
            sed -i '/<\/VirtualHost>/i \
\
    # --- Shell Timer Integration (do not remove) ---\
    # shell-timer-integration\
    SetEnv no-gzip 1\
    <IfModule mod_substitute.c>\
        AddOutputFilterByType INFLATE;SUBSTITUTE;DEFLATE text/html\
        Substitute "s|</head>|<script src=\\x27/shell_timer/timer.js?v=2\\x27 defer></script></head>|ni"\
    </IfModule>' "$VHOST_CONF"
            
            log_ok "ISPConfig vhost frissítve: $VHOST_CONF"
        fi
    else
        log_warn "ISPConfig vhost nem található!"
        log_warn "Add hozzá manuálisan a </VirtualHost> elé:"
        echo ""
        echo '    <IfModule mod_substitute.c>'
        echo '        AddOutputFilterByType SUBSTITUTE text/html'
        echo "        Substitute \"s|</head>|<script src='/shell_timer/timer.js?v=1' defer></script></head>|ni\""
        echo '    </IfModule>'
        echo ""
    fi

    # --- 3. Sudoers ---
    echo ""
    echo "3. Jogosultságok beállítása..."
    cat > "$SUDOERS_FILE" << 'SUDOERS'
# Shell Timer - ISPConfig Integration
# Allow ISPConfig web process to manage shell access
www-data ALL=(root) NOPASSWD: /usr/local/shell-access-manager/enable-shell-user.sh
www-data ALL=(root) NOPASSWD: /usr/local/shell-access-manager/disable-shell-user.sh
www-data ALL=(root) NOPASSWD: /usr/local/shell-access-manager/status.sh
SUDOERS
    chmod 440 "$SUDOERS_FILE"
    
    if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
        log_ok "Sudoers: $SUDOERS_FILE"
    else
        log_err "Sudoers szintaxis hiba!"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi

    # --- 4. State dir permissions ---
    echo ""
    echo "4. Jogosultságok ellenőrzése..."
    local state_dir="/var/lib/shell-access-manager"
    if [ -d "$state_dir" ]; then
        chmod 755 "$state_dir"
        chmod 644 "$state_dir"/* 2>/dev/null || true
        log_ok "State dir olvasható: $state_dir"
    fi

    # --- 5. Restart Apache ---
    echo ""
    echo "5. Apache újraindítása..."
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        systemctl reload apache2
        log_ok "Apache újraindítva"
    else
        log_err "Apache config hiba! Ellenőrizd: apache2ctl configtest"
        exit 1
    fi

    # --- Done ---
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ✅ Telepítés kész!                                  ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║                                                      ║"
    echo "║  Nyisd meg: https://srv.knh.hu:8080                  ║"
    echo "║  Sites → SSH-User → bármelyik user                   ║"
    echo "║  → Timer panel automatikusan megjelenik!              ║"
    echo "║                                                      ║"
    echo "║  Dashboard: Sites menüben → 'Shell Timer' link       ║"
    echo "║                                                      ║"
    echo "║  ⭐ ISPConfig frissítés után:                         ║"
    echo "║     SEMMI TEENDŐ! Minden automatikusan működik.      ║"
    echo "║                                                      ║"
    echo "║  Módosított ISPConfig fájlok: NULLA                  ║"
    echo "║  Csak a vhost-ba került 1 Apache direktíva.          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    
    do_status
}

# ============================================================
# UNINSTALL
# ============================================================
do_uninstall() {
    echo ""
    echo "Shell Timer eltávolítása..."
    echo ""

    # --- Disable & remove watchdog (must be BEFORE removing files,
    #     otherwise the watchdog races us and re-installs them) ---
    for unit in shell-timer-watchdog.path shell-timer-watchdog.timer shell-timer-watchdog.service; do
        if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
        fi
    done
    rm -f /etc/systemd/system/shell-timer-watchdog.path \
          /etc/systemd/system/shell-timer-watchdog.service \
          /etc/systemd/system/shell-timer-watchdog.timer
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/shell-access-manager/ispconfig-redeploy.sh
    rm -rf /usr/local/shell-access-manager/ispconfig-templates
    log_ok "Watchdog eltávolítva (systemd units + templates)"

    # Remove web files
    if [ -d "$SHELL_TIMER_DIR" ]; then
        rm -rf "$SHELL_TIMER_DIR"
        log_ok "Eltávolítva: $SHELL_TIMER_DIR"
    fi

    # Remove Apache config
    if [ -f "$APACHE_CONF" ]; then
        rm -f "$APACHE_CONF"
        log_ok "Eltávolítva: $APACHE_CONF"
    fi

    # Remove from ISPConfig vhost
    for vhost in /etc/apache2/sites-available/ispconfig.vhost /etc/apache2/sites-available/ispconfig.conf; do
        if [ -f "$vhost" ]; then
            # Backup, then strip every known shell-timer leftover (legacy v1, v2 Include, marker)
            cp "$vhost" "${vhost}.bak.uninstall.$(date +%Y%m%d%H%M%S)"
            sed -i '/Shell Timer Integration/,/<\/IfModule>/d' "$vhost"
            sed -i '\|Include conf-available/shell-timer\.conf|d' "$vhost"
            sed -i '/shell-timer-integration/d' "$vhost"
            # Clean up consecutive empty lines
            sed -i '/^$/N;/^\n$/d' "$vhost"
            log_ok "Vhost megtisztítva: $vhost"
        fi
    done

    # Remove sudoers
    if [ -f "$SUDOERS_FILE" ]; then
        rm -f "$SUDOERS_FILE"
        log_ok "Eltávolítva: $SUDOERS_FILE"
    fi

    # Reload Apache
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        systemctl reload apache2
        log_ok "Apache újratöltve"
    fi

    echo ""
    log_ok "Eltávolítás kész!"
    echo ""
}

# ============================================================
# STATUS
# ============================================================
do_status() {
    echo ""
    echo "  Shell Timer - Állapot"
    echo "  ====================="
    echo ""
    
    echo "  Fájlok:"
    for f in "$SHELL_TIMER_DIR/api.php" "$SHELL_TIMER_DIR/timer.js" "$SHELL_TIMER_DIR/dashboard.php"; do
        [ -f "$f" ] && log_ok "$f" || log_err "$f"
    done
    [ -f "$SUDOERS_FILE" ] && log_ok "$SUDOERS_FILE" || log_err "$SUDOERS_FILE"

    echo ""
    echo "  Apache:"
    if apache2ctl -M 2>/dev/null | grep -q substitute; then
        log_ok "mod_substitute aktív"
    else
        log_err "mod_substitute NEM aktív"
    fi
    
    local found_vhost=""
    for vhost in /etc/apache2/sites-available/ispconfig.vhost /etc/apache2/sites-available/ispconfig.conf; do
        if [ -f "$vhost" ] && grep -q "shell-timer-integration" "$vhost" 2>/dev/null; then
            log_ok "Vhost injection: $vhost"
            found_vhost="1"
        fi
    done
    [ -z "$found_vhost" ] && log_err "Vhost injection: NINCS"

    echo ""
    echo "  Shell Access Manager:"
    [ -d "$SHELL_MANAGER_DIR" ] && log_ok "$SHELL_MANAGER_DIR" || log_err "$SHELL_MANAGER_DIR"
    [ -d "/var/lib/shell-access-manager" ] && log_ok "State dir létezik" || log_err "State dir hiányzik"
    
    local active_count=$(ls /var/lib/shell-access-manager/*.enabled 2>/dev/null | wc -l)
    log_info "Aktív timer: ${active_count} db"
    
    echo ""
}

# ============================================================
# Main
# ============================================================
case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)
        echo "Használat: $0 [install|uninstall|status]"
        echo ""
        echo "  install    Telepítés (ISPConfig fájlokat NEM módosít)"
        echo "  uninstall  Eltávolítás"
        echo "  status     Állapot ellenőrzés"
        exit 1
        ;;
esac
