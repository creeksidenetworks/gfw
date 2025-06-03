#!/bin/bash
# WireGurad interface bring up scripts
# (c) 2023 Creekside Networks LLC, Jackson Tong
# this file should be placed at /config/scripts/post-config.d

# Conf & Log files
WIREGURAD_DEB_PATH=/config/user-data/wireguard/deb

# Log file path
LOG_FILE="/var/log/wireguard.log"

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

# check if WireGuard is installed already (VyOS preinstalled, it will always be ok)
if [[ $(dpkg-query -W -f='${Status} ${Version}\n' wireguard | awk '{print $2}') != 'ok' ]]; then
    # check firmware version to decide which package to install
    version=$(cat /etc/version | cut -d . -f 3)
    db_package=${WIREGURAD_DEB_PATH}/wireguard_${version}.deb
    if [ -f $db_package ]; then
        log_message "install WireGuard package \"$db_package\""
        sudo dpkg -i "$db_package" &> /dev/null 
    else 
        log_message "wireguard deb package \"$db_package\" not found!" 3
    fi
else
    echo "wireguard already installed"
fi

exit 0
