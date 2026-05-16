#!/bin/bash
# ============================================================
# Shell Access Manager - Inaktivitás Monitor (Cron Job)
#
# Crontab: */10 * * * * /usr/local/shell-access-manager/monitor-idle-users.sh
#
# Feladatai:
#   1. Aktív shell userek ellenőrzése
#   2. Inaktivitási limit túllépés -> letiltás
#   3. Hard limit túllépés -> letiltás (backup az at job mellett)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib-functions.sh"

# Lock fájl - párhuzamos futás elkerülése
LOCK_FILE="/tmp/shell-access-monitor.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log WARN "Monitor already running, skipping"; exit 0; }

NOW_EPOCH=$(date +%s)
USERS_CHECKED=0
USERS_DISABLED=0

log INFO "=== Idle monitor scan started ==="

# Aktív shell userek lekérése
ACTIVE_USERS=$(get_active_shell_users)

if [ -z "$ACTIVE_USERS" ]; then
    log INFO "No active shell users found"
    exit 0
fi

while IFS=$'\t' read -r SHELL_USER_ID USERNAME SYS_USERID CLIENT_ID; do
    USERS_CHECKED=$((USERS_CHECKED + 1))

    # --- Inaktivitás ellenőrzés ---
    LAST_ACTIVITY=$(get_last_ssh_activity "$USERNAME")

    if [ "$LAST_ACTIVITY" = "ACTIVE" ]; then
        log INFO "  $USERNAME: active SSH session - skip idle check"

        ENABLED_FILE="${STATE_DIR}/${USERNAME}.enabled"

        # Auto-register web-enabled users (configurable)
        if [ ! -f "$ENABLED_FILE" ]; then
            if [ "${AUTO_REGISTER_WEB_USERS:-true}" = "true" ]; then
                log WARN "  $USERNAME: active session but no state file - auto-registering"
                echo "$NOW_EPOCH" > "${STATE_DIR}/${USERNAME}.enabled"
                echo "$HARD_LIMIT" > "${STATE_DIR}/${USERNAME}.hard_limit"
            else
                log INFO "  $USERNAME: no state file, AUTO_REGISTER_WEB_USERS=false - skip"
                # Still bump last_seen_active so a later toggle to true won't
                # treat the user as immediately idle.
                echo "$NOW_EPOCH" > "${STATE_DIR}/${USERNAME}.last_seen_active"
                continue
            fi
        fi

        # Hard limit check FIRST — absolute ceiling, fires even on active sessions
        if [ -f "$ENABLED_FILE" ]; then
            ENABLED_EPOCH=$(cat "$ENABLED_FILE")
            HARD_LIMIT_FILE="${STATE_DIR}/${USERNAME}.hard_limit"
            EFFECTIVE_HARD=$HARD_LIMIT
            [ -f "$HARD_LIMIT_FILE" ] && EFFECTIVE_HARD=$(cat "$HARD_LIMIT_FILE")

            if [ "$EFFECTIVE_HARD" -gt 0 ]; then
                ELAPSED=$((NOW_EPOCH - ENABLED_EPOCH))
                if [ "$ELAPSED" -ge "$EFFECTIVE_HARD" ]; then
                    log WARN "  $USERNAME: HARD LIMIT exceeded (${ELAPSED}s >= ${EFFECTIVE_HARD}s) even with active session!"
                    "${SCRIPT_DIR}/disable-shell-user.sh" "$USERNAME" "hard-limit-expired"
                    USERS_DISABLED=$((USERS_DISABLED + 1))
                    continue
                fi
            fi
        fi

        # Sliding window: record that we saw activity NOW.
        # When the user goes idle later, the idle timer counts from this
        # timestamp (not from their last login), so long active sessions
        # don't trigger instant disable on logout.
        echo "$NOW_EPOCH" > "${STATE_DIR}/${USERNAME}.last_seen_active"
        continue
    fi

    # Last activity = 0 -> soha nem lépett be, de a state fájlból nézzük
    if [ "$LAST_ACTIVITY" = "0" ]; then
        ENABLED_FILE="${STATE_DIR}/${USERNAME}.enabled"
        if [ -f "$ENABLED_FILE" ]; then
            LAST_ACTIVITY=$(cat "$ENABLED_FILE")
            log INFO "  $USERNAME: never logged in, using enable time as reference"
        else
            if [ "${AUTO_REGISTER_WEB_USERS:-true}" = "true" ]; then
                # AUTO-REGISTER: user enabled via web panel
                log WARN "  $USERNAME: active in DB but no state file - auto-registering now"
                echo "$NOW_EPOCH" > "${STATE_DIR}/${USERNAME}.enabled"
                echo "$HARD_LIMIT" > "${STATE_DIR}/${USERNAME}.hard_limit"
                LAST_ACTIVITY=$NOW_EPOCH
                log INFO "  $USERNAME: state file created, tracking starts (idle: ${IDLE_LIMIT}s, hard: ${HARD_LIMIT}s)"
            else
                log INFO "  $USERNAME: no activity data, no state file, AUTO_REGISTER_WEB_USERS=false - skip"
                continue
            fi
        fi
    fi

    IDLE_SECONDS=$((NOW_EPOCH - LAST_ACTIVITY))
    IDLE_HUMAN=$(seconds_to_human "$IDLE_SECONDS")

    # --- Inaktivitási limit ---
    if [ "$IDLE_SECONDS" -ge "$IDLE_LIMIT" ]; then
        log WARN "  $USERNAME: IDLE LIMIT exceeded (${IDLE_HUMAN} >= $(seconds_to_human $IDLE_LIMIT))"
        "${SCRIPT_DIR}/disable-shell-user.sh" "$USERNAME" "idle-timeout"
        USERS_DISABLED=$((USERS_DISABLED + 1))
        continue
    fi

    # --- Hard limit ---
    ENABLED_FILE="${STATE_DIR}/${USERNAME}.enabled"
    if [ -f "$ENABLED_FILE" ]; then
        ENABLED_EPOCH=$(cat "$ENABLED_FILE")
        HARD_LIMIT_FILE="${STATE_DIR}/${USERNAME}.hard_limit"
        EFFECTIVE_HARD=$HARD_LIMIT
        [ -f "$HARD_LIMIT_FILE" ] && EFFECTIVE_HARD=$(cat "$HARD_LIMIT_FILE")

        if [ "$EFFECTIVE_HARD" -gt 0 ]; then
            ELAPSED=$((NOW_EPOCH - ENABLED_EPOCH))
            if [ "$ELAPSED" -ge "$EFFECTIVE_HARD" ]; then
                log WARN "  $USERNAME: HARD LIMIT exceeded ($(seconds_to_human $ELAPSED) >= $(seconds_to_human $EFFECTIVE_HARD))"
                "${SCRIPT_DIR}/disable-shell-user.sh" "$USERNAME" "hard-limit-expired"
                USERS_DISABLED=$((USERS_DISABLED + 1))
                continue
            fi
        fi
    fi

    # --- Felhasználó OK ---
    REMAINING_IDLE=$((IDLE_LIMIT - IDLE_SECONDS))
    log INFO "  $USERNAME: OK (idle: ${IDLE_HUMAN}, remaining: $(seconds_to_human $REMAINING_IDLE))"

done <<< "$ACTIVE_USERS"

log INFO "=== Scan complete: checked=$USERS_CHECKED, disabled=$USERS_DISABLED ==="

# Ha volt letiltás, összefoglaló email
if [ "$USERS_DISABLED" -gt 0 ]; then
    notify "Monitor: $USERS_DISABLED user(s) disabled" \
        "Az idle monitor $USERS_DISABLED shell usert tiltott le.\nIdő: $(date '+%Y-%m-%d %H:%M:%S')\nRészletek: $LOG_FILE" \
        "disable"
fi
