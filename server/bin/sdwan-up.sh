#!/usr/bin/env bash
# (c) 2025 Creekside Networks LLC, Jackson Tong
# This script will update sdwan wireguard peer settings

LOG_FILE=/var/log/sdwan.log
BASE_PATH=$(dirname $(dirname "$(readlink -f "$0")"))
SDWAN_PEERS_CONF="$BASE_PATH/conf/sdw-peers.conf"

# Function to log messages
log_message() {
    local message=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    printf "%-10s %s\n" "$timestamp" "$message" | sudo tee -a "$LOG_FILE" # > /dev/null

    # Ensure the log file does not exceed 1000 lines
    line_count=$(sudo wc -l < "$LOG_FILE")
    if [ "$line_count" -gt 1000 ]; then
        sudo tail -n 500 "$LOG_FILE" | sudo tee "$LOG_FILE.tmp" > /dev/null
        sudo mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

MY_ID=$(ip -4 --oneline addr show lo | grep 10.255.* | awk '{print $4}' | awk -F . '{print $3}')

if [[ "251 252 253" != *"$MY_ID"* ]]; then
    log_message "Invalid sdwan server id: [$MY_ID]"
    exit 1
fi

log_message "Bringup wireguard peers of wg[$MY_ID]"

while  read -r line || [[ -n $line ]]; do
    # remove comments
    stripped="${line%%\#*}"
    stripped="${stripped##*([[:space:]])}"      # remove leading spaces
    if [[ $stripped == "" ]]; then continue; fi # advanced to next line if empty

    PEER_ID=$(echo $stripped | cut -d " " -f 1)
    PEER_PUBKEY=$(echo $stripped | cut -d " " -f 2)

    log_message "Adding peer $PEER_ID - $PEER_PUBKEY"
    sudo wg set wg${MY_ID} peer ${PEER_PUBKEY} allowed-ips "10.${MY_ID}.255.${PEER_ID}/32"

done < <(cat $SDWAN_PEERS_CONF)
        
