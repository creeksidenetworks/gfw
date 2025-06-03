#!/bin/bash
# (c) 2022-2024 Creekside Networks LLC, Jackson Tong
# This script will update peer's dynamic IP address
# for VyOS 1.3.4 only

# Path to the config.boot file
CONFIG_BOOT_PATH="/config/config.boot"

# Define a constant for the default listen port
DEFAULT_LISTEN_PORT=28900

# Log file path
LOG_FILE="/var/log/creekside.log"

# Function to log messages
log_message() {
    local message=$1
    local priority=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z $priority ]; then
        priority=7
    fi

    case $priority in
        "1" | "2")
            log_level="crtc";;
        "3" | "4" | "5")
            log_level="warn";;
        *)
            log_level="info";;
    esac

    printf "%-10s %s %s: %s\n" "$timestamp" "[wg]" "$log_level" "$message" | sudo tee -a "$LOG_FILE"
    logger -t wg -p $priority "$message"

    # Ensure the log file does not exceed 1000 lines
    line_count=$(sudo wc -l < "$LOG_FILE")
    if [ "$line_count" -gt 1000 ]; then
        sudo tail -n 500 "$LOG_FILE" | sudo tee "$LOG_FILE.tmp" > /dev/null
        sudo mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# Function to update the WireGuard peer endpoint
update_peer_endpoint() {
    local interface="$1"
    local peer_pubkey="$2"
    local old_ip="$3"
    local new_ip="$4"
    local listen_port="$5"

    # Log the update
    log_message "$interface peer update: $peer_pubkey | $old_ip -> $new_ip : $listen_port"
    #log_message "Updating peer with public key $peer_pubkey endpoint from $old_ip to $new_ip on port $listen_port for interface $interface" 5

    # Update the WireGuard peer endpoint
    sudo wg set "$interface" peer "$peer_pubkey" endpoint "$new_ip:$listen_port"
}

# State variables
inside_wireguard_config=false
interface=""
peer_name=""
peer_pubkey=""

# Extract WireGuard configuration and peer details from the config.boot file
while IFS= read -r line; do
    # Check if we are entering a WireGuard interface section
    if [[ $line =~ wireguard\ (wg[0-9]+) ]]; then
        interface="${BASH_REMATCH[1]}"
        inside_wireguard_config=true
    fi

    # If we are inside a WireGuard configuration block
    if $inside_wireguard_config; then
        if [[ $line =~ peer\ ([a-zA-Z0-9.-]+) ]]; then
            peer_name="${BASH_REMATCH[1]}"
        fi
        if [[ $line =~ pubkey\ ([a-zA-Z0-9+/=]+) ]]; then
            peer_pubkey="${BASH_REMATCH[1]}"
        fi

        # Check for the end of a WireGuard peer block
        if [[ $line == *"}"* ]]; then
            # If a peer name was found, perform the update
            if [[ -n $peer_name && $peer_name =~ [a-zA-Z] ]]; then
                # Perform DNS lookup for FQDN
                new_ip=$(dig +short "$peer_name" | tail -n 1)

                # Get the current endpoint and listen port from the wg command
                current_endpoint=$(sudo wg show "$interface" endpoints | grep "$peer_pubkey")
                current_ip=$(echo "$current_endpoint" | awk '{print $2}' | awk -F':' '{print $1}')
                listen_port=$(echo "$current_endpoint" | awk '{print $2}' | awk -F':' '{print $2}')

                # echo "$interface: $peer_pubkey | $current_ip | $new_ip | $listen_port"

                # Use default port if the listen port is empty
                if [[ -z $listen_port ]]; then
                    listen_port=$DEFAULT_LISTEN_PORT
                fi

                # Update if the new IP differs from the current one
                if [[ -n $new_ip && $new_ip != $current_ip ]]; then
                    update_peer_endpoint "$interface" "$peer_pubkey" "$current_ip" "$new_ip" "$listen_port"
                fi
            fi

            # Reset peer-specific variables
            peer_name=""
            peer_pubkey=""
        fi
    fi

    # Check for the end of a WireGuard interface block
    if [[ $line == "}" && $inside_wireguard_config == true ]]; then
        inside_wireguard_config=false
    fi
done < "$CONFIG_BOOT_PATH"