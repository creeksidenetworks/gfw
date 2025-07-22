#!/usr/bin/env bash
# (c) 2025 Creekside Networks LLC, Jackson Tong
# This script will update sdwan wireguard peer settings

SDWAN_CONF_ROOT="/opt/gfw/sdwan/conf"
SDWAN_PEERS_CONF="$SDWAN_CONF_ROOT/sdw-peers.conf"
SDWAN_PRIVATE_KEY="$SDWAN_CONF_ROOT/sdw-private.key"
SDWAN_ID_CONF="$SDWAN_CONF_ROOT/sdw-id.conf"

LOG_FILE=/var/log/gfw.log

function MyLogger() {
    TS=$(date +"%Y-%m-%d %T")
    echo "$TS [$2] $3" | sudo tee -a $LOG_FILE
}

if [[ ! -f $SDWAN_ID_CONF ]]; then
    MyLogger "err" "sdwan" "Missing sdwan id config file: [$SDWAN_ID_CONF]"
    exit 1
fi

if [[ ! -f $SDWAN_PEERS_CONF ]]; then
    MyLogger "err" "sdwan" "Missing sdwan peers config file: [$SDWAN_PEERS_CONF]"
    exit 1
fi

if [[ ! -f $SDWAN_PRIVATE_KEY ]]; then
    MyLogger "err" "sdwan" "Missing sdwan private key file: [$SDWAN_PRIVATE_KEY]"
    exit 1
fi  

MY_ID=$(cat $SDWAN_ID_CONF | tr -d '[:space:]') # remove spaces
if [ $MY_ID -gt 254 ] || [ $MY_ID -lt 251 ]; then
    MyLogger "err" "sdwan" "Erro sdwan server id in config file: [$SDWAN_ID_CONF]"
    exit 1
else
    MyLogger "info" "sdwan" "sdwan server id: [$MY_ID]"
fi 

MY_KEY=$(cat $SDWAN_PRIVATE_KEY | tr -d '[:space:]')
if ! [[ "$MY_KEY" =~ ^[A-Za-z0-9+/=]{44}$ ]]; then
    MyLogger "err" "sdwan" "Invalid WireGuard private key in file: [$SDWAN_PRIVATE_KEY]"
    exit 1
else
    MyLogger "info" "sdwan" "Successfully read and validated private key from [$SDWAN_PRIVATE_KEY]"
fi

# Bring up the wireguard interface
sudo ip link add dev wg${MY_ID} type wireguard
sudo ip addr add 10.${MY_ID}.255.254/24 dev wg${MY_ID}
sudo ip link set up dev wg${MY_ID}
sudo wg set wg${MY_ID} private-key $SDWAN_PRIVATE_KEY listen-port 52800

MyLogger "info" "sdwan" "Bringup wireguard interface wg${MY_ID}"

MyLogger "info" "sdwan" "Bringup wireguard peers of [$MY_ID]"

while  read -r line || [[ -n $line ]]; do
    # remove comments
    stripped="${line%%\/\**}"                   # remove comments
    stripped="${stripped##*([[:space:]])}"      # remove leading spaces
    if [[ $stripped == "" ]]; then continue; fi # advanced to next line if empty

    PEER_ID=$(echo $stripped | cut -d " " -f 1)
    PEER_PUBKEY=$(echo $stripped | cut -d " " -f 2)

    MyLogger "info" "sdwan" "$PEER_ID $PEER_PUBKEY"
    sudo wg set wg${MY_ID} peer $PEER_PUBKEY allowed-ips "10.$MY_ID.255.$PEER_ID"

done < <(cat $SDWAN_PEERS_CONF)
        
MyLogger "info" "sdwan" "sdwan[$MY_ID] is up and running with peers configured."
