#!/bin/bash

# --- KONFIGURATION ---
export HCLOUD_TOKEN=""       # Insert your Hetzner Cloud API Token here

SERVER_NAME=""               # Desired name for your server instance
SERVER_TYPE=""               # Server type (e.g., cax11, cax21, cp11)
LOCATION=""                  # Datacenter location (e.g., fsn1, nbg1, hel1)
PRIMARY_IP_NAME=""           # The NAME of your existing Primary IP in Hetzner Cloud
SSH_KEY_NAME=""              # The NAME of your SSH Key as registered in Hetzner Cloud
PRICE_PER_GB=0.0143          # Price per GB for snapshot storage (used for cost calculation)

# Pfade
TIMER_PID_FILE="/tmp/hcloud_timer.pid"
TIMER_INFO_FILE="/tmp/hcloud_timer_info"

# Farben
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --- HILFSFUNKTIONEN ---

parse_duration() {
    local unit=$(echo $1 | grep -o -E '[a-z]+')
    local value=$(echo $1 | grep -o -E '[0-9]+')
    case $unit in
        m|min) echo $((value * 60)) ;;
        h|std) echo $((value * 3600)) ;;
        d|tag) echo $((value * 86400)) ;;
        *) echo $value ;;
    esac
}

stop_timer() {
    if [ -f "$TIMER_PID_FILE" ]; then
        local pid=$(cat "$TIMER_PID_FILE")
        # Beende den bash Hintergrundprozess und eventuelle sleep-Kinder
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

# --- KERNBEFEHLE ---

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
    [ -z "$snapshot_id" ] && { echo -e "${RED}❌ Fehler: Kein Snapshot gefunden!${NC}"; exit 1; }

    echo -e "${GREEN}🚀 Starte $SERVER_NAME...${NC}"
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
        echo -e "${YELLOW}⏩ Lösche ohne Backup...${NC}"
    else
        echo -e "${BLUE}💾 Erstelle Snapshot: $backup_name...${NC}"
        hcloud server create-image "$SERVER_NAME" --description "$backup_name" --label "type=wings-backup" --type snapshot
    fi

    hcloud server delete "$SERVER_NAME"
    send_notification "Server abgeschaltet. (Backup: $backup_name)"
}

run_schedule() {
    local duration=$1
    local seconds=$(parse_duration "$duration")

    # Alten Namen beibehalten falls vorhanden
    local old_name=""
    [ -f "$TIMER_INFO_FILE" ] && old_name=$(grep "Snapshot:" "$TIMER_INFO_FILE" | cut -d' ' -f2)
    local backup_name=${2:-${old_name:-"auto-backup-$(date +%F-%H%M)"}}

    # Alte Timer sauber beenden
    stop_timer

    # Fehler behoben: Sauberer bash -c Aufruf im Hintergrund
    nohup bash -c "sleep $seconds && $(realpath "$0") down \"$backup_name\"" > /dev/null 2>&1 &

    echo $! > "$TIMER_PID_FILE"
    echo -e "Endzeit: $(date -d @$(( $(date +%s) + seconds )) '+%H:%M:%S')\nSnapshot: $backup_name" > "$TIMER_INFO_FILE"

    local msg="${YELLOW}⏰ Shutdown in $duration aktiviert.${NC}"
    [[ "$backup_name" == "none" ]] && msg="$msg (KEIN BACKUP)"
    echo -e "$msg"
}

run_status() {
    echo -e "\n${BLUE}--- Server Status ---${NC}"
    hcloud server list | grep "$SERVER_NAME" || echo "Kein Server aktiv."

    echo -e "\n${BLUE}--- Auto-Shutdown Info ---${NC}"
    # Überprüfen, ob die Prozess-ID aus der Datei wirklich noch läuft (kill -0 prüft nur die Existenz)
    if [ -f "$TIMER_PID_FILE" ] && kill -0 $(cat "$TIMER_PID_FILE") 2>/dev/null; then
        echo -en "${GREEN}● AKTIV${NC} "
        grep -q "Snapshot: none" "$TIMER_INFO_FILE" && echo -en "${RED}(Ohne Backup)${NC}"
        echo ""
        cat "$TIMER_INFO_FILE"
    else
        echo -e "${RED}○ INAKTIV${NC}"
        rm -f "$TIMER_PID_FILE" "$TIMER_INFO_FILE"
    fi

    echo -e "\n${BLUE}--- Snapshots ---${NC}"
    hcloud image list --type snapshot --selector "type=wings-backup" --sort created:desc

    echo -en "\n${YELLOW}Kosten:${NC} "
    hcloud image list --type snapshot --selector "type=wings-backup" -o noheader -o columns=image_size | sed 's/ GB//g' | awk -v p="$PRICE_PER_GB" '{s+=$1} END {printf "%.2f GB | ~ %.2f €/Monat\n", s, s*p}'
}

# --- MAIN ---
case $1 in
    up)             shift; run_up "$@" ;;
    down)           shift; run_down "$1" ;;
    status)         run_status ;;
    cancel)         stop_timer && echo -e "${GREEN}Timer gestoppt.${NC}" ;;
    schedule)       run_schedule "$2" "$3" ;;
    rm)             hcloud image delete "$2" ;;
    kill)           stop_timer; hcloud server delete "$SERVER_NAME" ;;
    *)
        echo "Befehle: up, down, status, schedule, cancel, rm, kill"
        ;;
esac
