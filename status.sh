#!/bin/bash
# ============================================================
# Shell Access Manager for ISPConfig - Status Display
# Usage: ./status.sh [username]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib-functions.sh"

USERNAME="${1:-}"
NOW_EPOCH=$(date +%s)

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              Shell Access Manager - Status                      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

if [ -n "$USERNAME" ]; then
    QUERY="WHERE su.username = '$USERNAME'"
else
    QUERY=""
fi

mysql -e "
    SELECT
        su.username AS 'User',
        su.active AS 'Active',
        su.chroot AS 'Chroot',
        su.ssh_rsa AS 'Has SSH Key',
        w.domain AS 'Website'
    FROM ${ISPCONFIG_DB}.shell_user su
    LEFT JOIN ${ISPCONFIG_DB}.web_domain w ON su.parent_domain_id = w.domain_id
    $QUERY
    ORDER BY su.active DESC, su.username ASC
" 2>/dev/null

echo ""

ACTIVE_USERS=$(mysql -Nse "
    SELECT su.username, su.shell_user_id
    FROM ${ISPCONFIG_DB}.shell_user su
    WHERE su.active = 'y'
    $([ -n "$USERNAME" ] && echo "AND su.username = '$USERNAME'")
" 2>/dev/null)

if [ -n "$ACTIVE_USERS" ]; then
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ Active shell user details:                                     │"
    echo "├─────────────────────────────────────────────────────────────────┤"

    while IFS=$'\t' read -r UNAME SU_ID; do
        LAST_ACTIVITY=$(get_last_ssh_activity "$UNAME")
        ACTIVE_SESSIONS=$(who | grep "^${UNAME} " | wc -l)

        ENABLED_FILE="${STATE_DIR}/${UNAME}.enabled"
        if [ -f "$ENABLED_FILE" ]; then
            ENABLED_EPOCH=$(cat "$ENABLED_FILE")
            ELAPSED=$((NOW_EPOCH - ENABLED_EPOCH))
            ENABLED_SINCE=$(date -d "@$ENABLED_EPOCH" '+%Y-%m-%d %H:%M')
            ELAPSED_HUMAN=$(seconds_to_human "$ELAPSED")
        else
            ENABLED_SINCE="unknown (not enabled via this tool)"
            ELAPSED_HUMAN="?"
            ELAPSED=0
        fi

        HARD_LIMIT_FILE="${STATE_DIR}/${UNAME}.hard_limit"
        if [ -f "$HARD_LIMIT_FILE" ]; then
            EFFECTIVE_HARD=$(cat "$HARD_LIMIT_FILE")
            HARD_REMAINING=$((EFFECTIVE_HARD - ELAPSED))
            [ "$HARD_REMAINING" -lt 0 ] && HARD_REMAINING=0
            HARD_INFO="$(seconds_to_human $EFFECTIVE_HARD) (remaining: $(seconds_to_human $HARD_REMAINING))"
        else
            HARD_INFO="not set"
        fi

        if [ "$LAST_ACTIVITY" = "ACTIVE" ]; then
            IDLE_INFO="⚡ Active session ($ACTIVE_SESSIONS)"
        elif [ "$LAST_ACTIVITY" -gt 0 ] 2>/dev/null; then
            IDLE_SECONDS=$((NOW_EPOCH - LAST_ACTIVITY))
            IDLE_REMAINING=$((IDLE_LIMIT - IDLE_SECONDS))
            [ "$IDLE_REMAINING" -lt 0 ] && IDLE_REMAINING=0
            IDLE_INFO="Idle: $(seconds_to_human $IDLE_SECONDS) (remaining: $(seconds_to_human $IDLE_REMAINING))"
        else
            IDLE_INFO="No activity"
        fi

        echo "│"
        echo "│  👤 $UNAME"
        echo "│     Enabled at:   $ENABLED_SINCE ($ELAPSED_HUMAN)"
        echo "│     Hard limit:   $HARD_INFO"
        echo "│     Activity:     $IDLE_INFO"
        echo "│     Sessions:     $ACTIVE_SESSIONS active"

    done <<< "$ACTIVE_USERS"

    echo "└─────────────────────────────────────────────────────────────────┘"
else
    echo "  No active shell users."
fi

echo ""
