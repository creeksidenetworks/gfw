#!/bin/ash
# (c) 2022-2024 Creekside Networks LLC, Jackson Tong
# This script will prepare for the gfw jailbreak. Need to run one time after reboot.
# for Openwrt

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

sdw_backup="40.118.161.200"
# Get the current script's path
ROOT_PATH=$(dirname "$(readlink -f "$0")")
CONF_PATH="${ROOT_PATH}/conf"
LOG_FILE="/var/log/gfw.log"

# Log function
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Log startup
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

log "Starting gfw-startup script"


# Check if coreutils-base64 is installed
if ! opkg list-installed | grep -q 'coreutils-base64'; then
    echo "coreutils-base64 is not installed. Installing..."
    opkg update
    opkg install coreutils-base64 nano tcpdump

    if [ $? -eq 0 ]; then
        log "coreutils-base64 installed successfully."
    else
        log "Failed to install coreutils-base64."
        exit 1
    fi
else
    echo "coreutils-base64 is already installed."
fi

# restart dnsmasq if needed
pid=$(sudo netstat -tulnp | grep 0.0.0.0:55353 | grep tcp | awk '{print $7}' | cut -d'/' -f1)
if [ -n "$pid" ]; then
    kill -9 $pid
    log "killed dnsmasq process $pid listening on port 55353"
fi

/usr/sbin/dnsmasq -p 55353 --conf-file="${CONF_PATH}/dnsmasq.conf" 

# Check if dnsmasq service is running
pid=$(sudo netstat -tulnp | grep 0.0.0.0:55353 | grep tcp | awk '{print $7}' | cut -d'/' -f1)
if [ -n "$pid" ]; then
    log "dnsmasq is up with pid=$pid."
else
    log "dnsmasq failed to start"
fi

# Bring up wireguard interfaces
for config_file in ${ROOT_PATH}/conf/wireguard/*.conf; do
    interface=$(basename "$config_file" .conf)
    # Check if the interface already exists and tear it down
    if ip link show "$interface" > /dev/null 2>&1; then
        ip link set "$interface" down
        ip link delete "$interface"
    fi

    # Read configuration from file
    address=$(grep 'Address' "$config_file" | awk '{print $3}')
    private_key=$(grep 'PrivateKey' "$config_file" | awk '{print $3}')
    public_key=$(grep 'PublicKey' "$config_file" | awk '{print $3}')
    allowed_ips=$(grep 'AllowedIPs' "$config_file" | awk '{print $3}')
    endpoint=$(grep 'Endpoint' "$config_file" | awk '{print $3}')
    persistent_keepalive=$(grep 'PersistentKeepalive' "$config_file" | awk '{print $3}')


    # Split endpoint into hostname and port
    endpoint_host=$(echo "$endpoint" | awk -F':' '{print $1}')
    endpoint_port=$(echo "$endpoint" | awk -F':' '{print $2}')

    # Resolve endpoint_host to IP if it is a FQDN
    if ! echo "$endpoint_host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        endpoint_ip=$(nslookup "$endpoint_host" | awk '/^Address 1:/ { print $3; exit }')
        if [ -z "$endpoint_ip" ]; then
            log "Failed to resolve $endpoint_host, using backup IP $sdw_backup"
            endpoint_ip="$sdw_backup"
        fi
        endpoint="$endpoint_ip:$endpoint_port"
    fi

    # Set up WireGuard interface
    ip link add "$interface" type wireguard
    ip address add "$address" dev "$interface"
    
    temp_private_key_file=$(mktemp)
    echo "$private_key" > "$temp_private_key_file"
    wg set "$interface" private-key "$temp_private_key_file"
    rm "$temp_private_key_file"
    
    wg set "$interface" peer "$public_key" allowed-ips "$allowed_ips" endpoint "$endpoint" persistent-keepalive "$persistent_keepalive"
    ip link set "$interface" up

    # Allow traffic forwarding between br-lan and wgx interfaces
    iptables -I FORWARD 1 -i br-lan -o "$interface" -j ACCEPT
    iptables -I FORWARD 1 -i br-guest -o "$interface" -j ACCEPT

    # Enable source NAT for traffic to wgx interfaces
    iptables -t nat -A POSTROUTING -o "$interface" -j MASQUERADE

    log "$interface configured."
done

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Add gooogle DNS routing and gfw routing table
ip route add 8.8.8.8/32 dev $interface metric 100
ip route add table 100 default dev $interface metric 100

log "routing table configured."

# create ip ipset LIBERTY_ADDRESS_GRP and add 8.8.8.8/8.8.4.4 to it
if ! ipset list LIBERTY_ADDRESS_GRP > /dev/null 2>&1; then
    ipset create LIBERTY_ADDRESS_GRP hash:ip
    ipset add LIBERTY_ADDRESS_GRP 8.8.8.8
    ipset add LIBERTY_ADDRESS_GRP 8.8.4.4
    log "created ipset LIBERTY_ADDRESS_GRP."
else
    log "ipset LIBERTY_ADDRESS_GRP already exists."
fi

# Add policy route for LIBERTY_ADDRESS_GRP
ip rule add from all fwmark 1 lookup 100
iptables -t mangle -A PREROUTING -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 1
iptables -t mangle -A PREROUTING -s 192.168.9.0/24 -j MARK --set-mark 1
log "Policy routing for LIBERTY_ADDRESS_GRP configured."

# force local network 192.168.8.0/24 dns requst to smart dns
iptables -t nat -A PREROUTING -s 192.168.8.0/24 -p udp --dport 53 -j DNAT --to-destination 192.168.8.1:55353
# force global network 192.168.9.0/24 dns requst to google dns
iptables -t nat -A PREROUTING -s 192.168.9.0/24 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53

log "DNAT for DNS requests configured."

# check if the cron tab file is linked to /etc/crontabs/root
if [ ! -L /etc/crontabs/root ]; then
    ln -fs ${ROOT_PATH}/conf/crontabs.root /etc/crontabs/root
    log "linked crontab file."
else
    log "crontab file already linked."
fi

# update Wifi

# Change all wireless interfaces to 20Mhz channel wide
uci set wireless.radio0.htmode='HT20'
uci set wireless.radio1.htmode='HT20'
uci set wireless.@wifi-device[0].disabled=0
uci set wireless.@wifi-device[1].disabled=0

# Main WiFi 
uci set wireless.@wifi-iface[0].ssid="LibertySmart"
uci set wireless.@wifi-iface[0].encryption="psk2"
uci set wireless.@wifi-iface[0].key="Good2Great"
uci set wireless.@wifi-iface[0].disabled=0

uci set wireless.@wifi-iface[1].ssid="LibertySmart"
uci set wireless.@wifi-iface[1].encryption="psk2"
uci set wireless.@wifi-iface[1].key="Good2Great"
uci set wireless.@wifi-iface[1].disabled=0

# Guest WiFi 
uci set wireless.@wifi-iface[2].ssid="LibertyGlobal"
uci set wireless.@wifi-iface[2].encryption="psk2"
uci set wireless.@wifi-iface[2].key="Good2Great"
uci set wireless.@wifi-iface[2].disabled=0

uci set wireless.@wifi-iface[3].ssid="LibertyGlobal"
uci set wireless.@wifi-iface[3].encryption="psk2"
uci set wireless.@wifi-iface[3].key="Good2Great"
uci set wireless.@wifi-iface[3].disabled=0

# Commit the changes
uci commit wireless

# Reload the Wi-Fi settings
wifi reload

# check if this script is linked to /etc/rc.local
if [ ! -f /etc/hotplug.d/iface/98-gfw ]; then
    log "Autostartup script linked to /etc/hotplug.d/iface/98-gfw"
    echo "/etc/config/gfw/gfw-startup.sh" >  /etc/hotplug.d/iface/98-gfw
    chmod +x /etc/hotplug.d/iface/98-gfw
else
    log "Autostartup script already linked"
fi

# preserve the new file during upgrade
if cat /etc/sysupgrade.conf | grep -q "/etc/hotplug.d/iface/98-gfw"; then
    echo "Startup script file already preserved"
else
    echo "/etc/hotplug.d/iface/98-gfw" >> "/etc/sysupgrade.conf"
    echo "Preserve startup script file"
fi
