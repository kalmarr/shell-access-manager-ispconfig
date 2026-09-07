#!/bin/bash
# ============================================================
# Shell Timer Watchdog - Idempotent redeploy script
#
# Restores /usr/local/ispconfig/interface/web/shell_timer/{api,timer,dashboard}
# from the stable source at /usr/local/shell-access-manager/ispconfig-templates/
# whenever the ISPConfig updater has wiped them, and makes sure the Apache
# injection is present in every vhost Apache actually reads.
#
# Invoked by:
#   - shell-timer-watchdog.path  (reactive: ISPConfig version file changes)
#   - shell-timer-watchdog.timer (fallback: hourly safety net)
#
# Idempotent: if everything matches, exits without touching anything and
# without reloading Apache.
#
# The vhost, backup, sudoers and verification logic is shared with the
# installer via lib-apache.sh. It used to be duplicated here and drifted:
# both picked "the first candidate that exists", which on a host where
# sites-enabled/000-ispconfig.vhost is a real file wrote the injection into a
# dead sites-available copy and then reported success from that same file.
# ============================================================

set -uo pipefail

TEMPLATES="/usr/local/shell-access-manager/ispconfig-templates"
TARGET="/usr/local/ispconfig/interface/web/shell_timer"
SUDOERS_FILE="/etc/sudoers.d/shell-timer"
LIB="/usr/local/shell-access-manager/lib-apache.sh"
FILES=(api.php timer.js dashboard.php)

log() { logger -t shell-timer-watchdog "$*"; echo "$*"; }

if [ ! -f "$LIB" ]; then
    log "ERROR: shared library missing: $LIB — run the integration installer"
    exit 0
fi
ST_PANEL_DIR="$TARGET"
. "$LIB"

if [ ! -d "$TEMPLATES" ]; then
    log "ERROR: templates directory missing: $TEMPLATES — install incomplete?"
    exit 0
fi

if [ ! -d "/usr/local/ispconfig/interface/web" ]; then
    log "ISPConfig interface/web not present — skipping (not an ISPConfig host?)"
    exit 0
fi

changed=0

# ---- 1. Ensure target directory exists ----
if [ ! -d "$TARGET" ]; then
    mkdir -p "$TARGET"
    log "Created missing target directory: $TARGET"
    changed=1
fi

# ---- 2. Restore each file if missing or different from the template ----
for f in "${FILES[@]}"; do
    src="$TEMPLATES/$f"
    dst="$TARGET/$f"
    if [ ! -f "$src" ]; then
        log "WARN: template file missing: $src"
        continue
    fi
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
        cp -f "$src" "$dst"
        chmod 644 "$dst"
        id ispconfig >/dev/null 2>&1 && chown ispconfig:ispconfig "$dst"
        log "Restored: $dst"
        changed=1
    fi
done

# ---- 3. Directory permissions (idempotent) ----
chmod 755 "$TARGET" 2>/dev/null || true
id ispconfig >/dev/null 2>&1 && chown ispconfig:ispconfig "$TARGET" 2>/dev/null || true

# ---- 4. A stray *.bak in sites-enabled breaks the whole Apache config ----
swept=$(st_sweep_stray_backups)
if [ -n "$swept" ]; then
    log "Moved stray Apache backups out of sites-enabled:$swept"
    changed=1
fi

# ---- 5. Injection in every vhost Apache reads, with a current cache-buster ----
hash=$(st_asset_hash "$TARGET/timer.js")
synced=$(st_sync_vhosts "$hash")
if [ -n "$synced" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && log "Vhost $line (v=$hash)"
    done <<< "$synced"
    changed=1
fi

# ---- 6. Sudoers, for the user the panel actually runs as ----
panel_user=$(st_detect_panel_user)
if [ ! -f "$SUDOERS_FILE" ] || ! st_check_sudo_for "$panel_user"; then
    if st_write_sudoers "$SUDOERS_FILE" "$panel_user"; then
        log "Restored sudoers for $panel_user: $SUDOERS_FILE"
        changed=1
    else
        log "ERROR: sudoers syntax check failed — removed $SUDOERS_FILE"
    fi
fi

# ---- 7. Reload Apache only if something actually changed ----
if [ "$changed" -eq 1 ]; then
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        systemctl reload apache2 && log "Apache reloaded after watchdog redeploy"
    else
        log "ERROR: apache2ctl configtest failed — Apache NOT reloaded"
        exit 0
    fi

    # Prove the injection reaches the browser. Checking the config file only
    # tells you what you wrote, not what Apache serves.
    port=$(st_panel_port)
    count=$(st_injection_count "$port")
    if [ "$count" -ne 1 ]; then
        log "ERROR: timer.js appears ${count}x in the panel HTML on port ${port} (expected exactly 1)"
    fi
fi

exit 0
