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
    #    pgrep -U uses UID -> reliable even when name resolution is weird in jails
    local uid
    uid=$(id -u "$username" 2>/dev/null)
    local active_procs=0
    if [ -n "$uid" ]; then
        active_procs=$(pgrep -U "$uid" 2>/dev/null | wc -l)
    fi
    if [ "$active_procs" -eq 0 ]; then
        active_procs=$(pgrep -u "$username" 2>/dev/null | wc -l)
    fi
    if [ "$active_procs" -gt 0 ]; then
        log INFO "  $username: $active_procs process(es) running - ACTIVE"
        echo "ACTIVE"
        return
    fi

    # 2. Check auth.log for last session close
    #    Ubuntu 24.04 / Debian 12 rsyslog defaults to ISO 8601 timestamps:
    #      2026-05-16T16:30:01.123456+02:00 host sshd[…]: ...
    #    Classic syslog format:
    #      May 16 16:30:01 host sshd[…]: ...
    #    Detect and parse accordingly.
    local auth_log="/var/log/auth.log"
    [ ! -f "$auth_log" ] && auth_log="/var/log/secure"
    if [ -f "$auth_log" ] && [ -r "$auth_log" ]; then
        local last_close_line
        last_close_line=$(grep -E "(session closed|Disconnected from).*${username}" "$auth_log" 2>/dev/null | tail -1)
        if [ -n "$last_close_line" ]; then
            local ts_field
            if [[ "$last_close_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
                # ISO 8601: take just the first whitespace-separated field
                ts_field=$(awk '{print $1}' <<<"$last_close_line")
            else
                # Classic syslog: month day time
                ts_field=$(awk '{print $1" "$2" "$3}' <<<"$last_close_line")
            fi
            local close_epoch
            close_epoch=$(date -d "$ts_field" +%s 2>/dev/null)
            if [ -n "$close_epoch" ] && [ "$close_epoch" -gt 0 ]; then
                [ "$close_epoch" -gt "$last_epoch" ] && last_epoch=$close_epoch
            else
                log WARN "  $username: failed to parse auth.log timestamp: '$ts_field'"
            fi
        fi
    fi

    # 3. journalctl fallback (covers journald-only systems where auth.log may be sparse)
    if command -v journalctl &>/dev/null; then
        local j_line
        j_line=$(journalctl _COMM=sshd --since "1 week ago" -o short-iso --no-pager 2>/dev/null \
                 | grep -E "(session closed|Disconnected from).*${username}" \
                 | tail -1)
        if [ -n "$j_line" ]; then
            local j_ts
            j_ts=$(awk '{print $1}' <<<"$j_line")
            local j_epoch
            j_epoch=$(date -d "$j_ts" +%s 2>/dev/null)
            if [ -n "$j_epoch" ] && [ "$j_epoch" -gt 0 ] && [ "$j_epoch" -gt "$last_epoch" ]; then
                last_epoch=$j_epoch
            fi
        fi
    fi

    # 4. lastlog fallback (returns last LOGIN time, not last activity)
    local lastlog_time
    lastlog_time=$(lastlog -u "$username" 2>/dev/null | tail -1)
    if ! echo "$lastlog_time" | grep -q "Never logged in"; then
        local parsed
        parsed=$(echo "$lastlog_time" | awk '{print $4" "$5" "$6" "$7" "$9}')
        local parsed_epoch
        parsed_epoch=$(date -d "$parsed" +%s 2>/dev/null)
        if [ -n "$parsed_epoch" ] && [ "$parsed_epoch" -gt 0 ] && [ "$parsed_epoch" -gt "$last_epoch" ]; then
            last_epoch=$parsed_epoch
        fi
    fi

    # 5. last_seen_active state file — written by the monitor whenever it
    #    observed ACTIVE processes for this user. This is the authoritative
    #    "sliding window" source: as long as the user keeps working, this
    #    timestamp advances every monitor tick.
    local seen_file="${STATE_DIR}/${username}.last_seen_active"
    if [ -f "$seen_file" ]; then
        local seen_epoch
        seen_epoch=$(cat "$seen_file" 2>/dev/null)
        if [ -n "$seen_epoch" ] && [ "$seen_epoch" -gt "$last_epoch" ] 2>/dev/null; then
            last_epoch=$seen_epoch
        fi
    fi

    # 6. FLOOR: enable timestamp is always the minimum
    #    Prevents old auth.log entries from causing instant disable after re-enable.
    local enabled_file="${STATE_DIR}/${username}.enabled"
    if [ -f "$enabled_file" ]; then
        local enabled_epoch
        enabled_epoch=$(cat "$enabled_file" 2>/dev/null)
        if [ -n "$enabled_epoch" ] && [ "$last_epoch" -lt "$enabled_epoch" ] 2>/dev/null; then
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
