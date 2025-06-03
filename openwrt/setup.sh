#!/bin/bash
# (c) 2022-2024 Creekside Networks LLC, Jackson Tong
# This script will prepare for the gfw jailbreak. Need to run one time after reboot.
# for Openwrt

# --- Configuration ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="${ROOT_DIR}/openwrt"
KEY_FILE="$ROOT_DIR/sdw-keys.txt"
SDWCONF_DIR="${ROOT_DIR}/openwrt/conf/wireguard"
SSH_OPTIONS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
GFW_DIR="/etc/config/gfw"

# Constants
PUBLIC_KEY_1=
ENDPOINT_1=

PUBLIC_KEY_2=""
ENDPOINT_2=""

# --- Check sshpass ---
if ! command -v sshpass >/dev/null 2>&1; then
  echo "Error: sshpass is required but not installed. Please install sshpass."
  exit 1
fi

# --- Prompt for Site ID ---
while true; do
  read -p "Enter site ID (1-249): " site_id
  if [[ "$site_id" =~ ^[0-9]+$ ]] && [ "$site_id" -ge 1 ] && [ "$site_id" -le 249 ]; then
    break
  else
    echo "Invalid site ID. Please enter a number between 1 and 249."
  fi
done

# --- Prompt for Router IP ---
read -p "Enter OpenWRT router IP [192.168.8.1]: " router_ip
router_ip="${router_ip:-192.168.8.1}"

if ! [[ "$router_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Error: $router_ip is not a valid IPv4 address."
  exit 1
fi

# --- Prompt for Username ---
read -p "Enter OpenWRT username [root]: " router_user
router_user="${router_user:-root}"

# --- Prompt for Password ---
read -s -p "Enter password for $router_user@$router_ip: " router_pass
echo

# --- Key lookup ---
if [ ! -f "$KEY_FILE" ]; then
  echo "Error: Key file not found: $KEY_FILE"
  exit 1
fi

PRIVATE_KEY=$(grep -E "^\"$site_id\"" "$KEY_FILE" | sed -E 's/^"[0-9]+": *"([^"]+)",?/\1/')

if [ -z "$PRIVATE_KEY" ]; then
  echo "Error: No key found for site ID $site_id."
  exit 1
fi


# --- SCP entire ../openwrt folder contents to /etc/config/gfw/ on router ---
if [ ! -d "$OPENWRT_DIR" ]; then
  echo "Error: Directory $OPENWRT_DIR does not exist."
  exit 1
fi




# --- IP Address Assignment ---
ADDRESS_1="10.252.255.$site_id/24"
ADDRESS_2="10.253.255.$site_id/24"

WG252_CONF_FILE="$SDWCONF_DIR/wg252.conf"
WG253_CONF_FILE="$SDWCONF_DIR/wg253.conf"


# --- Generate wg252.conf ---
cat > "$WG252_CONF_FILE" <<EOF
[Interface]
Address    = 10.252.255.$site_id/24
PrivateKey = $PRIVATE_KEY

[Peer]
PublicKey  = ypX70YJDR45YZhUdCdAem3uo5SAf5U4/rkFGVMZBzz8=
AllowedIPs = 0.0.0.0/0
Endpoint   = sdw2.creekside.network:500
PersistentKeepalive = 25
EOF

# --- Generate wg253.conf ---
cat > "$WG253_CONF_FILE" <<EOF
[Interface]
Address    = 10.253.255.$site_id/24
PrivateKey = $PRIVATE_KEY

[Peer]
PublicKey  = uLuDu5RyGyi3/Uxpd69RaNCGtP5Z80e2mMAxIgs/w3w=
AllowedIPs = 0.0.0.0/0
Endpoint   = sdw3.creekside.network:52800
PersistentKeepalive = 25
EOF

# --- Show results ---
echo "WireGuard config files created in: $SDWCONF_DIR"
echo
cat "$WG252_CONF_FILE"
echo
cat "$WG253_CONF_FILE"
echo


echo "Uploading contents of $OPENWRT_DIR to $router_ip:$GFW_DIR ..."
sshpass -p "$router_pass" ssh $SSH_OPTIONS "$router_user@$router_ip" "mkdir -p $GFW_DIR"
if [ $? -ne 0 ]; then
  echo "Error: Failed to create target directory $GFW_DIR on router."
  exit 1
fi

sshpass -p "$router_pass" scp $SSH_OPTIONS -r -O "$OPENWRT_DIR"/* "$router_user@$router_ip:$GFW_DIR/"
if [ $? -ne 0 ]; then
  echo "Error: Failed to upload openwrt directory contents."
  exit 1
fi

echo "Files uploaded successfully!"

echo "First run of gfw-startup scripts"

sshpass -p "$router_pass" ssh $SSH_OPTIONS "$router_user@$router_ip" "/etc/config/gfw/gfw-startup.sh"

echo "All finished"