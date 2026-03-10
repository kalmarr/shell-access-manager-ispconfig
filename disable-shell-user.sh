#!/bin/bash
# ============================================================
# Shell Access Manager for ISPConfig - DISABLE Shell User
# Usage: ./disable-shell-user.sh <username> [reason]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib-functions.sh"

USERNAME="${1:-}"
REASON="${2:-manual}"

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username> [reason]"
    echo ""
    echo "Examples:  $0 web1"
    echo "           $0 web1 idle-timeout"
    echo "           $0 web1 hard-limit-expired"
    exit 1
fi

check_dependencies || exit 1

SHELL_USER_ID=$(get_shell_user_id "$USERNAME")
if [ -z "$SHELL_USER_ID" ]; then
    log ERROR "Shell user not found in ISPConfig: $USERNAME"
    exit 1
fi

log INFO "Disabling shell user: $USERNAME (ID: $SHELL_USER_ID, reason: $REASON)"

# --- API login ---
SESSION=$(api_login)
if [ -z "$SESSION" ]; then
    log ERROR "Cannot connect to ISPConfig API"
    log WARN "Falling back to direct DB update"
    mysql -e "UPDATE ${ISPCONFIG_DB}.shell_user SET
        active='n', chroot='jailkit',
        sys_updated=UNIX_TIMESTAMP(),
        sys_update_done='n'
        WHERE shell_user_id=${SHELL_USER_ID};" 2>/dev/null

    if [ $? -eq 0 ]; then
        log OK "Shell user $USERNAME disabled via DB fallback"
    else
        log ERROR "DB fallback also failed for $USERNAME"
        notify "CRITICAL: Cannot disable $USERNAME" \
            "API and DB fallback both failed!\nUser: $USERNAME\nReason: $REASON" \
            "error"
        exit 1
    fi
    SESSION=""
fi

trap '[ -n "$SESSION" ] && api_logout "$SESSION"' EXIT

# --- Disable via API ---
if [ -n "$SESSION" ]; then
    CLIENT_ID=0

    UPDATE_RESULT=$(api_update_shell_user "$SESSION" "$CLIENT_ID" "$SHELL_USER_ID" '{"active": "n", "chroot": "jailkit"}')
    UPDATE_OK=$(echo "$UPDATE_RESULT" | jq -r '.response // empty' 2>/dev/null)
    if [ -z "$UPDATE_OK" ] || [ "$UPDATE_OK" = "false" ]; then
        ERROR_MSG=$(echo "$UPDATE_RESULT" | jq -r '.message // "unknown"' 2>/dev/null)
        log ERROR "API update failed: $ERROR_MSG - trying DB fallback"
        mysql -e "UPDATE ${ISPCONFIG_DB}.shell_user SET
            active='n', chroot='jailkit',
            sys_updated=UNIX_TIMESTAMP(),
            sys_update_done='n'
            WHERE shell_user_id=${SHELL_USER_ID};" 2>/dev/null
    fi
fi

# --- Kill active SSH sessions ---
ACTIVE_PIDS=$(pgrep -u "$USERNAME" 2>/dev/null || true)
if [ -n "$ACTIVE_PIDS" ]; then
    log WARN "Killing active sessions for $USERNAME (PIDs: $ACTIVE_PIDS)"
    pkill -HUP -u "$USERNAME" 2>/dev/null || true
    sleep 2
    pkill -u "$USERNAME" 2>/dev/null || true
    sleep 1
    pkill -9 -u "$USERNAME" 2>/dev/null || true
fi

# --- Calculate uptime ---
ENABLED_FILE="${STATE_DIR}/${USERNAME}.enabled"
if [ -f "$ENABLED_FILE" ]; then
    ENABLED_EPOCH=$(cat "$ENABLED_FILE")
    DURATION=$(( $(date +%s) - ENABLED_EPOCH ))
    DURATION_HUMAN=$(seconds_to_human "$DURATION")
else
    DURATION_HUMAN="unknown"
fi

# --- Cleanup state files ---
rm -f "${STATE_DIR}/${USERNAME}.enabled"
rm -f "${STATE_DIR}/${USERNAME}.hard_limit"

AT_JOB_FILE="${STATE_DIR}/${USERNAME}.at_job"
if [ -f "$AT_JOB_FILE" ]; then
    OLD_JOB=$(cat "$AT_JOB_FILE")
    atrm "$OLD_JOB" 2>/dev/null || true
    rm -f "$AT_JOB_FILE"
fi

log OK "Shell user DISABLED: $USERNAME (reason: $REASON)"
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  🔒 Shell access DISABLED                    ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  User:     $USERNAME"
echo "║  Reason:   $REASON"
echo "║  Uptime:   $DURATION_HUMAN"
echo "║  Locked:   $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚══════════════════════════════════════════════╝"

REASON_HUMAN=""
case "$REASON" in
    idle-timeout)         REASON_HUMAN="Idle timeout" ;;
    hard-limit-expired)   REASON_HUMAN="Hard limit expired" ;;
    manual)               REASON_HUMAN="Manual" ;;
    *)                    REASON_HUMAN="$REASON" ;;
esac

notify "Shell DISABLED: $USERNAME ($REASON_HUMAN)" \
    "Shell user '$USERNAME' disabled.\nReason: ${REASON_HUMAN}\nUptime: ${DURATION_HUMAN}\nTime: $(date '+%Y-%m-%d %H:%M:%S')" \
    "disable"
