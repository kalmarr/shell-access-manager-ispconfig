#!/bin/bash
# ============================================================
# Shell Access Manager for ISPConfig - Idle Monitor (Cron Job)
#
# Crontab: */10 * * * * /usr/local/shell-access-manager/monitor-idle-users.sh
#
# Tasks:
#   1. Check all active shell users
#   2. Idle limit exceeded -> disable
#   3. Hard limit exceeded -> disable (backup for at-job)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib-functions.sh"

# Lock file - prevent concurrent execution
LOCK_FILE="/tmp/shell-access-monitor.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log WARN "Monitor already running, skipping"; exit 0; }

NOW_EPOCH=$(date +%s)
USERS_CHECKED=0
USERS_DISABLED=0

log INFO "=== Idle monitor scan started ==="

ACTIVE_USERS=$(get_active_shell_users)

if [ -z "$ACTIVE_USERS" ]; then
    log INFO "No active shell users found"
    exit 0
fi

while IFS=$'\t' read -r SHELL_USER_ID USERNAME SYS_USERID CLIENT_ID; do
    USERS_CHECKED=$((USERS_CHECKED + 1))

    LAST_ACTIVITY=$(get_last_ssh_activity "$USERNAME")

    if [ "$LAST_ACTIVITY" = "ACTIVE" ]; then
        log INFO "  $USERNAME: active SSH session - skip"

        # Check hard limit even for active sessions
        ENABLED_FILE="${STATE_DIR}/${USERNAME}.enabled"
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
                fi
            fi
        fi
        continue
    fi

    # No activity data? Use enable timestamp
    if [ "$LAST_ACTIVITY" = "0" ]; then
        ENABLED_FILE="${STATE_DIR}/${USERNAME}.enabled"
        if [ -f "$ENABLED_FILE" ]; then
            LAST_ACTIVITY=$(cat "$ENABLED_FILE")
            log INFO "  $USERNAME: never logged in, using enable time as reference"
        else
            log INFO "  $USERNAME: no activity data, no state file - skip"
            continue
        fi
    fi

    IDLE_SECONDS=$((NOW_EPOCH - LAST_ACTIVITY))
    IDLE_HUMAN=$(seconds_to_human "$IDLE_SECONDS")

    # --- Idle limit check ---
    if [ "$IDLE_SECONDS" -ge "$IDLE_LIMIT" ]; then
        log WARN "  $USERNAME: IDLE LIMIT exceeded (${IDLE_HUMAN} >= $(seconds_to_human $IDLE_LIMIT))"
        "${SCRIPT_DIR}/disable-shell-user.sh" "$USERNAME" "idle-timeout"
        USERS_DISABLED=$((USERS_DISABLED + 1))
        continue
    fi

    # --- Hard limit check ---
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

    # --- User OK ---
    REMAINING_IDLE=$((IDLE_LIMIT - IDLE_SECONDS))
    log INFO "  $USERNAME: OK (idle: ${IDLE_HUMAN}, remaining: $(seconds_to_human $REMAINING_IDLE))"

done <<< "$ACTIVE_USERS"

log INFO "=== Scan complete: checked=$USERS_CHECKED, disabled=$USERS_DISABLED ==="

if [ "$USERS_DISABLED" -gt 0 ]; then
    notify "Monitor: $USERS_DISABLED user(s) disabled" \
        "Idle monitor disabled $USERS_DISABLED shell user(s).\nTime: $(date '+%Y-%m-%d %H:%M:%S')\nDetails: $LOG_FILE" \
        "disable"
fi
