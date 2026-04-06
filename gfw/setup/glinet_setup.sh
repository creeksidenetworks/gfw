#!/bin/sh
# Openwrt gfw jailbreak configuration utility v1
# (c) 2025 Creekside Networks LLC, Jackson Tong
# Usage: ssh -t root@<router ip> "$(<./gfw-setup.sh)"

LOG_FILE="/var/log/gfw.log"
# Define cron jobs: "schedule|script_file|args|description"
GFW_SCRIPT_PATH="/etc/config/gfw/bin"
GFW_SCRIPT_JOBS="*/2 * * * *|$GFW_SCRIPT_PATH/wg_peer_update.sh||wg_peer_update
*/2 * * * *|$GFW_SCRIPT_PATH/gfw_peer_update.sh|-b wg251|gfw_peer_update
0 0 * * 0|$GFW_SCRIPT_PATH/update_dnsmasq_rulesets.sh||update_dnsmasq_rulesets"

# Function to log messages
log_message() {
    local message=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to file only, no terminal output to avoid confusion
    printf "%s %s\n" "$timestamp" "$message" >> "$LOG_FILE" 2>/dev/null

    # Ensure the log file does not exceed 1000 lines
    if [ -f "$LOG_FILE" ]; then
        line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$line_count" -gt 1000 ]; then
            tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null
            mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
}

# Function to validate device ID
validate_device_id() {
    local id="$1"
    if [ -z "$id" ]; then
        return 1
    fi
    # Check if it's a number
    case "$id" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Check if it's in range 1-249
    if [ "$id" -ge 1 ] && [ "$id" -le 249 ]; then
        return 0
    else
        return 1
    fi
}

# Function to validate WireGuard private key format
validate_wg_key() {
    local key="$1"
    if [ -z "$key" ]; then
        return 1
    fi
    # WireGuard keys are 44 characters long and base64 encoded
    if [ ${#key} -eq 44 ]; then
        return 0
    else
        return 1
    fi
}

# Function to configure WiFi settings
configure_wifi() {
    local main_ssid="$1"
    local main_password="$2"
    local guest_ssid="$3"
    local guest_password="$4"
    
    log_message "Starting WiFi configuration: main_ssid=$main_ssid, guest_ssid=$guest_ssid"
    echo "Analyzing current WiFi configuration..."
    
    # Find 5GHz and 2.4GHz radios
    RADIO_5G=""
    RADIO_2G=""
    
    # Check each radio to determine band
    for radio in radio0 radio1 radio2; do
        if uci get "wireless.$radio" >/dev/null 2>&1; then
            band=$(uci get "wireless.$radio.band" 2>/dev/null || echo "")
            if [ "$band" = "5g" ]; then
                RADIO_5G=$radio
                echo "Found 5GHz radio: $radio"
            elif [ "$band" = "2g" ]; then
                RADIO_2G=$radio
                echo "Found 2.4GHz radio: $radio"
            fi
        fi
    done
    
    if [ -z "$RADIO_5G" ] || [ -z "$RADIO_2G" ]; then
        log_message "WiFi configuration failed: Could not identify both radios (5GHz=$RADIO_5G, 2.4GHz=$RADIO_2G)"
        echo "Warning: Could not identify both 5GHz and 2.4GHz radios"
        echo "5GHz radio: $RADIO_5G, 2.4GHz radio: $RADIO_2G"
        return 1
    fi
    
    # Disable 2.4GHz radio
    echo "Disabling 2.4GHz radio ($RADIO_2G)..."
    uci set "wireless.$RADIO_2G.disabled=1"
    
    # Configure 5GHz radio for 20MHz bandwidth
    echo "Configuring 5GHz radio ($RADIO_5G) for 20MHz bandwidth..."
    uci set "wireless.$RADIO_5G.htmode=HT20"
    uci set "wireless.$RADIO_5G.disabled=0"
    
    # Find and configure 5GHz main WiFi interface
    MAIN_5G_INTERFACE=""
    for iface in "default_$RADIO_5G" "default_radio0" "default_radio1"; do
        if uci get "wireless.$iface" >/dev/null 2>&1; then
            device=$(uci get "wireless.$iface.device" 2>/dev/null || echo "")
            if [ "$device" = "$RADIO_5G" ]; then
                MAIN_5G_INTERFACE=$iface
                break
            fi
        fi
    done
    
    if [ -n "$MAIN_5G_INTERFACE" ]; then
        echo "Configuring 5GHz main WiFi interface ($MAIN_5G_INTERFACE)..."
        uci set "wireless.$MAIN_5G_INTERFACE.ssid=$main_ssid"
        uci set "wireless.$MAIN_5G_INTERFACE.key=$main_password"
        uci set "wireless.$MAIN_5G_INTERFACE.encryption=psk2"
    else
        echo "Warning: Could not find main WiFi interface for 5GHz radio"
        return 1
    fi
    
    # Find and configure 2.4GHz main WiFi interface (update SSID to match, but keep disabled)
    MAIN_2G_INTERFACE=""
    for iface in "default_$RADIO_2G" "default_radio0" "default_radio1"; do
        if uci get "wireless.$iface" >/dev/null 2>&1; then
            device=$(uci get "wireless.$iface.device" 2>/dev/null || echo "")
            if [ "$device" = "$RADIO_2G" ]; then
                MAIN_2G_INTERFACE=$iface
                break
            fi
        fi
    done
    
    if [ -n "$MAIN_2G_INTERFACE" ]; then
        echo "Updating 2.4GHz main WiFi interface ($MAIN_2G_INTERFACE) SSID..."
        uci set "wireless.$MAIN_2G_INTERFACE.ssid=$main_ssid"
        uci set "wireless.$MAIN_2G_INTERFACE.key=$main_password"
        uci set "wireless.$MAIN_2G_INTERFACE.encryption=psk2"
    else
        echo "Warning: Could not find main WiFi interface for 2.4GHz radio"
    fi
    
    # Find and configure 5GHz global network interface
    GUEST_5G_INTERFACE=""
    for iface in guest5g guest_5g; do
        if uci get "wireless.$iface" >/dev/null 2>&1; then
            device=$(uci get "wireless.$iface.device" 2>/dev/null || echo "")
            if [ "$device" = "$RADIO_5G" ]; then
                GUEST_5G_INTERFACE=$iface
                break
            fi
        fi
    done
    
    if [ -n "$GUEST_5G_INTERFACE" ]; then
        echo "Configuring 5GHz global network ($GUEST_5G_INTERFACE)..."
        uci set "wireless.$GUEST_5G_INTERFACE.ssid=$guest_ssid"
        uci set "wireless.$GUEST_5G_INTERFACE.key=$guest_password"
        uci set "wireless.$GUEST_5G_INTERFACE.encryption=psk2"
        uci set "wireless.$GUEST_5G_INTERFACE.disabled=0"
    else
        echo "Warning: Could not find 5GHz global network interface"
    fi
    
    # Disable 2.4GHz global network interface if it exists
    GUEST_2G_INTERFACE=""
    for iface in guest2g guest_2g; do
        if uci get "wireless.$iface" >/dev/null 2>&1; then
            device=$(uci get "wireless.$iface.device" 2>/dev/null || echo "")
            if [ "$device" = "$RADIO_2G" ]; then
                GUEST_2G_INTERFACE=$iface
                break
            fi
        fi
    done
    
    if [ -n "$GUEST_2G_INTERFACE" ]; then
        echo "Disabling 2.4GHz global network ($GUEST_2G_INTERFACE)..."
        uci set "wireless.$GUEST_2G_INTERFACE.disabled=1"
    fi
    
    # Commit wireless changes
    uci commit wireless
    
    log_message "WiFi configuration completed successfully"
    echo "WiFi configuration completed:"
    echo "  Main WiFi: $main_ssid (5GHz, 20MHz) on $RADIO_5G"
    echo "  Global Network: $guest_ssid (5GHz, 20MHz) on $RADIO_5G"
    echo "  2.4GHz radio: Disabled ($RADIO_2G) - SSID updated to match 5GHz"
    
    return 0
}

# Function to configure WireGuard interface
# Usage: configure_wg_interface <interface_name> <network_octet> <private_key> <peer_public_key> <endpoint_host> <endpoint_port>
configure_wg_interface() {
    local interface="$1"
    local network_octet="$2"
    local private_key="$3"
    local peer_public_key="$4"
    local endpoint_host="$5"
    local endpoint_port="$6"
    
    log_message "Starting WireGuard interface configuration: $interface"
    if [ $# -ne 6 ]; then
        log_message "WireGuard configuration failed: Invalid arguments for $interface"
        echo "Error: configure_wg_interface requires 6 arguments"
        echo "Usage: configure_wg_interface <interface> <network_octet> <private_key> <peer_public_key> <endpoint_host> <endpoint_port>"
        return 1
    fi
    
    local wg_ip_address="10.${network_octet}.255.${DEVICE_ID}/24"
    
    echo "Setting up $interface WireGuard interface..."
    
    # Check if interface exists
    echo "Checking for existing $interface interface..."
    if uci get "network.$interface" >/dev/null 2>&1; then
        echo "$interface interface already exists. Removing existing configuration..."
        
        # Remove existing interface configuration
        uci delete "network.$interface" 2>/dev/null || true
        
        # Remove existing peer configuration
        # Find and remove all wireguard sections for this interface
        section_index=0
        while uci get "network.@wireguard_${interface}[$section_index]" >/dev/null 2>&1; do
            uci delete "network.@wireguard_${interface}[$section_index]" 2>/dev/null || true
            section_index=$((section_index + 1))
        done
        
        # Also check for any remaining wireguard sections that might reference this interface
        section_index=0
        while uci get "network.@wireguard[$section_index]" >/dev/null 2>&1; do
            # This is a more generic cleanup in case the naming convention differs
            uci delete "network.@wireguard[$section_index]" 2>/dev/null || true
            section_index=$((section_index + 1))
        done
        
        # Remove from firewall WAN zone if present
        wan_zone_index=""
        zone_index=0
        while uci get "firewall.@zone[$zone_index]" >/dev/null 2>&1; do
            if [ "$(uci get firewall.@zone[$zone_index].name 2>/dev/null)" = "wan" ]; then
                wan_zone_index=$zone_index
                break
            fi
            zone_index=$((zone_index + 1))
        done
        
        if [ -n "$wan_zone_index" ]; then
            # Remove interface from WAN zone network list
            uci del_list "firewall.@zone[$wan_zone_index].network=$interface" 2>/dev/null || true
        fi
        
        # Commit the deletions
        uci commit network
        uci commit firewall
        
        echo "Existing $interface configuration removed."
    fi
    
    echo "Creating new $interface WireGuard interface..."
    
    # Create interface configuration
    uci set "network.$interface=interface"
    uci set "network.$interface.proto=wireguard"
    uci set "network.$interface.private_key=$private_key"
    uci add_list "network.$interface.addresses=$wg_ip_address"
    
    # Add peer configuration
    uci add network "wireguard_$interface"
    uci set "network.@wireguard_${interface}[-1].public_key=$peer_public_key"
    uci set "network.@wireguard_${interface}[-1].allowed_ips=0.0.0.0/0"
    uci set "network.@wireguard_${interface}[-1].endpoint_host=$endpoint_host"
    uci set "network.@wireguard_${interface}[-1].endpoint_port=$endpoint_port"
    uci set "network.@wireguard_${interface}[-1].persistent_keepalive=25"
    
    # Commit network changes
    uci commit network
    
    # Add interface to firewall WAN zone
    echo "Adding $interface to firewall WAN zone..."
    
    # Find the WAN zone index by searching for name='wan'
    wan_zone_index=""
    zone_index=0
    while uci get "firewall.@zone[$zone_index]" >/dev/null 2>&1; do
        if [ "$(uci get firewall.@zone[$zone_index].name 2>/dev/null)" = "wan" ]; then
            wan_zone_index=$zone_index
            break
        fi
        zone_index=$((zone_index + 1))
    done
    
    if [ -n "$wan_zone_index" ]; then
        # Check if interface is already in the WAN zone
        if ! uci get "firewall.@zone[$wan_zone_index].network" 2>/dev/null | grep -q "$interface"; then
            uci add_list "firewall.@zone[$wan_zone_index].network=$interface"
            uci commit firewall
            echo "$interface added to WAN firewall zone."
        else
            echo "$interface already exists in WAN firewall zone."
        fi
    else
        echo "Warning: WAN firewall zone not found. Skipping firewall configuration."
    fi
    
    log_message "WireGuard interface $interface configured successfully: $wg_ip_address -> $endpoint_host:$endpoint_port"
    echo "WireGuard $interface interface created with:"
    echo "  Address: $wg_ip_address"
    echo "  Endpoint: $endpoint_host:$endpoint_port"
    echo "  Peer PublicKey: $peer_public_key"
    echo "  Firewall Zone: WAN"
    echo "WireGuard $interface setup complete!"
    echo
    
    return 0
}

# Function to configure dnsmasq settings
configure_dnsmasq() {
    log_message "Starting dnsmasq configuration"
    echo "Configuring dnsmasq settings..."
    
    local dnsmasq_changed=false
    
    # 1. Check and add conf-dir setting
    echo "Checking dnsmasq conf-dir configuration..."
    if ! uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q "/etc/config/gfw/conf"; then
        echo "Adding conf-dir=/etc/config/gfw/conf to dnsmasq..."
        uci add_list dhcp.@dnsmasq[0].confdir='/etc/config/gfw/conf'
        dnsmasq_changed=true
    else
        echo "dnsmasq conf-dir already configured."
    fi
    
    # Create GFW configuration directory if it doesn't exist
    if [ ! -d "/etc/config/gfw/conf" ]; then
        echo "Creating GFW configuration directory..."
        mkdir -p "/etc/config/gfw/conf"
        
        # Create placeholder configuration file
        if [ ! -f "/etc/config/gfw/conf/dnsmasq_gfw_custom.conf" ]; then
            echo "Creating placeholder dnsmasq_gfw_custom.conf..."
            touch "/etc/config/gfw/conf/dnsmasq_gfw_custom.conf"
        fi
    else
        echo "GFW configuration directory already exists."
    fi
    
    # 2. Restart dnsmasq if configuration changed
    if [ "$dnsmasq_changed" = "true" ]; then
        echo "Committing dnsmasq configuration changes..."
        uci commit dhcp
        
        echo "Restarting dnsmasq service..."
        /etc/init.d/dnsmasq restart
        
        # Wait a moment for service to start
        sleep 2
        
        # Check if dnsmasq is running properly
        if ! pgrep dnsmasq >/dev/null 2>&1; then
            log_message "dnsmasq configuration failed: Service failed to restart"
            echo "Error: dnsmasq failed to restart properly!"
            echo "Configuration may have errors. Please check manually."
            return 1
        else
            log_message "dnsmasq configuration completed successfully"
            echo "dnsmasq restarted successfully."
        fi
    else
        log_message "dnsmasq configuration skipped: No changes needed"
        echo "No dnsmasq configuration changes needed."
    fi
    
    return 0
}

# Function to check cron jobs status
check_cron_jobs_status() {
    local jobs="$1"
    local cron_file="/etc/crontabs/root"

    # Create crontab file and directory if they don't exist
    mkdir -p /etc/crontabs
    touch "$cron_file"
    chmod 600 "$cron_file"
    

    # Check if GFW scripts directory exists
    if [ ! -d "$GFW_SCRIPT_PATH" ]; then
        echo "  - GFW scripts directory not found: $GFW_SCRIPT_PATH"
        echo "  - All cron jobs require GFW system installation first"
        return 1
    fi
    
    # If no crontab file exists at all
    if [ ! -f "$cron_file" ]; then
        echo "  - No crontab file found ($cron_file), all cron jobs need configuration"
        return 1
    fi
    
    # Use here document to avoid subshell issues with pipe
    local needs_config=false
    while IFS='|' read -r schedule script_path args description; do
        [ -z "$script_path" ] && continue
        
        # Extract filename from full path for display
        local script_name="${script_path##*/}"
        
        # Check if script exists
        if [ ! -f "$script_path" ]; then
            echo "  - $description cron job: Script missing ($script_name)"
            needs_config=true
            continue
        fi
        
        # Check if cron job exists in file
        if grep -qF "$script_path" "$cron_file" 2>/dev/null; then
            echo "  - $description cron job: Already configured"
        else
            echo "  - $description cron job: Not configured"
            needs_config=true
        fi
    done << EOF
$jobs
EOF
    
    # Return based on needs_config status
    [ "$needs_config" = "true" ] && return 1 || return 0
}

# Function to configure cron jobs
configure_cron_jobs() {
    local jobs="$1"
    
    log_message "Starting cron jobs configuration"
    echo "Configuring cron jobs..."
    
    local cron_file="/etc/crontabs/root"
    local changes_made=false
    
    # Process each cron job
    echo "$jobs" | while IFS='|' read -r schedule script_path args description; do
        [ -z "$script_path" ] && continue
        
        # Extract filename from full path for display
        local script_name="${script_path##*/}"
        
        # Check if script exists
        if [ ! -f "$script_path" ]; then
            echo "Warning: Script not found: $script_name"
            log_message "Cron job skipped: $script_path not found"
            continue
        fi
        
        # Remove any existing lines containing this script
        if grep -qF "$script_path" "$cron_file" 2>/dev/null; then
            echo "Updating $description cron job..."
            grep -vF "$script_path" "$cron_file" > "$cron_file.tmp"
            mv "$cron_file.tmp" "$cron_file"
            changes_made=true
        else
            echo "Adding $description cron job..."
            changes_made=true
        fi
        
        # Add the new cron job line
        local cron_line="$schedule $script_path"
        [ -n "$args" ] && cron_line="$cron_line $args"
        echo "$cron_line" >> "$cron_file"
    done
    
    if [ "$changes_made" = "true" ]; then
        /etc/init.d/cron restart
        log_message "Cron jobs configuration completed successfully"
        echo "Cron jobs installed successfully."
    else
        log_message "Cron jobs configuration skipped: All jobs already configured"
        echo "All cron jobs already configured."
    fi
    
    return 0
}

main() {
    log_message "=== Starting OpenWrt GFW Setup Configuration ==="
    echo "=== OpenWrt GFW Setup Configuration ==="
    echo

    # Disable IPv6 globally
    echo "Disabling IPv6 globally..."
    if ! grep -q '^net.ipv6.conf.all.disable_ipv6=1' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.ipv6.conf.all.disable_ipv6=1' >> /etc/sysctl.conf
    fi
    if ! grep -q '^net.ipv6.conf.default.disable_ipv6=1' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.ipv6.conf.default.disable_ipv6=1' >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    log_message "IPv6 disabled globally via sysctl.conf"

    # Initialize summary string
    SUMMARY=""
    
    # Track if any changes are needed
    CHANGES_NEEDED=false

    echo "=== Package Installation Status ==="
    
    # List of packages to check and install
    PACKAGES="coreutils-base64 nano tcpdump bind-dig bind-host"
    
    # Check if all packages are already installed
    ALL_INSTALLED=true
    for pkg in $PACKAGES; do
        if ! opkg list-installed | grep -q "$pkg"; then
            ALL_INSTALLED=false
            break
        fi
    done
    
    # Add package status to summary
    if [ "$ALL_INSTALLED" = "true" ]; then
        SUMMARY="${SUMMARY}  ✓ All required packages already installed\n"
    else
        SUMMARY="${SUMMARY}  - Install required packages (coreutils-base64, nano, tcpdump, bind-dig, bind-host)\n"
        CHANGES_NEEDED=true
    fi

    # Check dnsmasq configuration
    echo
    echo "=== dnsmasq Configuration Status ==="
    DNSMASQ_NEEDS_CONFIG=false
    
    # Check if conf-dir is already configured
    if ! uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q "/etc/config/gfw/conf"; then
        DNSMASQ_NEEDS_CONFIG=true
    fi
        
    # Check if GFW directory exists
    if [ ! -d "/etc/config/gfw/conf" ]; then
        DNSMASQ_NEEDS_CONFIG=true
    fi
    
    # Add dnsmasq status to summary
    if [ "$DNSMASQ_NEEDS_CONFIG" = "true" ]; then
        SUMMARY="${SUMMARY}  - Configure dnsmasq GFW settings\n"
        CHANGES_NEEDED=true
    else
        SUMMARY="${SUMMARY}  ✓ dnsmasq GFW configuration already present\n"
    fi

    # Check cron job configuration
    echo
    echo "=== Cron Jobs Configuration Status ==="
    
    # Check cron jobs status using new function
    if check_cron_jobs_status "$GFW_SCRIPT_JOBS"; then
        SUMMARY="${SUMMARY}  ✓ All required cron jobs already configured\n"
        CRON_NEEDS_CONFIG=false
    else
        SUMMARY="${SUMMARY}  - Configure cron jobs (wg_peer_update, gfw_peer_update, update_dnsmasq_rulesets)\n"
        CHANGES_NEEDED=true
        CRON_NEEDS_CONFIG=true
    fi

    # Check global network routing configuration
    echo
    echo "=== Global Network Configuration Status ==="
    GUEST_ROUTING_NEEDS_CONFIG=false
    
    # Check if DNS redirect rule exists for guest network
    if ! uci get firewall.guest_dns_redirect >/dev/null 2>&1; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if policy routing rule exists for guest network
    if ! uci get firewall.guest_policy_route >/dev/null 2>&1; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if loopback DNS interface exists
    if ! uci get network.loopback_dns >/dev/null 2>&1; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if DNS redirect rule exists for LAN network
    if ! uci get firewall.lan_dns_redirect >/dev/null 2>&1; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if policy routing rule exists for LAN LIBERTY addresses
    if ! uci get firewall.lan_liberty_route >/dev/null 2>&1; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if IP rules exist for table 100
    if ! ip rule show | grep -q "fwmark 0x64/0xff lookup 100"; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    if ! ip rule show | grep -q "fwmark 0x65/0xff lookup 100"; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if iptables rule exists for LAN LIBERTY address matching
    if ! iptables -t mangle -C PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff 2>/dev/null; then
        GUEST_ROUTING_NEEDS_CONFIG=true
    fi
    
    # Check if WAN access rules exist
    if ! uci get firewall.wan_ssh_access >/dev/null 2>&1; then
        echo "  - WAN SSH access: Not configured"
        GUEST_ROUTING_NEEDS_CONFIG=true
    else
        echo "  - WAN SSH access: Already configured"
    fi
    
    if ! uci get firewall.wan_web_access >/dev/null 2>&1; then
        echo "  - WAN web access: Not configured"
        GUEST_ROUTING_NEEDS_CONFIG=true
    else
        echo "  - WAN web access: Already configured"
    fi
    
    if ! uci get firewall.wan_ping_access >/dev/null 2>&1; then
        echo "  - WAN ping access: Not configured"
        GUEST_ROUTING_NEEDS_CONFIG=true
    else
        echo "  - WAN ping access: Already configured"
    fi
    
    # Check if guest network interface is enabled
    if uci get network.guest >/dev/null 2>&1; then
        disabled=$(uci get "network.guest.disabled" 2>/dev/null || echo "0")
        if [ "$disabled" = "1" ]; then
            echo "Found disabled global network interface: guest"
            GUEST_ROUTING_NEEDS_CONFIG=true
        fi
    fi
    
    # Check if guest zone is configured for full access
    guest_zone_configured=false
    guest_zone_index=""
    zone_index=0
    while uci get "firewall.@zone[$zone_index]" >/dev/null 2>&1; do
        if [ "$(uci get firewall.@zone[$zone_index].name 2>/dev/null)" = "guest" ]; then
            guest_zone_index=$zone_index
            input_policy=$(uci get "firewall.@zone[$zone_index].input" 2>/dev/null || echo "")
            forward_policy=$(uci get "firewall.@zone[$zone_index].forward" 2>/dev/null || echo "")
            if [ "$input_policy" = "ACCEPT" ] && [ "$forward_policy" = "ACCEPT" ]; then
                guest_zone_configured=true
            fi
            break
        fi
        zone_index=$((zone_index + 1))
    done
    
    if [ "$guest_zone_configured" = "false" ]; then
        echo "  - Guest zone access: Not configured for full access"
        GUEST_ROUTING_NEEDS_CONFIG=true
    else
        echo "  - Guest zone access: Already configured (INPUT=ACCEPT, FORWARD=ACCEPT)"
    fi
    
    # Add global network routing status to summary
    if [ "$GUEST_ROUTING_NEEDS_CONFIG" = "true" ]; then
        SUMMARY="${SUMMARY}  - Configure network routing (DNS redirect, policy routing, LAN LIBERTY routing, guest zone access, WAN management access)\n"
        CHANGES_NEEDED=true
    else
        SUMMARY="${SUMMARY}  ✓ Network routing configured (guest and LAN networks with policy routing, guest zone access, and WAN management access)\n"
    fi

    # Check if WireGuard interfaces are already configured
    echo
    echo "=== WireGuard Configuration Status ==="
    if uci get network.wg252 >/dev/null 2>&1; then
        echo "Existing WireGuard configuration detected."
        printf "Do you want to keep existing WireGuard configuration? (Y/n): "
        read KEEP_EXISTING
        case "$KEEP_EXISTING" in
            [Nn]|[Nn][Oo])
                echo "  → Will reconfigure WireGuard interfaces"
                RECONFIGURE_WG=true
                CHANGES_NEEDED=true
                ;;
            *)
                echo "  → Keeping existing WireGuard configuration"
                RECONFIGURE_WG=false
                SUMMARY="${SUMMARY}  ✓ WireGuard configuration preserved\n"
                ;;
        esac
    else
        echo "No existing WireGuard configuration found."
        echo "  → New WireGuard setup required"
        RECONFIGURE_WG=true
        SUMMARY="${SUMMARY}  - WireGuard VPN interfaces (wg251, wg252, wg253)\n"
        CHANGES_NEEDED=true
    fi
    
    # Only prompt for device ID and private key if we need to configure WireGuard
    if [ "$RECONFIGURE_WG" = "true" ]; then
        echo
        while true; do
            printf "Enter device ID (1-249): "
            read DEVICE_ID
            if validate_device_id "$DEVICE_ID"; then
                log_message "Device ID validated successfully: $DEVICE_ID"
                break
            else
                log_message "Device ID validation failed: $DEVICE_ID"
                echo "Error: Device ID must be a number between 1 and 249. Please try again."
            fi
        done

        # Prompt for WireGuard private key
        echo
        while true; do
            printf "Enter WireGuard private key: "
            read WG_PRIVATE_KEY
            if validate_wg_key "$WG_PRIVATE_KEY"; then
                log_message "WireGuard private key validated successfully"
                break
            else
                log_message "WireGuard private key validation failed: invalid format"
                echo "Error: Invalid WireGuard private key format. Key must be 44 characters long. Please try again."
            fi
        done
    fi

    # WiFi Configuration Section
    echo
    echo "=== WiFi Configuration ==="
    
    # Check for default WiFi configuration by looking at multiple possible interfaces
    DEFAULT_SSID=""
    UPDATE_WIFI=false
    
    # Check common GL.iNet interface names for default SSID
    for iface in default_radio0 default_radio1 "@wifi-iface[0]" "@wifi-iface[1]"; do
        CURRENT_SSID=$(uci get "wireless.$iface.ssid" 2>/dev/null || echo "")
        if [ -n "$CURRENT_SSID" ] && echo "$CURRENT_SSID" | grep -q "^GL-"; then
            DEFAULT_SSID="$CURRENT_SSID"
            echo "Default WiFi SSID detected: $DEFAULT_SSID (on $iface)"
            break
        fi
    done
    
    if [ -n "$DEFAULT_SSID" ]; then
        printf "Do you want to update WiFi configuration? (y/N): "
        read UPDATE_WIFI_CHOICE
        case "$UPDATE_WIFI_CHOICE" in
            [Yy]|[Yy][Ee][Ss])
                UPDATE_WIFI=true

                # Prompt for new main WiFi credentials with defaults
                echo
                DEFAULT_MAIN_SSID="LibertySmart"
                DEFAULT_MAIN_PASSWORD="Good2Great"
                DEFAULT_GUEST_SSID="LibertyGlobal"
                DEFAULT_GUEST_PASSWORD="Good2Great"

                printf "Enter new main WiFi SSID [LibertySmart]: "
                read NEW_MAIN_SSID
                [ -z "$NEW_MAIN_SSID" ] && NEW_MAIN_SSID="$DEFAULT_MAIN_SSID"

                printf "Enter new main WiFi password (min 8 characters) [Good2Great]: "
                read NEW_MAIN_PASSWORD
                [ -z "$NEW_MAIN_PASSWORD" ] && NEW_MAIN_PASSWORD="$DEFAULT_MAIN_PASSWORD"
                while [ ${#NEW_MAIN_PASSWORD} -lt 8 ]; do
                    printf "Password too short. Enter password (min 8 characters) [Good2Great]: "
                    read NEW_MAIN_PASSWORD
                    [ -z "$NEW_MAIN_PASSWORD" ] && NEW_MAIN_PASSWORD="$DEFAULT_MAIN_PASSWORD"
                done

                # Prompt for new global network credentials with defaults
                echo
                printf "Enter new global network SSID [LibertyGlobal]: "
                read NEW_GUEST_SSID
                [ -z "$NEW_GUEST_SSID" ] && NEW_GUEST_SSID="$DEFAULT_GUEST_SSID"

                printf "Enter new global network password (min 8 characters) [Good2Great]: "
                read NEW_GUEST_PASSWORD
                [ -z "$NEW_GUEST_PASSWORD" ] && NEW_GUEST_PASSWORD="$DEFAULT_GUEST_PASSWORD"
                while [ ${#NEW_GUEST_PASSWORD} -lt 8 ]; do
                    printf "Password too short. Enter password (min 8 characters) [Good2Great]: "
                    read NEW_GUEST_PASSWORD
                    [ -z "$NEW_GUEST_PASSWORD" ] && NEW_GUEST_PASSWORD="$DEFAULT_GUEST_PASSWORD"
                done

                echo "WiFi configuration will be updated."
                SUMMARY="${SUMMARY}  - WiFi networks: $NEW_MAIN_SSID (main), $NEW_GUEST_SSID (global)\n"
                SUMMARY="${SUMMARY}  - 5GHz only, 20MHz bandwidth, 2.4GHz disabled\n"
                CHANGES_NEEDED=true
                ;;
            *)
                echo "Keeping existing WiFi configuration."
                SUMMARY="${SUMMARY}  ✓ WiFi configuration preserved\n"
                ;;
        esac
    else
        echo "WiFi already configured or no default GL.iNet SSID detected."
        echo "Skipping WiFi configuration."
        SUMMARY="${SUMMARY}  ✓ WiFi already customized\n"
    fi

    echo
    if [ "$RECONFIGURE_WG" = "true" ]; then
        echo "Configuration received:"
        echo "Device ID: $DEVICE_ID"
        echo "WireGuard private key: [HIDDEN]"
        if [ "$UPDATE_WIFI" = "true" ]; then
            echo "Main WiFi SSID: $NEW_MAIN_SSID"
            echo "Global Network SSID: $NEW_GUEST_SSID"
        fi
        echo
    fi
    
    # If no changes are needed, show summary and exit
    if [ "$CHANGES_NEEDED" = "false" ]; then
        log_message "System review completed: No changes needed"
        echo "System Review Complete - No Changes Needed!"
        echo
        echo "Current Status:"
        printf "$SUMMARY"
        echo
        echo "Your GL.iNet router is already properly configured."
        echo "No reboot or changes are necessary."
        exit 0
    fi

    # Add reboot to summary if changes will be made
    if [ "$UPDATE_WIFI" = "true" ] || [ "$RECONFIGURE_WG" = "true" ]; then
        SUMMARY="${SUMMARY}  - Reboot system to activate changes\\n"
    fi
    
    echo "This will:"
    printf "$SUMMARY"
    echo
    printf "Do you want to proceed? (y/N): "
    read PROCEED
    case "$PROCEED" in
        [Yy]|[Yy][Ee][Ss])
            log_message "User confirmed setup: Starting configuration process"
            echo "Proceeding with setup..."
            ;;
        *)
            log_message "Setup cancelled by user"
            echo "Setup cancelled by user."
            exit 0
            ;;
    esac
    echo
    
    # Install packages if needed
    if [ "$ALL_INSTALLED" = "false" ]; then
        log_message "Starting package installation"
        echo "Some packages are missing. Updating package list and installing..."
        opkg update
        
        for pkg in $PACKAGES; do
            if ! opkg list-installed | grep -q "$pkg"; then
                echo "Installing $pkg..."
                opkg install "$pkg"
                
                if [ $? -eq 0 ]; then
                    echo "$pkg installed successfully."
                else
                    log_message "Package installation failed: $pkg"
                    echo "Failed to install $pkg."
                    # Decide if you want to exit on failure or continue
                    # exit 1
                fi
            fi
        done
        # Update summary to reflect completion
        log_message "Package installation completed"
        SUMMARY=$(echo "$SUMMARY" | sed 's/- Install required packages.*/✓ Required packages installed/')
    else
        echo "All required packages are already installed."
    fi

    # Configure WiFi if needed
    if [ "$UPDATE_WIFI" = "true" ]; then
        echo "Configuring WiFi settings..."
                
        # Call the WiFi configuration function
        configure_wifi "$NEW_MAIN_SSID" "$NEW_MAIN_PASSWORD" "$NEW_GUEST_SSID" "$NEW_GUEST_PASSWORD"
        
        if [ $? -eq 0 ]; then
            echo "WiFi configuration completed successfully."
            SUMMARY="${SUMMARY}  ✓ WiFi networks configured\n"
        else
            echo "Warning: WiFi configuration may have encountered issues."
            SUMMARY="${SUMMARY}  ⚠ WiFi configuration issues\n"
        fi
    fi

    # Configure dnsmasq if needed
    if [ "$DNSMASQ_NEEDS_CONFIG" = "true" ]; then
        echo "Configuring dnsmasq settings..."
        
        if configure_dnsmasq; then
            echo "dnsmasq configuration completed successfully."
            SUMMARY="${SUMMARY}  ✓ dnsmasq GFW settings configured\n"
        else
            echo "Error: dnsmasq configuration failed!"
            echo "Please check the configuration manually."
            exit 1
        fi
    else
        echo "dnsmasq GFW configuration already present."
    fi

    # Configure cron jobs if needed
    if [ "$CRON_NEEDS_CONFIG" = "true" ]; then
        echo "Configuring cron jobs..."
        
        if configure_cron_jobs "$GFW_SCRIPT_JOBS"; then
            echo "Cron jobs configuration completed successfully."
            SUMMARY="${SUMMARY}  ✓ Cron jobs configured\n"
        else
            echo "Error: Cron jobs configuration failed!"
            echo "Please check the configuration manually."
            exit 1
        fi
    else
        echo "All required cron jobs already configured."
    fi

    # Configure global network routing if needed
    if [ "$GUEST_ROUTING_NEEDS_CONFIG" = "true" ]; then
        echo "Configuring global network routing rules..."
        
        # Enable guest network interface if it's disabled
        echo "Checking and enabling global network interface..."
        if uci get network.guest >/dev/null 2>&1; then
            disabled=$(uci get "network.guest.disabled" 2>/dev/null || echo "0")
            if [ "$disabled" = "1" ]; then
                echo "Enabling global network interface: guest"
                uci set "network.guest.disabled=0"
            else
                echo "Global network interface already enabled."
            fi
        else
            echo "Warning: Guest network interface not found in network configuration."
        fi
        
        # Add DNS redirect rule for global network (redirect all DNS to 8.8.8.8:53)
        if ! uci get firewall.guest_dns_redirect >/dev/null 2>&1; then
            echo "Adding DNS redirect rule for global network..."
            uci set firewall.guest_dns_redirect=redirect
            uci set firewall.guest_dns_redirect.name='Global DNS Redirect'
            uci set firewall.guest_dns_redirect.src='guest'
            uci set firewall.guest_dns_redirect.proto='tcp udp'
            uci set firewall.guest_dns_redirect.src_dport='53'
            uci set firewall.guest_dns_redirect.dest_ip='8.8.8.8'
            uci set firewall.guest_dns_redirect.dest_port='53'
            uci set firewall.guest_dns_redirect.target='DNAT'
        fi
        
        # Add policy routing rule for global network (mark packets from guest network)
        if ! uci get firewall.guest_policy_route >/dev/null 2>&1; then
            echo "Adding policy routing rule for global network..."
            uci set firewall.guest_policy_route=rule
            uci set firewall.guest_policy_route.name='Global Policy Route'
            uci set firewall.guest_policy_route.src='guest'
            uci set firewall.guest_policy_route.set_mark='0x64/0xff'
            uci set firewall.guest_policy_route.target='MARK'
            uci set firewall.guest_policy_route.chain='mangle_prerouting'
        fi
        
        # Configure guest zone for full access (INPUT ACCEPT, FORWARD ACCEPT)
        echo "Configuring guest zone for full access..."
        
        # Find the guest zone and set INPUT/FORWARD to ACCEPT
        guest_zone_index=""
        zone_index=0
        while uci get "firewall.@zone[$zone_index]" >/dev/null 2>&1; do
            if [ "$(uci get firewall.@zone[$zone_index].name 2>/dev/null)" = "guest" ]; then
                guest_zone_index=$zone_index
                break
            fi
            zone_index=$((zone_index + 1))
        done
        
        if [ -n "$guest_zone_index" ]; then
            echo "Found guest zone at index $guest_zone_index, configuring for full access..."
            uci set "firewall.@zone[$guest_zone_index].input=ACCEPT"
            uci set "firewall.@zone[$guest_zone_index].forward=ACCEPT"
            echo "Guest zone configured: INPUT=ACCEPT, FORWARD=ACCEPT"
        else
            echo "Warning: Guest zone not found in firewall configuration"
        fi
        
        # Add loopback interface configuration
        if ! uci get network.loopback_dns >/dev/null 2>&1; then
            echo "Adding loopback DNS interface..."
            uci set network.loopback_dns=interface
            uci set network.loopback_dns.proto='static'
            uci add_list network.loopback_dns.ipaddr='10.255.255.254/32'
            uci set network.loopback_dns.device='lo'
        fi
        
        # Add DNS redirect rule for main network (lan) - redirect to loopback DNS
        if ! uci get firewall.lan_dns_redirect >/dev/null 2>&1; then
            echo "Adding DNS redirect rule for main network..."
            uci set firewall.lan_dns_redirect=redirect
            uci set firewall.lan_dns_redirect.name='LAN DNS Redirect'
            uci set firewall.lan_dns_redirect.src='lan'
            uci set firewall.lan_dns_redirect.proto='tcp udp'
            uci set firewall.lan_dns_redirect.src_dport='53'
            uci set firewall.lan_dns_redirect.dest_ip='10.255.255.254'
            uci set firewall.lan_dns_redirect.dest_port='53'
            uci set firewall.lan_dns_redirect.target='DNAT'
        fi
        
        # Add policy routing rule for main network LIBERTY addresses
        if ! uci get firewall.lan_liberty_route >/dev/null 2>&1; then
            echo "Adding policy routing rule for main network LIBERTY addresses..."
            uci set firewall.lan_liberty_route=rule
            uci set firewall.lan_liberty_route.name='LAN Liberty Route'
            uci set firewall.lan_liberty_route.src='lan'
            uci set firewall.lan_liberty_route.set_mark='0x65/0xff'
            uci set firewall.lan_liberty_route.target='MARK'
            uci set firewall.lan_liberty_route.chain='mangle_prerouting'
        fi
        
        # Add SSH access rule from WAN zone
        if ! uci get firewall.wan_ssh_access >/dev/null 2>&1; then
            echo "Adding SSH access rule from WAN zone..."
            uci set firewall.wan_ssh_access=rule
            uci set firewall.wan_ssh_access.name='WAN SSH Access'
            uci set firewall.wan_ssh_access.src='wan'
            uci set firewall.wan_ssh_access.dest_port='22'
            uci set firewall.wan_ssh_access.proto='tcp'
            uci set firewall.wan_ssh_access.target='ACCEPT'
        fi
        
        # Add web management access rule from WAN zone
        if ! uci get firewall.wan_web_access >/dev/null 2>&1; then
            echo "Adding web management access rule from WAN zone..."
            uci set firewall.wan_web_access=rule
            uci set firewall.wan_web_access.name='WAN Web Access'
            uci set firewall.wan_web_access.src='wan'
            uci set firewall.wan_web_access.dest_port='80 443'
            uci set firewall.wan_web_access.proto='tcp'
            uci set firewall.wan_web_access.target='ACCEPT'
        fi
        
        # Add ping access rule from WAN zone
        if ! uci get firewall.wan_ping_access >/dev/null 2>&1; then
            echo "Adding ping access rule from WAN zone..."
            uci set firewall.wan_ping_access=rule
            uci set firewall.wan_ping_access.name='WAN Ping Access'
            uci set firewall.wan_ping_access.src='wan'
            uci set firewall.wan_ping_access.proto='icmp'
            uci set firewall.wan_ping_access.icmp_type='echo-request'
            uci set firewall.wan_ping_access.target='ACCEPT'
        fi
        
        # Commit network and firewall changes
        echo "Committing network changes..."
        uci commit network
        uci commit firewall
        
        # Configure loopback DNS IP immediately
        echo "Configuring loopback DNS interface..."
        if ! ip addr show lo | grep -q "10.255.255.254/32"; then
            ip addr add 10.255.255.254/32 dev lo
            echo "Loopback DNS IP 10.255.255.254/32 added to lo interface"
        else
            echo "Loopback DNS IP already configured"
        fi
        
        # Ensure LIBERTY_ADDRESS_GRP ipset is created immediately
        echo "Ensuring LIBERTY_ADDRESS_GRP ipset is active..."
        if ! ipset list LIBERTY_ADDRESS_GRP >/dev/null 2>&1; then
            ipset create LIBERTY_ADDRESS_GRP hash:ip family inet
            ipset add LIBERTY_ADDRESS_GRP 8.8.8.8
            ipset add LIBERTY_ADDRESS_GRP 8.8.4.4
            echo "LIBERTY_ADDRESS_GRP ipset created and populated"
        else
            echo "LIBERTY_ADDRESS_GRP ipset already exists"
        fi
        
        # Add IP rules for marked packets to use routing table 100
        echo "Adding IP rules for policy routing..."
        
        # Rule for guest network (br-guest) - mark 0x64
        if ! ip rule show | grep -q "fwmark 0x64/0xff lookup 100"; then
            ip rule add fwmark 0x64/0xff table 100 priority 100
            echo "IP rule added: fwmark 0x64/0xff table 100 priority 100"
        else
            echo "IP rule already exists for guest network (table 100)"
        fi
        
        # Rule for LAN network (br-lan) LIBERTY addresses - mark 0x65
        if ! ip rule show | grep -q "fwmark 0x65/0xff lookup 100"; then
            ip rule add fwmark 0x65/0xff table 100 priority 101
            echo "IP rule added: fwmark 0x65/0xff table 100 priority 101"
        else
            echo "IP rule already exists for LAN LIBERTY addresses (table 100)"
        fi
        
        # Add iptables rule for guest network policy routing
        echo "Adding iptables rule for guest network policy routing..."
        if ! iptables -t mangle -C PREROUTING -i br-guest -j MARK --set-mark 0x64/0xff 2>/dev/null; then
            iptables -t mangle -I PREROUTING -i br-guest -j MARK --set-mark 0x64/0xff
            echo "iptables rule added for guest network policy routing"
        else
            echo "iptables rule already exists for guest network policy routing"
        fi
        
        # Add iptables rule for LAN LIBERTY_ADDRESS_GRP matching
        echo "Adding iptables rule for LAN LIBERTY address matching..."
        if ! iptables -t mangle -C PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff 2>/dev/null; then
            iptables -t mangle -I PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff
            echo "iptables rule added for LAN LIBERTY address matching"
        else
            echo "iptables rule already exists for LAN LIBERTY address matching"
        fi
        
        # Add static routes for policy routing
        echo "Configuring routing tables..."
        
        # Add static route for 8.8.8.8 via wg251 in main table
        if ! ip route show | grep -q "8.8.8.8 dev wg251"; then
            ip route add 8.8.8.8 dev wg251
            echo "Static route added: 8.8.8.8 via wg251"
        else
            echo "Static route already exists: 8.8.8.8 via wg251"
        fi
        
        # Add default route in table 100 via wg251
        if ! ip route show table 100 | grep -q "default dev wg251"; then
            ip route add default dev wg251 table 100
            echo "Default route added in table 100: default via wg251"
        else
            echo "Default route already exists in table 100 via wg251"
        fi
        
        # Make IP rules and iptables rules persistent by adding to a startup script
        if [ ! -f "/etc/init.d/gfw" ]; then
            echo "Creating custom routing startup script..."
            cat > /etc/init.d/gfw << 'EOF'
#!/bin/sh /etc/rc.common

START=99

start() {
    # Ensure LIBERTY_ADDRESS_GRP ipset exists
    if ! ipset list LIBERTY_ADDRESS_GRP >/dev/null 2>&1; then
        ipset create LIBERTY_ADDRESS_GRP hash:ip family inet
        ipset add LIBERTY_ADDRESS_GRP 8.8.8.8
        ipset add LIBERTY_ADDRESS_GRP 8.8.4.4
    fi
    
    # Ensure loopback DNS IP is configured
    if ! ip addr show lo | grep -q "10.255.255.254/32"; then
        ip addr add 10.255.255.254/32 dev lo
    fi
    
    # Add IP rule for global network policy routing
    if ! ip rule show | grep -q "fwmark 0x64/0xff lookup 100"; then
        ip rule add fwmark 0x64/0xff table 100 priority 100
    fi
    
    # Add IP rule for LAN LIBERTY addresses policy routing
    if ! ip rule show | grep -q "fwmark 0x65/0xff lookup 100"; then
        ip rule add fwmark 0x65/0xff table 100 priority 101
    fi
    
    # Add iptables rule for guest network policy routing
    if ! iptables -t mangle -C PREROUTING -i br-guest -j MARK --set-mark 0x64/0xff 2>/dev/null; then
        iptables -t mangle -I PREROUTING -i br-guest -j MARK --set-mark 0x64/0xff
    fi
    
    # Add iptables rule for LAN LIBERTY_ADDRESS_GRP matching
    if ! iptables -t mangle -C PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff 2>/dev/null; then
        iptables -t mangle -I PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff
    fi
    
    # Add static routes for policy routing
    # Static route for 8.8.8.8 via wg251 in main table
    if ! ip route show | grep -q "8.8.8.8 dev wg251"; then
        ip route add 8.8.8.8 dev wg251
    fi
    
    # Default route in table 100 via wg251
    if ! ip route show table 100 | grep -q "default dev wg251"; then
        ip route add default dev wg251 table 100
    fi
}

stop() {
    # Remove iptables rule for guest network policy routing
    if iptables -t mangle -C PREROUTING -i br-guest -j MARK --set-mark 0x64/0xff 2>/dev/null; then
        iptables -t mangle -D PREROUTING -i br-guest -j MARK --set-mark 0x64/0xff
    fi
    
    # Remove iptables rule for LAN LIBERTY_ADDRESS_GRP matching
    if iptables -t mangle -C PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff 2>/dev/null; then
        iptables -t mangle -D PREROUTING -i br-lan -m set --match-set LIBERTY_ADDRESS_GRP dst -j MARK --set-mark 0x65/0xff
    fi
    
    # Remove loopback DNS IP
    if ip addr show lo | grep -q "10.255.255.254/32"; then
        ip addr del 10.255.255.254/32 dev lo
    fi
    
    # Remove IP rule for global network policy routing
    if ip rule show | grep -q "fwmark 0x64/0xff lookup 100"; then
        ip rule del fwmark 0x64/0xff table 100
    fi
    
    # Remove IP rule for LAN LIBERTY addresses policy routing
    if ip rule show | grep -q "fwmark 0x65/0xff lookup 100"; then
        ip rule del fwmark 0x65/0xff table 100
    fi
    
    # Remove static routes
    # Remove static route for 8.8.8.8 via wg251
    if ip route show | grep -q "8.8.8.8 dev wg251"; then
        ip route del 8.8.8.8 dev wg251
    fi
    
    # Remove default route in table 100
    if ip route show table 100 | grep -q "default dev wg251"; then
        ip route del default dev wg251 table 100
    fi
    
    # Remove LIBERTY_ADDRESS_GRP ipset (optional - comment out if you want to keep it)
    # if ipset list LIBERTY_ADDRESS_GRP >/dev/null 2>&1; then
    #     ipset destroy LIBERTY_ADDRESS_GRP
    # fi
}
EOF
            chmod +x /etc/init.d/gfw
            /etc/init.d/gfw enable
            echo "Gfw startup script created and enabled"
        fi
        
        echo "Network configuration completed successfully."
        SUMMARY="${SUMMARY}  ✓ Network routing configured (guest and LAN networks with policy routing, guest zone access, and WAN management access)\n"
    else
        echo "Network routing already configured for guest, LAN, and WAN access."
    fi

    # Configure WireGuard interfaces if needed
    if [ "$RECONFIGURE_WG" = "true" ]; then
        echo "Configuring WireGuard interfaces..."

        # Configure wg251 interface
        configure_wg_interface "wg251" "251" "$WG_PRIVATE_KEY" "zu9+zqHtZvuIZ+VE5DxqWgdiJxiDL8gTzmaYZ4O9sno=" "sdw1.creekside.network" "52800"

        # Configure wg252 interface
        configure_wg_interface "wg252" "252" "$WG_PRIVATE_KEY" "ypX70YJDR45YZhUdCdAem3uo5SAf5U4/rkFGVMZBzz8=" "sdw2.creekside.network" "500"

        # Configure wg253 interface  
        configure_wg_interface "wg253" "253" "$WG_PRIVATE_KEY" "uLuDu5RyGyi3/Uxpd69RaNCGtP5Z80e2mMAxIgs/w3w=" "sdw3.creekside.network" "52800"

        echo "WireGuard interfaces configured."
        SUMMARY="${SUMMARY}  ✓ WireGuard VPN interfaces configured\n"

    else
        echo "Skipping WireGuard interface configuration as requested."
    fi

    # Show configuration summary
    log_message "=== OpenWrt GFW Setup Configuration completed successfully ==="
    echo
    echo "Configuration completed successfully!"
    echo "Summary of changes:"
    printf "$SUMMARY"
    
    if [ "$RECONFIGURE_WG" = "true" ]; then
        echo "WireGuard details:"
        echo "  - wg251: 10.251.255.$DEVICE_ID/24 -> sdw1.creekside.network:52800"
        echo "  - wg252: 10.252.255.$DEVICE_ID/24 -> sdw2.creekside.network:500"
        echo "  - wg253: 10.253.255.$DEVICE_ID/24 -> sdw3.creekside.network:52800"
    fi
    
    echo
    echo "Configuration changes require a system reboot to take effect."
    echo "The router will restart and you may need to reconnect to the new WiFi network."
    echo
    printf "Reboot now? (Y/n) - Will auto-reboot in 5 seconds if no response: "
    
    # Read user input with 5 second timeout
    if read -t 5 REBOOT_CHOICE; then
        case "$REBOOT_CHOICE" in
            [Nn]|[Nn][Oo])
                log_message "Reboot cancelled by user - manual reboot required"
                echo "Reboot cancelled. Please reboot manually when ready to activate changes."
                exit 0
                ;;
            *)
                log_message "System rebooting to activate changes"
                echo "Rebooting now..."
                reboot
                ;;
        esac
    else
        echo
        log_message "Auto-rebooting after timeout"
        echo "No response received. Rebooting automatically..."
        reboot
    fi

}

main "$@"