#!/bin/sh
# (c) 2022-2025 Creekside Networks LLC, Jackson Tong
# This script will decide the best tunnel for jailbreak based on ping result
# for EdgeOS & VyOS 1.3.4

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Routing table to update
GFW_ROUTING_TABLE="100"
# Log file path
LOG_FILE="/var/log/gfw.log"
# interface switch decision threshold
SW_THRESHOLD="10"
LOSS_THRESHOLD="20"

if [ ! -f "$LOG_FILE" ]; then
    sudo touch "$LOG_FILE"
fi


# Function to parse command line arguments
parse_args() {
    PING_COUNT=60
    PING_TARGET_IP="8.8.8.8"
    GFW_ROUTING_TABLE="100"
    PRIMARY_IF="wg252"
    SECONDARY_IF="wg253"
    BACKUP_IF=""

    SUBJECT="$NAS_NAME"
    while getopts ":p:s:t:c:b:" opt; do
        case $opt in
            c)
                PING_COUNT="$OPTARG"
                ;;
            t)
                # target IP to ping test, default 8.8.8.8
                PING_TARGET_IP="$OPTARG"
                ;;
            p)
                PRIMARY_IF="$OPTARG"
                ;;
            s)
                SECONDARY_IF="$OPTARG"
                ;;
            b)  
                BACKUP_IF="$OPTARG"
                ;;
            \?)
                echo "Usage: $0 [-p <primary i/f>] [-s <secondary if>] [-b <backup if>] [-p <target ping test IP>] [-c <ping counts>]"
                exit 1
                ;;
        esac
    done
    shift $((OPTIND -1))
}

# Function to get the current default route interface for the specified table
get_current_route_interface() {
    sudo ip -4 -oneline route show table "$GFW_ROUTING_TABLE" | grep -o "dev.*" | awk '{print $2}'
}

# Function to ping from a specific interface
ping_from_interface() {
    local interface=$1
    local result_file=$2
    sudo ping -q -I "$interface" -c "$PING_COUNT" "$PING_TARGET_IP" > "$result_file" 2>&1
    echo $? > "${result_file}.status"
}

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

# Function to delete all routes in the specified table
delete_routes() {
    sudo ip route flush table "$GFW_ROUTING_TABLE"
    echo "Flushed all routes in table $GFW_ROUTING_TABLE"
}

# Process the results
get_loss_rate() {
    local result_file=$1
    local loss=$(grep 'packet loss' "$result_file" | cut -d '%' -f 1 | awk '{print $NF}')
    if [ -z "$loss" ]; then
        echo "100"
    else
        echo "$loss"
    fi
}

clean_and_exit(){
    # Clean up temp files

    rm -rf $TMP_DIR
    [ $1 -eq 0 ] || printf 'Exit with Error code '$1'.\n'
    exit $1
}

main() {
    parse_args "$@"

    TMP_DIR=$(mktemp -d)
    PRIMARY_RESULT_FILE="$TMP_DIR/primary_ping_result.txt"
    SECONDARY_RESULT_FILE="$TMP_DIR/secondary_ping_result.txt"
    BACKUP_RESULT_FILE="$TMP_DIR/backup_ping_result.txt"

    # Print message indicating start of pings
    if [ -n "$BACKUP_IF" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Ping test: ${PRIMARY_IF}, ${SECONDARY_IF}, ${BACKUP_IF}."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') Ping test: ${PRIMARY_IF}, ${SECONDARY_IF}."
    fi  

    # Ping from each interface in the background and store the result files
    ping_from_interface "$PRIMARY_IF" "$PRIMARY_RESULT_FILE" &
    ping_from_interface "$SECONDARY_IF" "$SECONDARY_RESULT_FILE" &
    ping_from_interface "$BACKUP_IF" "$BACKUP_RESULT_FILE" &

    # Wait for all background jobs to complete
    wait

    PRIMARY_LOSS=$(get_loss_rate "$PRIMARY_RESULT_FILE")
    SECONDARY_LOSS=$(get_loss_rate "$SECONDARY_RESULT_FILE")
    BACKUP_LOSS=$(get_loss_rate "$BACKUP_RESULT_FILE")

    if [ -n "$BACKUP_IF" ]; then
        echo "Ping results: $PRIMARY_IF: $PRIMARY_LOSS%, $SECONDARY_IF: $SECONDARY_LOSS%, $BACKUP_IF: $BACKUP_LOSS%"
    else
        echo "Ping results: $PRIMARY_IF: $PRIMARY_LOSS%, $SECONDARY_IF: $SECONDARY_LOSS%"
    fi

    # Get current interface
    CURRENT_IF=$(sudo ip -4 -oneline route show table "$GFW_ROUTING_TABLE" | grep -o "dev.*" | awk '{print $2}')
    DEFAULT_ROUTE=$(ip -4 -oneline route show default 0.0.0.0/0)
    DEFAULT_IF=$(echo "$DEFAULT_ROUTE" | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')

    # Make the interface switch decision by following rules
    if [ "$PRIMARY_LOSS" -gt "$LOSS_THRESHOLD" ] && [ "$SECONDARY_LOSS" -gt "$LOSS_THRESHOLD" ]; then
        # If both interfaces are down, then switch to default route
        if [ -n "$BACKUP_IF" ] && [ "$BACKUP_LOSS" -le "$LOSS_THRESHOLD" ]; then
            NEXT_IF="$BACKUP_IF"
        else
            NEXT_IF="$DEFAULT_IF"
        fi
    elif [ "$CURRENT_IF" = "$DEFAULT_IF" ] || [ -z "$CURRENT_IF" ] || [ "$CURRENT_IF" = "$BACKUP_IF" ]; then
        # Switch from loss or backup interface to best interface
        if [ "$PRIMARY_LOSS" -le "$SECONDARY_LOSS" ]; then
            NEXT_IF="$PRIMARY_IF"
        else
            NEXT_IF="$SECONDARY_IF"
        fi  
    elif [ "$PRIMARY_LOSS" -lt "$SW_THRESHOLD" ] && [ "$SECONDARY_LOSS" -lt "$SW_THRESHOLD" ]; then
        # If both interfaces are good, and current is not default, then stay
        NEXT_IF="$CURRENT_IF"
    else
        # At least one interface is worst thatn stay zone, switch to best interface
        if [ "$PRIMARY_LOSS" -le "$SECONDARY_LOSS" ]; then
            NEXT_IF="$PRIMARY_IF"
        else
            NEXT_IF="$SECONDARY_IF"
        fi  
    fi

    if [ "$NEXT_IF" = "$CURRENT_IF" ]; then
        echo "Stay with $CURRENT_IF"
    elif [ "$NEXT_IF" = "$PRIMARY_IF" ]; then
        delete_routes
        sudo ip route replace default dev "$PRIMARY_IF" table "$GFW_ROUTING_TABLE"
        sudo ip route replace "$PING_TARGET_IP" dev "$PRIMARY_IF"
    elif [ "$NEXT_IF" = "$SECONDARY_IF" ]; then
        delete_routes
        sudo ip route replace default dev "$SECONDARY_IF" table "$GFW_ROUTING_TABLE"
        sudo ip route replace "$PING_TARGET_IP" dev "$SECONDARY_IF"
    elif [ "$NEXT_IF" = "$BACKUP_IF" ]; then
        delete_routes
        sudo ip route replace default dev "$BACKUP_IF" table "$GFW_ROUTING_TABLE"
        sudo ip route replace "$PING_TARGET_IP" dev "$BACKUP_IF"
    else
        delete_routes
        default_route=$(ip -4 -oneline route show default 0.0.0.0/0)
        default_route_interface=$(echo "$default_route" | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
        new_route=$(echo "$default_route" | grep -o "via.*" | awk '{print $1 " " $2}')
        new_route="$new_route $(echo "$default_route" | grep -o "dev.*" | awk '{print $1 " " $2}')"
        sudo ip route replace default $new_route table "$GFW_ROUTING_TABLE"
        sudo ip route replace "$PING_TARGET_IP" $new_route
    fi

    if [[ "$NEXT_IF" != "$CURRENT_IF" ]]; then
        if [ -n "$BACKUP_IF" ]; then
            log_message "Ping results: $PRIMARY_IF: $PRIMARY_LOSS%, $SECONDARY_IF: $SECONDARY_LOSS%, $BACKUP_IF: $BACKUP_LOSS%"
        else
            log_message "Ping results: $PRIMARY_IF: $PRIMARY_LOSS%, $SECONDARY_IF: $SECONDARY_LOSS%"
        fi
        log_message "Interface switch decision: $CURRENT_IF -> $NEXT_IF"
    fi

    clean_and_exit 0
}

main "$@"