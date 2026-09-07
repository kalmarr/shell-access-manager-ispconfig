#!/bin/bash
# ============================================================
# Shell Timer - shared Apache/vhost helpers
#
# Sourced by:
#   ispconfig-integration/install.sh
#   /usr/local/shell-access-manager/ispconfig-redeploy.sh  (the watchdog)
#
# Both used to carry their own copy of this logic and drifted apart, which is
# how the injection ended up in a file Apache never reads. Keep it in one place.
#
# Safe to source under both `set -euo pipefail` and `set -uo pipefail`.
# ============================================================

ST_VHOST_MARKER="shell-timer-integration"
ST_BACKUP_DIR="${ST_BACKUP_DIR:-/var/backups/shell-timer}"
ST_PANEL_DIR="${ST_PANEL_DIR:-/usr/local/ispconfig/interface/web/shell_timer}"
ST_MANAGER_DIR="${ST_MANAGER_DIR:-/usr/local/shell-access-manager}"

# ------------------------------------------------------------
# Which vhost files does Apache ACTUALLY read?
#
# Apache only includes sites-enabled. On a stock ISPConfig install
# sites-enabled/000-ispconfig.vhost is a symlink to sites-available, but it can
# equally be a real file, in which case sites-available/ispconfig.vhost is a
# dead copy. Picking "the first candidate that exists" therefore writes the
# injection into a file nobody reads, and every check that greps the same file
# happily reports success.
#
# Resolve every candidate with readlink -f, drop duplicates, and return the real
# files. Editing must always happen on the resolved path: sed -i replaces a
# symlink with a regular file, quietly forking the config.
#
# A candidate only counts if it really is the panel's vhost. The name is not
# enough: on some hosts sites-available/ispconfig.conf is ISPConfig's GLOBAL
# Apache config (ServerTokens, vlogger, NameVirtualHost lines) with no
# <VirtualHost> block at all, sitting next to the real ispconfig.vhost. Trying
# to inject into it fails, and parsing it for the port or the panel user finds
# nothing. So: must contain </VirtualHost> AND reference the panel docroot.
# ------------------------------------------------------------
st_is_panel_vhost() {
    local f="$1"
    [ -f "$f" ] || return 1
    grep -qi '</VirtualHost>' "$f" 2>/dev/null || return 1
    grep -q '/usr/local/ispconfig/interface/web\|/var/www/ispconfig' "$f" 2>/dev/null
}

st_vhost_candidates() {
    local v real seen=""
    for v in /etc/apache2/sites-enabled/000-ispconfig.vhost \
             /etc/apache2/sites-available/ispconfig.vhost \
             /etc/apache2/sites-available/ispconfig.conf; do
        [ -e "$v" ] || continue
        real=$(readlink -f "$v" 2>/dev/null || true)
        [ -n "$real" ] && [ -f "$real" ] || continue
        st_is_panel_vhost "$real" || continue
        case " $seen " in *" $real "*) continue ;; esac
        seen="$seen $real"
        printf '%s\n' "$real"
    done
}

# Is this resolved path reachable from sites-enabled, i.e. does Apache read it?
st_vhost_is_live() {
    local target="$1" v real
    for v in /etc/apache2/sites-enabled/*; do
        [ -e "$v" ] || continue
        real=$(readlink -f "$v" 2>/dev/null || true)
        [ "$real" = "$target" ] && return 0
    done
    return 1
}

# ------------------------------------------------------------
# Backups: never beside the original. Apache parses every file in sites-enabled,
# so a .bak copy there is read as a second vhost and takes the whole config down
# with "Cannot define multiple Listeners on the same IP:port".
# ------------------------------------------------------------
st_backup_config() {
    local src="$1" tag="${2:-}"
    mkdir -p "$ST_BACKUP_DIR"
    cp "$src" "${ST_BACKUP_DIR}/$(basename "$src").bak${tag}.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
}

st_sweep_stray_backups() {
    local dir="/etc/apache2/sites-enabled" f moved=""
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.bak "$dir"/*.bak.* "$dir"/*~; do
        [ -f "$f" ] || continue
        mkdir -p "$ST_BACKUP_DIR"
        mv "$f" "${ST_BACKUP_DIR}/$(basename "$f")" 2>/dev/null && moved="${moved} $(basename "$f")"
    done
    [ -n "$moved" ] && printf '%s\n' "${moved# }"
    return 0
}

# ------------------------------------------------------------
# Cache-busting hash of the deployed timer.js. A fixed ?v=2 means browsers keep
# a stale copy after every redeploy.
# ------------------------------------------------------------
st_asset_hash() {
    local f="${1:-${ST_PANEL_DIR}/timer.js}"
    if [ -f "$f" ]; then
        md5sum "$f" 2>/dev/null | cut -c1-10
    else
        echo "0"
    fi
}

# The hash currently baked into a vhost's injected block, empty if no block.
st_block_hash() {
    local vhost="$1"
    [ -f "$vhost" ] || return 0
    grep -o 'timer\.js?v=[A-Za-z0-9]*' "$vhost" 2>/dev/null | head -1 | sed 's/.*v=//' || true
}

st_has_block() {
    grep -q "$ST_VHOST_MARKER" "$1" 2>/dev/null
}

st_remove_block() {
    local vhost="$1"
    [ -f "$vhost" ] || return 0
    sed -i '/# --- Shell Timer Integration/,/<\/IfModule>/d' "$vhost"
    sed -i '\|Include conf-available/shell-timer\.conf|d' "$vhost"
    sed -i "/${ST_VHOST_MARKER}/d" "$vhost"
    sed -i '/^$/N;/^\n$/d' "$vhost"
    return 0
}

# ------------------------------------------------------------
# Insert the injection block before the first </VirtualHost>.
#
# Built with awk rather than a nested `sed i\` script: the block contains single
# quotes, double quotes and slashes, and the escaping in the old sed one-liner
# was unreadable and easy to break. Writing back with `cat >` keeps the inode,
# so a symlinked vhost stays a symlink.
#
# SetEnv no-gzip + INFLATE;SUBSTITUTE;DEFLATE are both required: mod_substitute
# cannot patch a compressed body, and the panel is served with compression on.
# ------------------------------------------------------------
st_inject_block() {
    local vhost="$1" hash="${2:-2}" tmp new sq="'"
    [ -f "$vhost" ] || return 1
    tmp=$(mktemp) || return 1
    {
        echo ""
        echo "    # --- Shell Timer Integration (do not remove) ---"
        echo "    # ${ST_VHOST_MARKER}"
        echo "    SetEnv no-gzip 1"
        echo "    <IfModule mod_substitute.c>"
        echo "        AddOutputFilterByType INFLATE;SUBSTITUTE;DEFLATE text/html"
        echo "        Substitute \"s|</head>|<script src=${sq}/shell_timer/timer.js?v=${hash}${sq} defer></script></head>|ni\""
        echo "    </IfModule>"
    } > "$tmp"

    new=$(mktemp) || { rm -f "$tmp"; return 1; }
    awk -v blockfile="$tmp" '
        BEGIN { while ((getline line < blockfile) > 0) block = block line "\n" }
        /<\/VirtualHost>/ && !inserted { printf "%s", block; inserted = 1 }
        { print }
        END { exit(inserted ? 0 : 1) }
    ' "$vhost" > "$new"
    local rc=$?
    if [ $rc -eq 0 ]; then
        cat "$new" > "$vhost"
    fi
    rm -f "$tmp" "$new"
    return $rc
}

# Make sure every real vhost carries the block with the current hash.
# Prints one "action path" line per file it touched.
st_sync_vhosts() {
    local hash="$1" vhost cur rc=0
    while IFS= read -r vhost; do
        [ -n "$vhost" ] || continue
        st_is_panel_vhost "$vhost" || continue
        cur=$(st_block_hash "$vhost")
        if st_has_block "$vhost" && [ "$cur" = "$hash" ]; then
            continue
        fi
        st_backup_config "$vhost"
        if st_has_block "$vhost"; then
            st_remove_block "$vhost"
            if st_inject_block "$vhost" "$hash"; then printf 'updated %s\n' "$vhost"; else rc=1; fi
        else
            if st_inject_block "$vhost" "$hash"; then printf 'injected %s\n' "$vhost"; else rc=1; fi
        fi
    done <<EOF
$(st_vhost_candidates)
EOF
    return $rc
}

# ------------------------------------------------------------
# The ISPConfig panel port is configurable at install time, so read it back.
# ------------------------------------------------------------
st_panel_port() {
    local port="" vhost
    while IFS= read -r vhost; do
        [ -n "$vhost" ] || continue
        port=$(grep -oP '<VirtualHost\s+_default_:\K[0-9]+' "$vhost" 2>/dev/null | head -1 || true)
        if [ -z "$port" ]; then
            port=$(sed -n 's/.*<VirtualHost[[:space:]]\+_default_:\([0-9]\+\).*/\1/p' "$vhost" 2>/dev/null | head -1 || true)
        fi
        [ -n "$port" ] && break
    done <<EOF
$(st_vhost_candidates)
EOF
    printf '%s' "${port:-8080}"
}

# How many times does the panel's own HTML reference timer.js?
# The only check that actually proves the integration is live. Exactly 1 is
# correct: 0 means no injection reaches the browser, 2 means two mechanisms are
# both active and the script would run twice.
st_injection_count() {
    local port="${1:-$(st_panel_port)}" body=""
    body=$(curl -sk --max-time 8 "https://127.0.0.1:${port}/login/" 2>/dev/null || true)
    if ! printf '%s' "$body" | grep -q "shell_timer/timer.js"; then
        local plain
        plain=$(curl -s --max-time 8 "http://127.0.0.1:${port}/login/" 2>/dev/null || true)
        printf '%s' "$plain" | grep -q "shell_timer/timer.js" && body="$plain"
    fi
    # grep -o exits 1 on zero matches; with pipefail that would make this
    # function fail and, under set -e, kill the caller at the assignment instead
    # of letting it report "0 injections". Swallow grep's status, count with wc.
    { printf '%s' "$body" | grep -o "shell_timer/timer.js" || true; } | wc -l
}

# ------------------------------------------------------------
# Which user does the panel's PHP run as? With mod_fcgid + suexec (the
# ISPConfig default) it is the vhost's SuexecUserGroup, normally "ispconfig",
# NOT www-data. Granting sudo to the wrong user leaves every panel action
# failing with "sudo: a password is required".
# ------------------------------------------------------------
st_detect_panel_user() {
    local vhost user=""
    while IFS= read -r vhost; do
        [ -n "$vhost" ] || continue
        user=$(grep -oP '^[[:space:]]*SuexecUserGroup[[:space:]]+\K[^[:space:]]+' "$vhost" 2>/dev/null | head -1 || true)
        [ -n "$user" ] && break
        user=$(grep -oP '^[[:space:]]*AssignUserId[[:space:]]+\K[^[:space:]]+' "$vhost" 2>/dev/null | head -1 || true)
        [ -n "$user" ] && break
    done <<EOF
$(st_vhost_candidates)
EOF

    # suexec runs the CGI as the owner of the starter script, so that is
    # authoritative when the vhost cannot be parsed.
    if [ -z "$user" ] && [ -f /var/www/php-fcgi-scripts/ispconfig/.php-fcgi-starter ]; then
        user=$(stat -c %U /var/www/php-fcgi-scripts/ispconfig/.php-fcgi-starter 2>/dev/null || true)
    fi

    [ -n "$user" ] || user="ispconfig"
    id -u "$user" >/dev/null 2>&1 || user="www-data"
    printf '%s' "$user"
}

st_check_sudo_for() {
    local user="$1" script="${ST_MANAGER_DIR}/enable-shell-user.sh"
    id -u "$user" >/dev/null 2>&1 || return 1
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- sudo -n -l "$script" >/dev/null 2>&1
    else
        su -s /bin/sh -c "sudo -n -l $(printf '%q' "$script")" "$user" >/dev/null 2>&1
    fi
}

st_write_sudoers() {
    local file="$1" panel_user="$2" u done_users=""
    rm -f "$file"
    {
        echo "# Shell Timer - ISPConfig Integration"
        echo "# Allow the ISPConfig panel process to manage shell access."
        echo "# With mod_fcgid + suexec the panel runs as the vhost's SuexecUserGroup"
        echo "# (normally ispconfig), not as www-data, so both are listed."
        for u in "$panel_user" www-data; do
            id -u "$u" >/dev/null 2>&1 || continue
            case " $done_users " in *" $u "*) continue ;; esac
            done_users="$done_users $u"
            echo "$u ALL=(root) NOPASSWD: ${ST_MANAGER_DIR}/enable-shell-user.sh"
            echo "$u ALL=(root) NOPASSWD: ${ST_MANAGER_DIR}/disable-shell-user.sh"
            echo "$u ALL=(root) NOPASSWD: ${ST_MANAGER_DIR}/status.sh"
        done
    } > "$file"
    chmod 440 "$file"
    if visudo -c -f "$file" >/dev/null 2>&1; then
        return 0
    fi
    rm -f "$file"
    return 1
}
