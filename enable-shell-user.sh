#!/bin/bash
# ============================================================
# Shell Access Manager for ISPConfig - ENABLE Shell User
# Usage: ./enable-shell-user.sh <username> [max_hours]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib-functions.sh"

USERNAME="${1:-}"
MAX_HOURS="${2:-}"

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username> [max_hours]"
    echo ""
    echo "Examples:  $0 web1 3"
    echo "           $0 web1          (default: $(( HARD_LIMIT / 3600 ))h)"
    exit 1
fi

if [ -n "$MAX_HOURS" ]; then
    EFFECTIVE_HARD_LIMIT=$(( MAX_HOURS * 3600 ))
else
    EFFECTIVE_HARD_LIMIT=$HARD_LIMIT
    MAX_HOURS=$(( HARD_LIMIT / 3600 ))
fi

check_dependencies || exit 1

SHELL_USER_ID=$(get_shell_user_id "$USERNAME")
if [ -z "$SHELL_USER_ID" ]; then
    log ERROR "Shell user not found in ISPConfig: $USERNAME"
    exit 1
fi

log INFO "Enabling shell user: $USERNAME (ID: $SHELL_USER_ID)"

SESSION=$(api_login)
if [ -z "$SESSION" ]; then
    log ERROR "Cannot connect to ISPConfig API"
    exit 1
fi
trap 'api_logout "$SESSION"' EXIT

# Get current record
RECORD=$(api_get_shell_user "$SESSION" "$SHELL_USER_ID")
CURRENT_ACTIVE=$(echo "$RECORD" | jq -r '.response.active // empty' 2>/dev/null)

# Admin users have no client_id, use 0
CLIENT_ID=0

if [ "$CURRENT_ACTIVE" = "y" ]; then
    log WARN "Shell user $USERNAME is already active"
    echo "⚠️  $USERNAME is already active. Resetting timers..."
fi

# Enable via API
UPDATE_RESULT=$(api_update_shell_user "$SESSION" "$CLIENT_ID" "$SHELL_USER_ID" '{"active": "y"}')
UPDATE_OK=$(echo "$UPDATE_RESULT" | jq -r '.response // empty' 2>/dev/null)
if [ -z "$UPDATE_OK" ] || [ "$UPDATE_OK" = "false" ]; then
    ERROR_MSG=$(echo "$UPDATE_RESULT" | jq -r '.message // "unknown"' 2>/dev/null)
    log ERROR "API update failed for $USERNAME: $ERROR_MSG"
    exit 1
fi

# Save state
NOW_EPOCH=$(date +%s)
echo "$NOW_EPOCH" > "${STATE_DIR}/${USERNAME}.enabled"
echo "$EFFECTIVE_HARD_LIMIT" > "${STATE_DIR}/${USERNAME}.hard_limit"

# Schedule hard limit at-job
if [ "$EFFECTIVE_HARD_LIMIT" -gt 0 ]; then
    AT_JOB_FILE="${STATE_DIR}/${USERNAME}.at_job"
    if [ -f "$AT_JOB_FILE" ]; then
        OLD_JOB=$(cat "$AT_JOB_FILE")
        atrm "$OLD_JOB" 2>/dev/null || true
    fi
    AT_OUTPUT=$(echo "${SCRIPT_DIR}/disable-shell-user.sh $USERNAME hard-limit-expired" | at now + ${MAX_HOURS} hours 2>&1)
    AT_JOB_ID=$(echo "$AT_OUTPUT" | grep -oP 'job \K\d+')
    [ -n "$AT_JOB_ID" ] && echo "$AT_JOB_ID" > "$AT_JOB_FILE"
    log OK "Hard limit at-job scheduled: ${MAX_HOURS}h (job: ${AT_JOB_ID:-?})"
fi

IDLE_HOURS=$(( IDLE_LIMIT / 3600 ))
IDLE_MINS=$(( (IDLE_LIMIT % 3600) / 60))

log OK "Shell user ENABLED: $USERNAME"
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ Shell access ENABLED                     ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  User:       $USERNAME"
echo "║  Hard limit: ${MAX_HOURS}h (expires $(date -d "+${MAX_HOURS} hours" '+%H:%M'))"
echo "║  Idle limit: ${IDLE_HOURS}h ${IDLE_MINS}m of inactivity"
echo "║  Enabled at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚══════════════════════════════════════════════╝"

notify "Shell ENABLED: $USERNAME" \
    "Shell user '$USERNAME' enabled.\nHard limit: ${MAX_HOURS}h\nIdle limit: ${IDLE_HOURS}h ${IDLE_MINS}m\nTime: $(date '+%Y-%m-%d %H:%M:%S')" \
    "enable"
