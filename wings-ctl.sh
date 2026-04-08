#!/bin/bash

# --- KONFIGURATION ---
export HCLOUD_TOKEN=""       # Insert your Hetzner Cloud API Token here

SERVER_NAME=""               # Desired name for your server instance
SERVER_TYPE=""               # Server type (e.g., cax11, cax21, cp11)
LOCATION=""                  # Datacenter location (e.g., fsn1, nbg1, hel1)
PRIMARY_IP_NAME=""           # The NAME of your existing Primary IP in Hetzner Cloud
SSH_KEY_NAME=""              # The NAME of your SSH Key as registered in Hetzner Cloud
PRICE_PER_GB=0.0143          # Price per GB for snapshot storage (used for cost calculation)

# Paths
TIMER_PID_FILE="/tmp/hcloud_timer.pid"
TIMER_INFO_FILE="/tmp/hcloud_timer_info"

# Colors
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# --- DEPENDENCY CHECK ---
MISSING=()
command -v hcloud    >/dev/null 2>&1 || MISSING+=("hcloud (https://github.com/hetznercloud/cli)")
command -v awk       >/dev/null 2>&1 || MISSING+=("awk (meist vorinstalliert, Paket: gawk)")
command -v pkill     >/dev/null 2>&1 || MISSING+=("pkill (Paket: procps)")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "${RED}❌ Fehlende Abhängigkeiten:${NC}"
    for dep in "${MISSING[@]}"; do
        echo -e "  ${YELLOW}→ $dep${NC}"
    done
    exit 1
fi

# --- HELPER FUNCTIONS ---

show_help() {
    echo -e "${BLUE}=== HETZNER CLOUD MANAGER HELP ===${NC}"
    echo -e "Usage: $0 ${YELLOW}[COMMAND] [ARGUMENTS]${NC}"
    echo ""
    echo -e "${BLUE}COMMANDS:${NC}"
    printf "  ${YELLOW}%-20s${NC} %s\n" "up [ID]" "Deploys a server. Uses latest snapshot if ID is missing."
    printf "  ${YELLOW}%-20s${NC} %s\n" "down [name|none]" "Creates snapshot and deletes server. Use 'none' to skip backup."
    printf "  ${YELLOW}%-20s${NC} %s\n" "status" "Shows server state, active timers, snapshots, and estimated costs."
    printf "  ${YELLOW}%-20s${NC} %s\n" "schedule [time]" "Reschedules the shutdown timer (e.g., 2h, 30m)."
    printf "  ${YELLOW}%-20s${NC} %s\n" "cancel" "Stops and removes the current auto-shutdown timer."
    printf "  ${YELLOW}%-20s${NC} %s\n" "rm [ID]" "Deletes a specific snapshot by its ID."
    printf "  ${YELLOW}%-20s${NC} %s\n" "kill" "Immediately deletes the server without any backup."
    echo ""
    echo -e "${BLUE}OPTIONS FOR 'up':${NC}"
    printf "  ${YELLOW}%-20s${NC} %s\n" "--time [val]" "Set custom shutdown duration (default: 4h). Units: m, h, d."
    printf "  ${YELLOW}%-20s${NC} %s\n" "--name [val]" "Set a custom name for the automatic backup snapshot."
    printf "  ${YELLOW}%-20s${NC} %s\n" "--no-timer" "Starts the server without an automatic shutdown timer."
    printf "  ${YELLOW}%-20s${NC} %s\n" "--no-backup" "Server will delete itself after time expires without a backup."
    echo ""
    echo -e "${BLUE}EXAMPLES:${NC}"
    echo "  $0 up --time 2h --no-backup      -> Start for 2 hours, no backup at end."
    echo "  $0 schedule 30m none             -> Change remaining time to 30m, skip backup."
    echo "  $0 down my-final-backup          -> Shut down now and name the snapshot 'my-final-backup'."
    echo ""
}

parse_duration() {
    local unit=$(echo $1 | grep -o -E '[a-z]+')
    local value=$(echo $1 | grep -o -E '[0-9]+')
    case $unit in
        m|min) echo $((value * 60)) ;;
        h|std|h) echo $((value * 3600)) ;;
        d|tag|d) echo $((value * 86400)) ;;
        *) echo $value ;; 
    esac
}

stop_timer() {
    if [ -f "$TIMER_PID_FILE" ]; then
        local pid=$(cat "$TIMER_PID_FILE")
        pkill -P "$pid" 2>/dev/null
        kill -9 "$pid" 2>/dev/null
        rm -f "$TIMER_PID_FILE" "$TIMER_INFO_FILE"
    fi
}

send_notification() {
    local msg=$1
    command -v notify-send >/dev/null && notify-send "Hetzner Cloud" "$msg"
    echo -e "${RED}🔔 $msg${NC}" | wall 2>/dev/null
}

# --- CORE COMMANDS ---

run_up() {
    local snapshot_id=""
    local duration="4h"
    local backup_name="auto-backup-$(date +%F-%H%M)"
    local use_timer=true

    while [[ $# -gt 0 ]]; do
        case $1 in
            --time)      duration="$2"; shift 2 ;;
            --name)      backup_name="$2"; shift 2 ;;
            --no-timer)  use_timer=false; shift ;;
            --no-backup) backup_name="none"; shift ;;
            *)           snapshot_id="$1"; shift ;;
        esac
    done

    [ -z "$snapshot_id" ] && snapshot_id=$(hcloud image list --type snapshot --selector "type=wings-backup" --sort created:desc -o noheader -o columns=id | head -n 1)
    [ -z "$snapshot_id" ] && { echo -e "${RED}❌ Error: No snapshot found!${NC}"; exit 1; }

    echo -e "${GREEN}🚀 Starting $SERVER_NAME...${NC}"
    hcloud server create --name "$SERVER_NAME" --image "$snapshot_id" --type "$SERVER_TYPE" --location "$LOCATION" --primary-ipv4 "$PRIMARY_IP_NAME" --ssh-key "$SSH_KEY_NAME" --label "type=wings-node"

    if [ "$use_timer" = true ]; then
        run_schedule "$duration" "$backup_name"
    fi
}

run_down() {
    local scheduled_name=""
    [ -f "$TIMER_INFO_FILE" ] && scheduled_name=$(grep "Snapshot:" "$TIMER_INFO_FILE" | cut -d' ' -f2)
    local backup_name=${1:-${scheduled_name:-"manual-backup-$(date +%F-%H%M)"}}
    
    stop_timer

    if [[ "$backup_name" == "none" ]]; then
        echo -e "${YELLOW}⏩ Terminating without backup...${NC}"
    else
        echo -e "${BLUE}💾 Creating snapshot: $backup_name...${NC}"
        hcloud server create-image "$SERVER_NAME" --description "$backup_name" --label "type=wings-backup" --type snapshot
    fi
    
    hcloud server delete "$SERVER_NAME"
    send_notification "Server $SERVER_NAME terminated. (Backup: $backup_name)"
}

run_schedule() {
    local duration=$1
    local seconds=$(parse_duration "$duration")
    
    local old_name=""
    [ -f "$TIMER_INFO_FILE" ] && old_name=$(grep "Snapshot:" "$TIMER_INFO_FILE" | cut -d' ' -f2)
    local backup_name=${2:-${old_name:-"auto-backup-$(date +%F-%H%M)"}}

    stop_timer
    
    nohup bash -c "sleep $seconds && $(realpath "$0") down \"$backup_name\"" > /dev/null 2>&1 &
    
    echo $! > "$TIMER_PID_FILE"
    echo -e "End Time: $(date -d @$(( $(date +%s) + seconds )) '+%H:%M:%S')\nSnapshot: $backup_name" > "$TIMER_INFO_FILE"
    
    local msg="${YELLOW}⏰ Shutdown in $duration activated.${NC}"
    [[ "$backup_name" == "none" ]] && msg="$msg (NO BACKUP)"
    echo -e "$msg"
}

run_status() {
    echo -e "\n${BLUE}--- Server Status ---${NC}"
    hcloud server list | grep "$SERVER_NAME" || echo "No active server found."
    
    echo -e "\n${BLUE}--- Auto-Shutdown Info ---${NC}"
    if [ -f "$TIMER_PID_FILE" ] && kill -0 $(cat "$TIMER_PID_FILE") 2>/dev/null; then
        echo -en "${GREEN}● ACTIVE${NC} "
        grep -q "Snapshot: none" "$TIMER_INFO_FILE" && echo -en "${RED}(No Backup)${NC}"
        echo ""
        cat "$TIMER_INFO_FILE"
    else
        echo -e "${RED}○ INACTIVE${NC}"
        rm -f "$TIMER_PID_FILE" "$TIMER_INFO_FILE"
    fi

    echo -e "\n${BLUE}--- Snapshots ---${NC}"
    hcloud image list --type snapshot --selector "type=wings-backup" --sort created:desc
    
    echo -en "\n${YELLOW}Estimated Costs:${NC} "
    hcloud image list --type snapshot --selector "type=wings-backup" -o noheader -o columns=image_size | sed 's/ GB//g' | awk -v p="$PRICE_PER_GB" '{s+=$1} END {printf "%.2f GB | ~ %.2f €/month\n", s, s*p}'
}

# --- MAIN ---
case $1 in
    up)             shift; run_up "$@" ;;
    down)           shift; run_down "$1" ;;
    status)         run_status ;;
    cancel)         stop_timer && echo -e "${GREEN}Timer stopped.${NC}" ;;
    schedule)       run_schedule "$2" "$3" ;;
    rm)             hcloud image delete "$2" && echo -e "${GREEN}Snapshot deleted.${NC}" ;;
    kill)           stop_timer; hcloud server delete "$SERVER_NAME" && echo -e "${RED}Server killed.${NC}" ;;
    help|--help|-h) show_help ;;
    *)
        show_help
        ;;
esac