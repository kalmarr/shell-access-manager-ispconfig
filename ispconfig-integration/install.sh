#!/bin/bash
# ============================================================
# Shell Timer - ISPConfig Integration Installer
#
# ZERO ISPConfig files modified!
# Uses Apache mod_substitute to inject JS, and a systemd watchdog to restore
# the plugin after an ISPConfig update.
#
# Usage: sudo ./install.sh [install|uninstall|status]
# ============================================================

set -euo pipefail

ISPCONFIG_WEB="/usr/local/ispconfig/interface/web"
SHELL_TIMER_DIR="${ISPCONFIG_WEB}/shell_timer"
SHELL_MANAGER_DIR="/usr/local/shell-access-manager"
TEMPLATES_DIR="${SHELL_MANAGER_DIR}/ispconfig-templates"
SUDOERS_FILE="/etc/sudoers.d/shell-timer"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Legacy leftovers from the conf-available/cron variant of this integration.
LEGACY_APACHE_CONF="/etc/apache2/conf-available/shell-timer.conf"
LEGACY_CRON="/etc/cron.d/shell-timer-selfheal"
LEGACY_SELFHEAL="${SHELL_MANAGER_DIR}/shell-timer-selfheal.sh"
LEGACY_MASTER_DIR="${SHELL_MANAGER_DIR}/ispconfig-integration"

RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; CYAN='\e[36m'; NC='\e[0m'
log_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $*"; }
log_err()  { echo -e "  ${RED}✗${NC} $*"; }
log_info() { echo -e "  ${CYAN}→${NC} $*"; }

# Shared vhost/Apache helpers - see ispconfig-integration/lib-apache.sh
ST_MANAGER_DIR="$SHELL_MANAGER_DIR"
ST_PANEL_DIR="$SHELL_TIMER_DIR"
if [ -f "${SCRIPT_DIR}/lib-apache.sh" ]; then
    . "${SCRIPT_DIR}/lib-apache.sh"
elif [ -f "${SHELL_MANAGER_DIR}/lib-apache.sh" ]; then
    . "${SHELL_MANAGER_DIR}/lib-apache.sh"
else
    echo "ERROR: lib-apache.sh not found next to $0" >&2
    exit 1
fi

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
    chown -R ispconfig:ispconfig "$SHELL_TIMER_DIR" 2>/dev/null || true
    chmod 755 "$SHELL_TIMER_DIR"
    chmod 644 "$SHELL_TIMER_DIR"/*
    log_ok "Fájlok: $SHELL_TIMER_DIR/"

    # --- 2. Remove the older conf-available/cron variant ---
    # It injected from conf-enabled and re-ran itself from a daily cron job.
    # Left in place it fights the watchdog and can inject the script twice.
    echo ""
    echo "2. Örökölt mechanizmus eltakarítása..."
    local legacy_found=0
    if [ -e /etc/apache2/conf-enabled/shell-timer.conf ] || [ -f "$LEGACY_APACHE_CONF" ]; then
        a2disconf shell-timer >/dev/null 2>&1 || true
        rm -f "$LEGACY_APACHE_CONF" /etc/apache2/conf-enabled/shell-timer.conf
        log_ok "conf-available/conf-enabled shell-timer.conf eltávolítva"
        legacy_found=1
    fi
    for f in "$LEGACY_CRON" "$LEGACY_SELFHEAL"; do
        if [ -f "$f" ]; then rm -f "$f"; log_ok "Eltávolítva: $f"; legacy_found=1; fi
    done
    if [ -d "$LEGACY_MASTER_DIR" ] && [ "$SCRIPT_DIR" != "$LEGACY_MASTER_DIR" ]; then
        rm -rf "$LEGACY_MASTER_DIR"
        log_ok "Eltávolítva: $LEGACY_MASTER_DIR"
        legacy_found=1
    fi
    [ "$legacy_found" -eq 0 ] && log_ok "Nincs örökölt maradék"

    # --- 3. Apache ---
    echo ""
    echo "3. Apache konfiguráció..."

    if ! apache2ctl -M 2>/dev/null | grep -q substitute; then
        a2enmod substitute >/dev/null 2>&1
        log_ok "Apache mod_substitute engedélyezve"
    else
        log_ok "Apache mod_substitute már aktív"
    fi

    local swept
    swept=$(st_sweep_stray_backups)
    [ -n "$swept" ] && log_warn "Apache által beolvasott mentés áthelyezve: $swept -> $ST_BACKUP_DIR/"

    # Apache only reads sites-enabled. Writing into whichever candidate happens
    # to exist first put the injection into a dead sites-available copy, and the
    # marker check then reported success from that same dead file.
    local vhost live_seen=0
    while IFS= read -r vhost; do
        [ -n "$vhost" ] || continue
        if st_vhost_is_live "$vhost"; then
            log_info "Élő vhost (Apache ezt olvassa): $vhost"
            live_seen=1
        else
            log_info "Nem élő másolat, a teljesség kedvéért: $vhost"
        fi
    done <<EOF
$(st_vhost_candidates)
EOF
    if [ "$live_seen" -eq 0 ]; then
        log_err "Egyetlen ISPConfig vhost sincs a sites-enabled alatt!"
        exit 1
    fi

    local hash changed
    hash=$(st_asset_hash "$SHELL_TIMER_DIR/timer.js")
    changed=$(st_sync_vhosts "$hash") || { log_err "A vhost injektálás nem sikerült"; exit 1; }
    if [ -n "$changed" ]; then
        echo "$changed" | while IFS= read -r line; do [ -n "$line" ] && log_ok "Vhost $line"; done
    else
        log_ok "Minden vhost naprakész (timer.js?v=$hash)"
    fi

    # --- 4. Sudoers ---
    echo ""
    echo "4. Jogosultságok beállítása..."
    local panel_user
    panel_user=$(st_detect_panel_user)
    log_info "A panel PHP-ja ezen a néven fut: $panel_user"

    if st_write_sudoers "$SUDOERS_FILE" "$panel_user"; then
        log_ok "Sudoers: $SUDOERS_FILE"
    else
        log_err "Sudoers szintaxis hiba!"
        exit 1
    fi

    # An existing sudoers file proves nothing: the previous version granted
    # www-data while the panel runs as ispconfig, so every action failed with
    # "sudo: a password is required".
    if st_check_sudo_for "$panel_user"; then
        log_ok "sudo próba sikeres: $panel_user jelszó nélkül futtathatja a szkripteket"
    else
        log_err "sudo próba SIKERTELEN: $panel_user nem tudja jelszó nélkül futtatni a szkripteket!"
        exit 1
    fi

    # --- 5. State dir + published limits ---
    echo ""
    echo "5. Állapotkönyvtár és limitek..."
    local state_dir="/var/lib/shell-access-manager"
    if [ -d "$state_dir" ]; then
        chmod 755 "$state_dir"
        chmod 644 "$state_dir"/* 2>/dev/null || true
        log_ok "State dir olvasható: $state_dir"
    fi
    write_panel_limits

    # --- 6. Watchdog ---
    echo ""
    echo "6. Frissítés-biztos watchdog..."
    install_watchdog

    # --- 7. Reload + prove it ---
    echo ""
    echo "7. Apache újratöltése..."
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        systemctl reload apache2
        log_ok "Apache újratöltve"
    else
        log_err "Apache config hiba! Ellenőrizd: apache2ctl configtest"
        exit 1
    fi

    local port count
    port=$(st_panel_port)
    count=$(st_injection_count "$port")
    if [ "$count" -eq 1 ]; then
        log_ok "Élő ellenőrzés: a timer.js pontosan 1x szerepel a panel HTML-jében (port $port)"
    elif [ "$count" -eq 0 ]; then
        log_err "Élő ellenőrzés: a timer.js NEM szerepel a panel HTML-jében (port $port)!"
        log_err "A dashboard link és a timer panel így nem jelenik meg."
        exit 1
    else
        log_err "Élő ellenőrzés: a timer.js ${count}x szerepel - kettős injektálás!"
        exit 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ✅ Telepítés kész!                                  ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Sites → SSH-User → bármelyik user: timer panel      ║"
    echo "║  Sites menü → 'Shell Timer': dashboard              ║"
    echo "║  A dashboardon több user egyszerre kijelölhető.     ║"
    echo "║                                                      ║"
    echo "║  ⭐ ISPConfig frissítés után: SEMMI TEENDŐ.          ║"
    echo "║     A watchdog percen belül visszaállítja.          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    do_status
}

# ============================================================
# Watchdog + template store
#
# The watchdog restores the panel files from ispconfig-templates/. Only the
# repo-root install.sh used to refresh that store, so running this installer
# alone left stale templates behind and the watchdog reverted every deploy
# within the hour. Refresh them here.
# ============================================================
install_watchdog() {
    local wd="${SCRIPT_DIR}/watchdog"
    if [ ! -d "$wd" ]; then
        log_warn "Watchdog forrás nem található: $wd - kihagyva"
        return 0
    fi

    mkdir -p "$TEMPLATES_DIR"
    cp "$SHELL_TIMER_DIR/api.php"       "$TEMPLATES_DIR/"
    cp "$SHELL_TIMER_DIR/timer.js"      "$TEMPLATES_DIR/"
    cp "$SHELL_TIMER_DIR/dashboard.php" "$TEMPLATES_DIR/"
    chmod 644 "$TEMPLATES_DIR"/*
    log_ok "Sablonok frissítve: $TEMPLATES_DIR"

    install -m 0644 "${SCRIPT_DIR}/lib-apache.sh" "${SHELL_MANAGER_DIR}/lib-apache.sh"
    install -m 0755 "${wd}/ispconfig-redeploy.sh" "${SHELL_MANAGER_DIR}/ispconfig-redeploy.sh"
    install -m 0644 "${wd}/shell-timer-watchdog.path"    /etc/systemd/system/
    install -m 0644 "${wd}/shell-timer-watchdog.service" /etc/systemd/system/
    install -m 0644 "${wd}/shell-timer-watchdog.timer"   /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now shell-timer-watchdog.path  >/dev/null 2>&1 || true
    systemctl enable --now shell-timer-watchdog.timer >/dev/null 2>&1 || true
    log_ok "Redeploy script + systemd path/timer unit aktív"
}

# shell-access-manager.conf is 0600 root, so the panel process cannot read the
# limits and would silently show the built-in defaults. Publish just those two
# numbers world-readable next to the state files.
write_panel_limits() {
    local conf="${SHELL_MANAGER_DIR}/shell-access-manager.conf"
    local out="/var/lib/shell-access-manager/panel-limits.conf"
    local idle hard
    [ -f "$conf" ] || return 0
    idle=$(grep -oP '^[[:space:]]*IDLE_LIMIT=\K[0-9]+' "$conf" 2>/dev/null | tail -1 || true)
    hard=$(grep -oP '^[[:space:]]*HARD_LIMIT=\K[0-9]+' "$conf" 2>/dev/null | tail -1 || true)
    [ -n "$idle" ] || idle=10800
    [ -n "$hard" ] || hard=28800
    printf '# Generated by install.sh from %s\n# Read-only copy of the limits for the ISPConfig panel.\nIDLE_LIMIT=%s\nHARD_LIMIT=%s\n' \
        "$conf" "$idle" "$hard" > "$out"
    chmod 644 "$out"
    log_ok "Panel limitek: IDLE=${idle}s HARD=${hard}s -> $out"
    return 0
}

# ============================================================
# UNINSTALL
# ============================================================
do_uninstall() {
    echo ""
    echo "Shell Timer eltávolítása..."
    echo ""

    # Watchdog first, otherwise it races us and re-installs everything.
    local unit
    for unit in shell-timer-watchdog.path shell-timer-watchdog.timer shell-timer-watchdog.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
    rm -f /etc/systemd/system/shell-timer-watchdog.path \
          /etc/systemd/system/shell-timer-watchdog.service \
          /etc/systemd/system/shell-timer-watchdog.timer
    systemctl daemon-reload 2>/dev/null || true
    rm -f "${SHELL_MANAGER_DIR}/ispconfig-redeploy.sh" "${SHELL_MANAGER_DIR}/lib-apache.sh"
    rm -rf "$TEMPLATES_DIR"
    log_ok "Watchdog eltávolítva (systemd unitok + sablonok)"

    [ -d "$SHELL_TIMER_DIR" ] && { rm -rf "$SHELL_TIMER_DIR"; log_ok "Eltávolítva: $SHELL_TIMER_DIR"; }

    a2disconf shell-timer >/dev/null 2>&1 || true
    rm -f "$LEGACY_APACHE_CONF" "$LEGACY_CRON" "$LEGACY_SELFHEAL"
    rm -rf "$LEGACY_MASTER_DIR"

    local vhost
    while IFS= read -r vhost; do
        [ -n "$vhost" ] || continue
        if st_has_block "$vhost"; then
            st_backup_config "$vhost" ".uninstall"
            st_remove_block "$vhost"
            log_ok "Vhost megtisztítva: $vhost"
        fi
    done <<EOF
$(st_vhost_candidates)
EOF

    [ -f "$SUDOERS_FILE" ] && { rm -f "$SUDOERS_FILE"; log_ok "Eltávolítva: $SUDOERS_FILE"; }

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
    local f
    for f in "$SHELL_TIMER_DIR/api.php" "$SHELL_TIMER_DIR/timer.js" "$SHELL_TIMER_DIR/dashboard.php"; do
        [ -f "$f" ] && log_ok "$f" || log_err "$f"
    done

    echo ""
    echo "  Watchdog:"
    if [ -d "$TEMPLATES_DIR" ]; then
        local stale=0
        for f in api.php timer.js dashboard.php; do
            if [ -f "$TEMPLATES_DIR/$f" ] && [ -f "$SHELL_TIMER_DIR/$f" ] && ! cmp -s "$TEMPLATES_DIR/$f" "$SHELL_TIMER_DIR/$f"; then
                log_err "Sablon eltér a telepítettől: $f (a watchdog vissza fogja állítani!)"
                stale=1
            fi
        done
        [ "$stale" -eq 0 ] && log_ok "Sablonok egyeznek a telepített fájlokkal"
    else
        log_err "Sablonmappa hiányzik: $TEMPLATES_DIR"
    fi
    local u
    for u in shell-timer-watchdog.path shell-timer-watchdog.timer; do
        if [ "$(systemctl is-active "$u" 2>/dev/null || true)" = "active" ]; then
            log_ok "$u aktív"
        else
            log_err "$u NEM aktív"
        fi
    done

    echo ""
    echo "  Jogosultság:"
    [ -f "$SUDOERS_FILE" ] && log_ok "$SUDOERS_FILE" || log_err "$SUDOERS_FILE"
    local panel_user
    panel_user=$(st_detect_panel_user)
    log_info "Panel felhasználó: $panel_user"
    if st_check_sudo_for "$panel_user"; then
        log_ok "sudo jogosultság él: $panel_user (jelszó nélkül)"
    else
        log_err "sudo jogosultság HIÁNYZIK: $panel_user - a panelről nem indítható a shell"
        log_info "Javítás: sudo bash $0 install"
    fi

    echo ""
    echo "  Apache:"
    if apache2ctl -M 2>/dev/null | grep -q substitute; then
        log_ok "mod_substitute aktív"
    else
        log_err "mod_substitute NEM aktív"
    fi
    if [ -e /etc/apache2/conf-enabled/shell-timer.conf ]; then
        log_warn "Örökölt conf-enabled/shell-timer.conf még aktív - futtasd újra az install-t"
    fi

    local vhost hash
    hash=$(st_asset_hash "$SHELL_TIMER_DIR/timer.js")
    while IFS= read -r vhost; do
        [ -n "$vhost" ] || continue
        local live="nem élő" bh
        st_vhost_is_live "$vhost" && live="ÉLŐ"
        bh=$(st_block_hash "$vhost")
        if st_has_block "$vhost"; then
            if [ "$bh" = "$hash" ]; then
                log_ok "[$live] $vhost (v=$bh)"
            else
                log_warn "[$live] $vhost elavult hash: v=$bh, elvárt v=$hash"
            fi
        else
            log_err "[$live] $vhost - nincs benne injektálás"
        fi
    done <<EOF
$(st_vhost_candidates)
EOF

    echo ""
    echo "  Élő ellenőrzés:"
    local port count
    port=$(st_panel_port)
    count=$(st_injection_count "$port")
    log_info "Panel port: $port"
    if [ "$count" -eq 1 ]; then
        log_ok "A timer.js pontosan 1x szerepel a panel HTML-jében"
    elif [ "$count" -eq 0 ]; then
        log_err "A timer.js NEM szerepel a panel HTML-jében - nincs dashboard link!"
    else
        log_err "A timer.js ${count}x szerepel - kettős injektálás!"
    fi

    echo ""
    echo "  Shell Access Manager:"
    [ -d "$SHELL_MANAGER_DIR" ] && log_ok "$SHELL_MANAGER_DIR" || log_err "$SHELL_MANAGER_DIR"
    [ -d "/var/lib/shell-access-manager" ] && log_ok "State dir létezik" || log_err "State dir hiányzik"
    local active_count
    active_count=$(ls /var/lib/shell-access-manager/*.enabled 2>/dev/null | wc -l || true)
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
        echo "  status     Állapot ellenőrzés élő injektálás-teszttel"
        exit 1
        ;;
esac
