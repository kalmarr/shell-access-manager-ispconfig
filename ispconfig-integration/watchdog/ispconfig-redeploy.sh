#!/bin/bash
# ============================================================
# Shell Timer Watchdog - Idempotent redeploy script
#
# Restores /usr/local/ispconfig/interface/web/shell_timer/{api,timer,dashboard}
# from the stable source at /usr/local/shell-access-manager/ispconfig-templates/
# whenever the ISPConfig updater has wiped them.
#
# Invoked by:
#   - shell-timer-watchdog.path  (reactive: when version.inc.php changes OR
#                                 api.php disappears)
#   - shell-timer-watchdog.timer (fallback: hourly safety net)
#
# Idempotent: if everything is in place and matches the templates, exits
# without touching anything and without reloading Apache.
# ============================================================

set -uo pipefail
# NOTE: no `-e` — we want best-effort behavior; a missing template should
# log a warning and exit 0, not crash the systemd unit.

TEMPLATES="/usr/local/shell-access-manager/ispconfig-templates"
TARGET="/usr/local/ispconfig/interface/web/shell_timer"
VHOST_MARKER="shell-timer-integration"
SUDOERS_FILE="/etc/sudoers.d/shell-timer"
FILES=(api.php timer.js dashboard.php)

log() { logger -t shell-timer-watchdog "$*"; echo "$*"; }

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

# ---- 2. Restore each file if missing or differs from template ----
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
        if id ispconfig >/dev/null 2>&1; then
            chown ispconfig:ispconfig "$dst"
        fi
        log "Restored: $dst"
        changed=1
    fi
done

# ---- 3. Re-apply directory permissions (idempotent) ----
chmod 755 "$TARGET" 2>/dev/null || true
if id ispconfig >/dev/null 2>&1; then
    chown ispconfig:ispconfig "$TARGET" 2>/dev/null || true
fi

# ---- 4. Verify the Apache vhost still has the mod_substitute injection ----
vhost=""
for v in /etc/apache2/sites-available/ispconfig.vhost \
         /etc/apache2/sites-available/ispconfig.conf \
         /etc/apache2/sites-enabled/000-ispconfig.vhost; do
    [ -f "$v" ] && { vhost="$v"; break; }
done

if [ -n "$vhost" ] && ! grep -q "$VHOST_MARKER" "$vhost" 2>/dev/null; then
    cp "$vhost" "${vhost}.bak.watchdog.$(date +%Y%m%d%H%M%S)"
    # First strip any legacy v2 Include directive that points at a now-gone
    # conf-available/shell-timer.conf — otherwise apache2ctl configtest fails.
    sed -i '\|Include conf-available/shell-timer\.conf|d' "$vhost"
    # Now inject the correct mod_substitute block (INFLATE chain + no-gzip)
    sed -i '/<\/VirtualHost>/i \
\
    # --- Shell Timer Integration (do not remove) ---\
    # shell-timer-integration\
    SetEnv no-gzip 1\
    <IfModule mod_substitute.c>\
        AddOutputFilterByType INFLATE;SUBSTITUTE;DEFLATE text/html\
        Substitute "s|</head>|<script src=\\x27/shell_timer/timer.js?v=2\\x27 defer></script></head>|ni"\
    </IfModule>' "$vhost"
    log "Re-injected vhost mod_substitute directive into $vhost"
    changed=1
fi

# ---- 5. Verify sudoers still in place ----
if [ ! -f "$SUDOERS_FILE" ]; then
    cat > "$SUDOERS_FILE" <<'SUDOERS'
# Shell Timer - ISPConfig Integration (restored by watchdog)
www-data ALL=(root) NOPASSWD: /usr/local/shell-access-manager/enable-shell-user.sh
www-data ALL=(root) NOPASSWD: /usr/local/shell-access-manager/disable-shell-user.sh
www-data ALL=(root) NOPASSWD: /usr/local/shell-access-manager/status.sh
SUDOERS
    chmod 440 "$SUDOERS_FILE"
    if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        log "Restored sudoers: $SUDOERS_FILE"
        changed=1
    else
        rm -f "$SUDOERS_FILE"
        log "ERROR: sudoers syntax check failed — removed $SUDOERS_FILE"
    fi
fi

# ---- 6. Reload Apache only if something actually changed ----
if [ "$changed" -eq 1 ]; then
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        systemctl reload apache2 && log "Apache reloaded after watchdog redeploy"
    else
        log "ERROR: apache2ctl configtest failed — Apache NOT reloaded"
    fi
else
    : # silent success — no log spam when nothing to do
fi

exit 0
