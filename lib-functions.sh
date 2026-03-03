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
        OK)    echo -e "\e[32m[$level]\e[0m $message" >&2 ;;
        *)     echo "[$level] $message" >&2 ;;
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
# Compatible with jailkit chroot (who/utmp does NOT work there)
# Uses pgrep + PTY mtime + process elapsed time
# ============================================================

get_last_ssh_activity() {
    local username="$1" last_epoch=0

    # 1. Active processes? (works with jailkit chroot - who/utmp does NOT)
    local active_procs=$(pgrep -u "$username" 2>/dev/null | wc -l)
    if [ "$active_procs" -gt 0 ]; then
        # Check REAL activity via PTY device mtime OR process start time
        local most_recent_activity=0

        # Method A: PTY device check (for interactive sessions)
        local user_ptys=$(find /dev/pts/ -user "$username" 2>/dev/null)
        for dev_path in $user_ptys; do
            local pty_mtime=$(stat -c %Y "$dev_path" 2>/dev/null)
            if [ -n "$pty_mtime" ] && [ "$pty_mtime" -gt "$most_recent_activity" ]; then
                most_recent_activity=$pty_mtime
            fi
        done

        # Method B: Most recent process start time (for background processes / jailkit)
        if [ "$most_recent_activity" -eq 0 ]; then
            local newest_proc_start
            newest_proc_start=$(ps -u "$username" -o etimes= 2>/dev/null | sort -n | head -1)
            if [ -n "$newest_proc_start" ]; then
                local now_epoch=$(date +%s)
                most_recent_activity=$((now_epoch - newest_proc_start))
            fi
        fi

        local now_epoch=$(date +%s)

        if [ "$most_recent_activity" -gt 0 ]; then
            local idle_seconds=$((now_epoch - most_recent_activity))

            if [ "$idle_seconds" -lt "$IDLE_LIMIT" ]; then
                echo "ACTIVE"
                return
            else
                log INFO "  $username: processes running but idle for $(seconds_to_human $idle_seconds)"
                echo "$most_recent_activity"
                return
            fi
        fi

        # Has processes but can't determine activity time -> treat as active
        log INFO "  $username: $active_procs process(es) running - treating as ACTIVE"
        echo "ACTIVE"
        return
    fi

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

    # 4. State file as fallback if nothing else found
    if [ "$last_epoch" -eq 0 ]; then
        local state_file="${STATE_DIR}/${username}.enabled"
        [ -f "$state_file" ] && last_epoch=$(cat "$state_file")
    fi

    # 5. FLOOR: enable timestamp is always the minimum
    #    You can't be "idle" from before you were enabled!
    #    This prevents old auth.log entries from causing instant disable after re-enable.
    local enabled_file="${STATE_DIR}/${username}.enabled"
    if [ -f "$enabled_file" ]; then
        local enabled_epoch=$(cat "$enabled_file")
        if [ "$last_epoch" -lt "$enabled_epoch" ]; then
            log INFO "  $username: activity ($last_epoch) predates enable ($enabled_epoch) - using enable time as floor"
            last_epoch=$enabled_epoch
        fi
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
