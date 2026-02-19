#!/bin/bash
# ============================================================
# Shell Access Manager for ISPConfig - Shared Functions
# ISPConfig 3.3.x JSON API format
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/shell-access-manager.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Config file not found: $CONF_FILE" >&2
    exit 1
fi
source "$CONF_FILE"

mkdir -p "$STATE_DIR"

# --- Logging ---
log() {
    local level="$1"; shift; local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    [ "$SYSLOG_ENABLED" = true ] && logger -t "$SYSLOG_TAG" "[$level] $message"
    case "$level" in
        ERROR) echo -e "\e[31m[$level]\e[0m $message" >&2 ;;
        WARN)  echo -e "\e[33m[$level]\e[0m $message" >&2 ;;
        OK)    echo -e "\e[32m[$level]\e[0m $message" ;;
        *)     echo "[$level] $message" ;;
    esac
}

# --- Email Notifications ---
notify() {
    local subject="$1" body="$2" type="${3:-info}"
    case "$type" in
        enable)  [ "$NOTIFY_ON_ENABLE" != true ] && return ;;
        disable) [ "$NOTIFY_ON_DISABLE" != true ] && return ;;
        error)   [ "$NOTIFY_ON_ERROR" != true ] && return ;;
    esac
    [ -n "$NOTIFY_EMAIL" ] && command -v mail &>/dev/null && \
        echo "$body" | mail -s "[Shell-Access-Mgr] $subject" "$NOTIFY_EMAIL"
}

# ============================================================
# ISPConfig 3.3.x Remote JSON API
# Format: ?method_name in URL, parameters as JSON body
# ============================================================

api_login() {
    local response
    response=$(curl -sk --max-time 10 -X POST "${API_URL}?login" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg user "$API_USER" --arg pass "$API_PASS" \
            '{username: $user, password: $pass}')" 2>/dev/null)
    [ $? -ne 0 ] || [ -z "$response" ] && { log ERROR "API login failed: no response"; return 1; }
    local session_id=$(echo "$response" | jq -r '.response // empty' 2>/dev/null)
    if [ -z "$session_id" ] || [ "$session_id" = "null" ] || [ "$session_id" = "false" ]; then
        log ERROR "API login failed: $(echo "$response" | jq -r '.message // "unknown"')"
        return 1
    fi
    echo "$session_id"
}

api_logout() {
    local session_id="$1"; [ -z "$session_id" ] && return
    curl -sk --max-time 10 -X POST "${API_URL}?logout" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg sid "$session_id" '{session_id: $sid}')" &>/dev/null
}

get_shell_user_id() {
    mysql -Nse "SELECT shell_user_id FROM ${ISPCONFIG_DB}.shell_user WHERE username='${1}' ORDER BY shell_user_id DESC LIMIT 1" 2>/dev/null
}

api_get_shell_user() {
    curl -sk --max-time 10 -X POST "${API_URL}?sites_shell_user_get" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg sid "$1" --argjson pid "$2" '{session_id: $sid, primary_id: $pid}')" 2>/dev/null
}

api_update_shell_user() {
    local session_id="$1" client_id="$2" shell_user_id="$3" update_json="$4"
    curl -sk --max-time 10 -X POST "${API_URL}?sites_shell_user_update" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg sid "$session_id" --argjson cid "$client_id" --argjson pid "$shell_user_id" --argjson params "$update_json" \
            '{session_id: $sid, client_id: $cid, primary_id: $pid, params: $params}')" 2>/dev/null
}

get_active_shell_users() {
    mysql -Nse "
        SELECT su.shell_user_id, su.username, su.sys_userid, COALESCE(c.client_id, 0)
        FROM ${ISPCONFIG_DB}.shell_user su
        LEFT JOIN ${ISPCONFIG_DB}.sys_user sys ON su.sys_userid = sys.userid
        LEFT JOIN ${ISPCONFIG_DB}.client c ON sys.client_id = c.client_id
        WHERE su.active = 'y'" 2>/dev/null
}

# ============================================================
# SSH Activity Detection
# ============================================================

get_last_ssh_activity() {
    local username="$1" last_epoch=0

    # 1. Active session? -> currently active
    local active_sessions=$(who | grep "^${username} " | wc -l)
    [ "$active_sessions" -gt 0 ] && { echo "ACTIVE"; return; }

    # 2. Check auth.log for last session close
    local auth_log="/var/log/auth.log"
    [ ! -f "$auth_log" ] && auth_log="/var/log/secure"
    if [ -f "$auth_log" ]; then
        local last_close=$(grep -E "(session closed|Disconnected from).*${username}" "$auth_log" 2>/dev/null | tail -1 | awk '{print $1" "$2" "$3}')
        if [ -n "$last_close" ]; then
            local close_epoch=$(date -d "$last_close" +%s 2>/dev/null)
            [ -n "$close_epoch" ] && [ "$close_epoch" -gt "$last_epoch" ] && last_epoch=$close_epoch
        fi
    fi

    # 3. lastlog fallback
    if [ "$last_epoch" -eq 0 ]; then
        local lastlog_time=$(lastlog -u "$username" 2>/dev/null | tail -1)
        if ! echo "$lastlog_time" | grep -q "Never logged in"; then
            local parsed=$(echo "$lastlog_time" | awk '{print $4" "$5" "$6" "$7" "$9}')
            local parsed_epoch=$(date -d "$parsed" +%s 2>/dev/null)
            [ -n "$parsed_epoch" ] && last_epoch=$parsed_epoch
        fi
    fi

    # 4. State file (enable timestamp as last resort)
    if [ "$last_epoch" -eq 0 ]; then
        local state_file="${STATE_DIR}/${username}.enabled"
        [ -f "$state_file" ] && last_epoch=$(cat "$state_file")
    fi

    echo "$last_epoch"
}

# ============================================================
# Utility Functions
# ============================================================

seconds_to_human() {
    local total_seconds=$1
    echo "$((total_seconds / 3600))h $(( (total_seconds % 3600) / 60))m"
}

check_dependencies() {
    local missing=()
    for cmd in curl jq mysql; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -gt 0 ] && { log ERROR "Missing dependencies: ${missing[*]}"; return 1; }
    return 0
}
