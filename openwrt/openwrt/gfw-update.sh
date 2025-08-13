#!/bin/ash
# (c) 2022-2024 Creekside Networks LLC, Jackson Tong
# This script will decide the best tunnel for jailbreak based on ping result
# Setup a cron job to run it every 2-3 minutes
# for Openwrt

gfw_tun1="wg252"
gfw_tun2="wg253"
target_ip="8.8.8.8"
ping_count=6

# Get the current script's path
ROOT_PATH=$(dirname "$(readlink -f "$0")")

TUN1_PING_FILE=$(mktemp)
TUN2_PING_FILE=$(mktemp)

# Log function
log() {
    local log_file="/var/log/gfw.log"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$log_file"
}

# Ping both tunnels in the background and save results to temporary files
echo "start pings"
ping -I $gfw_tun1 -c $ping_count $target_ip > ${TUN1_PING_FILE} &
ping -I $gfw_tun2 -c $ping_count $target_ip > ${TUN2_PING_FILE} &

# Wait for both pings to complete
wait

# Get latencies from the temporary files
latency1=$(tail -1 ${TUN1_PING_FILE} | awk -F '/' '{print $5}' | awk '{print $1}')
latency2=$(tail -1 ${TUN2_PING_FILE} | awk -F '/' '{print $5}' | awk '{print $1}')
# Trim the part after "." of latency, make it an integer
latency1=${latency1%.*}
latency2=${latency2%.*}

# Check if latencies are valid, if not set them to a high value
if [ -z "$latency1" ]; then
    latency1=9999
fi

if [ -z "$latency2" ]; then
    latency2=9999
fi

echo "$latency1 and $latency2"

# Check if both tunnels are unreachable
if [ "$latency1" -eq 9999 ] && [ "$latency2" -eq 9999 ]; then
    # If both tunnels are unreachable, use the default interface of the main routing table
    default_if_ip=$(ip ro show | grep '^default' | grep -o via.* | awk '{print $2}')
    default_if=$(ip ro show | grep '^default' | grep -o dev.* | awk '{print $2}')
    if -z $default_if_ip; then
        new_route="dev $default_if"
    else
        new_route="via $default_if_ip dev $default_if"
    fi

    best_latency=9999
    log "both tunnels are unreachable, using default interface $default_if"
else
    # Determine the tunnel with the lowest latency
    best_tunnel=$(awk -v lat1="$latency1" -v lat2="$latency2" -v tun1="$gfw_tun1" -v tun2="$gfw_tun2" 'BEGIN { if (lat1 < lat2) print tun1; else print tun2 }')
    best_latency=$(awk -v lat1="$latency1" -v lat2="$latency2" 'BEGIN { if (lat1 < lat2) print lat1; else print lat2 }')
    new_route="dev $best_tunnel"
    echo "best tunnel is $best_tunnel with latency $best_latency"
fi

# Get the current default route for table 100
current_route_table_100=$(ip route show table 100 | grep '^default' | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

# Update routing table 100's default route if it doesn't match the best tunnel
if [ "$current_route_table_100" != "$best_tunnel" ]; then
    ip route show | grep "^$target_ip" | while read -r route; do
        ip route del $route
    done
    ip route add $target_ip $new_route metric 1
    ip route show table 100 | grep "^default" | while read -r route; do
        ip route del table 100 $route 
    done
    ip route add table 100 default $new_route metric 1 
    log "updated gfw route to use $new_route with latency $best_latency "
else
    echo "gfw route is already using $best_tunnel with latency $best_latency"    
fi

# Clean up temporary files
rm ${TUN1_PING_FILE}
rm ${TUN2_PING_FILE}

