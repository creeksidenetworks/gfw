#!/bin/sh
# (c) 2022-2025 Creekside Networks LLC, Jackson Tong
# This script will decide the best tunnel for jailbreak based on ping result
# for EdgeOS & VyOS 1.3.4

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Routing table to update
GFW_ROUTING_TABLE="100"
# Log file path
LOG_FILE="/var/log/gfw.log"
# State file to track interface recovery
STATE_FILE="/var/run/gfw_state.txt"
# interface switch decision threshold
SW_THRESHOLD="10"
LOSS_THRESHOLD="20"
# Consecutive successful pings required for interface recovery
RECOVERY_COUNT="5"

PING_COUNT=30
PING_TARGET_IP="8.8.8.8"
GFW_ROUTING_TABLE="100"
PRIMARY_IF="wg252"
SECONDARY_IF="wg253"
BACKUP_IF="wg251"


if [ ! -f "$LOG_FILE" ]; then
    sudo touch "$LOG_FILE"
fi


# Function to parse command line arguments
parse_args() {

    SUBJECT="$NAS_NAME"
    while getopts ":p:s:t:c:b:r:" opt; do
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
            r)
                RECOVERY_COUNT="$OPTARG"
                ;;
            \?)
                echo "Usage: $0 [-p <primary i/f>] [-s <secondary if>] [-b <backup if>] [-t <target ping test IP>] [-c <ping counts>] [-r <recovery count>]"
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

# Function to read interface state from state file
read_interface_state() {
    local interface=$1
    if [ -f "$STATE_FILE" ]; then
        grep "^${interface}:" "$STATE_FILE" 2>/dev/null | cut -d':' -f2
    fi
}

# Function to write interface state to state file
write_interface_state() {
    local interface=$1
    local count=$2
    
    if [ ! -f "$STATE_FILE" ]; then
        sudo touch "$STATE_FILE"
    fi
    
    # Remove old entry for this interface and add new one
    if grep -q "^${interface}:" "$STATE_FILE" 2>/dev/null; then
        sudo sed -i "/^${interface}:/d" "$STATE_FILE"
    fi
    echo "${interface}:${count}" | sudo tee -a "$STATE_FILE" > /dev/null
}

# Function to check if interface is ready (has enough consecutive successful pings)
is_interface_ready() {
    local interface=$1
    local loss=$2
    
    local success_count=$(read_interface_state "$interface")
    [ -z "$success_count" ] && success_count=0
    
    if [ "$loss" -le "$LOSS_THRESHOLD" ]; then
        # Increment recovery count
        success_count=$((success_count + 1))
        write_interface_state "$interface" "$success_count"
        
        if [ "$success_count" -ge "$RECOVERY_COUNT" ]; then
            echo "ready"
            return 0
        else
            echo "recovering:${success_count}"
            return 1
        fi
    else
        # Reset recovery count on failure
        write_interface_state "$interface" "0"
        echo "failed"
        return 1
    fi
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

    # Check interface readiness for primary and secondary
    PRIMARY_STATUS=$(is_interface_ready "$PRIMARY_IF" "$PRIMARY_LOSS")
    SECONDARY_STATUS=$(is_interface_ready "$SECONDARY_IF" "$SECONDARY_LOSS")

    if [ -n "$BACKUP_IF" ]; then
        echo "Ping results: $PRIMARY_IF: $PRIMARY_LOSS%, $SECONDARY_IF: $SECONDARY_LOSS%, $BACKUP_IF: $BACKUP_LOSS%"
    else
        echo "Ping results: $PRIMARY_IF: $PRIMARY_LOSS%, $SECONDARY_IF: $SECONDARY_LOSS%"
    fi

    # Get current interface
    CURRENT_IF=$(sudo ip -4 -oneline route show table "$GFW_ROUTING_TABLE" | grep -o "dev.*" | awk '{print $2}')
    DEFAULT_ROUTE=$(ip -4 -oneline route show default 0.0.0.0/0)
    DEFAULT_IF=$(echo "$DEFAULT_ROUTE" | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')

    # Determine which interfaces are actually available (passed RESUME_COUNTS threshold)
    PRIMARY_READY=false
    SECONDARY_READY=false
    
    if [ "$PRIMARY_STATUS" = "ready" ]; then
        PRIMARY_READY=true
    fi
    
    if [ "$SECONDARY_STATUS" = "ready" ]; then
        SECONDARY_READY=true
    fi

    # Make the interface switch decision by following rules
    if [ "$PRIMARY_READY" = false ] && [ "$SECONDARY_READY" = false ]; then
        # If both interfaces are not ready, then switch to backup or default route
        if [ -n "$BACKUP_IF" ] && [ "$BACKUP_LOSS" -le "$LOSS_THRESHOLD" ]; then
            NEXT_IF="$BACKUP_IF"
        else
            NEXT_IF="$DEFAULT_IF"
        fi
    elif [ "$CURRENT_IF" = "$DEFAULT_IF" ] || [ -z "$CURRENT_IF" ] || [ "$CURRENT_IF" = "$BACKUP_IF" ]; then
        # Switch from default or backup interface to best available interface
        if [ "$PRIMARY_READY" = true ] && [ "$SECONDARY_READY" = true ]; then
            # Both ready, choose the one with lower loss
            if [ "$PRIMARY_LOSS" -le "$SECONDARY_LOSS" ]; then
                NEXT_IF="$PRIMARY_IF"
            else
                NEXT_IF="$SECONDARY_IF"
            fi
        elif [ "$PRIMARY_READY" = true ]; then
            NEXT_IF="$PRIMARY_IF"
        elif [ "$SECONDARY_READY" = true ]; then
            NEXT_IF="$SECONDARY_IF"
        else
            # Neither ready, stay on default/backup
            NEXT_IF="$CURRENT_IF"
        fi
    elif [ "$PRIMARY_READY" = true ] && [ "$SECONDARY_READY" = true ] && [ "$PRIMARY_LOSS" -lt "$SW_THRESHOLD" ] && [ "$SECONDARY_LOSS" -lt "$SW_THRESHOLD" ]; then
        # If both interfaces are good, and current is not default, then stay
        NEXT_IF="$CURRENT_IF"
    elif [ "$CURRENT_IF" = "$PRIMARY_IF" ] && [ "$PRIMARY_READY" = false ]; then
        # Current primary is not ready, switch to secondary if ready
        if [ "$SECONDARY_READY" = true ]; then
            NEXT_IF="$SECONDARY_IF"
        elif [ -n "$BACKUP_IF" ] && [ "$BACKUP_LOSS" -le "$LOSS_THRESHOLD" ]; then
            NEXT_IF="$BACKUP_IF"
        else
            NEXT_IF="$DEFAULT_IF"
        fi
    elif [ "$CURRENT_IF" = "$SECONDARY_IF" ] && [ "$SECONDARY_READY" = false ]; then
        # Current secondary is not ready, switch to primary if ready
        if [ "$PRIMARY_READY" = true ]; then
            NEXT_IF="$PRIMARY_IF"
        elif [ -n "$BACKUP_IF" ] && [ "$BACKUP_LOSS" -le "$LOSS_THRESHOLD" ]; then
            NEXT_IF="$BACKUP_IF"
        else
            NEXT_IF="$DEFAULT_IF"
        fi
    else
        # At least one interface is worse than stay zone, switch to best available interface
        if [ "$PRIMARY_READY" = true ] && [ "$SECONDARY_READY" = true ]; then
            if [ "$PRIMARY_LOSS" -le "$SECONDARY_LOSS" ]; then
                NEXT_IF="$PRIMARY_IF"
            else
                NEXT_IF="$SECONDARY_IF"
            fi
        elif [ "$PRIMARY_READY" = true ]; then
            NEXT_IF="$PRIMARY_IF"
        elif [ "$SECONDARY_READY" = true ]; then
            NEXT_IF="$SECONDARY_IF"
        else
            NEXT_IF="$CURRENT_IF"
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

    # Log interface status changes
    case "$PRIMARY_STATUS" in
        failed)
            log_message "$PRIMARY_IF: Failed (${PRIMARY_LOSS}% loss)"
            ;;
        recovering:*)
            RECOVERY_COUNT_VAL=$(echo "$PRIMARY_STATUS" | cut -d':' -f2)
            log_message "$PRIMARY_IF: Recovering (${PRIMARY_LOSS}% loss), recovery count: ${RECOVERY_COUNT_VAL}/${RECOVERY_COUNT}"
            ;;
        ready)
            PRIMARY_COUNT=$(read_interface_state "$PRIMARY_IF")
            if [ "$PRIMARY_COUNT" = "$RECOVERY_COUNT" ]; then
                log_message "$PRIMARY_IF: Now available (${PRIMARY_LOSS}% loss), passed ${RECOVERY_COUNT} consecutive tests"
            fi
            ;;
    esac

    case "$SECONDARY_STATUS" in
        failed)
            log_message "$SECONDARY_IF: Failed (${SECONDARY_LOSS}% loss)"
            ;;
        recovering:*)
            RECOVERY_COUNT_VAL=$(echo "$SECONDARY_STATUS" | cut -d':' -f2)
            log_message "$SECONDARY_IF: Recovering (${SECONDARY_LOSS}% loss), recovery count: ${RECOVERY_COUNT_VAL}/${RECOVERY_COUNT}"
            ;;
        ready)
            SECONDARY_COUNT=$(read_interface_state "$SECONDARY_IF")
            if [ "$SECONDARY_COUNT" = "$RECOVERY_COUNT" ]; then
                log_message "$SECONDARY_IF: Now available (${SECONDARY_LOSS}% loss), passed ${RECOVERY_COUNT} consecutive tests"
            fi
            ;;
    esac

    clean_and_exit 0
}

main "$@"