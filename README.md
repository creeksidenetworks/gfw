# Linux Router
This collection support following features:

* Great firewall jailbreak
* iPXE boot for Edgerouter 

Supported platforms:

* EdgeRouter 3.0
* VyOS 1.3.4
* Openwrt (Gl-inet SFT1200/MT3000 tested)

## GFW Jailbreak
This feature will use wireguard VPN as the encrypted tunnel. Up to three remote servers are supported, primary/secondary and backup server.

### gfw_startup.sh
This scripts will setup the wiregaurd tunnels, launch a dnsmasq instance listening on port 55353/udp, apple iptables rules to route sepecific traffics to VPN tunnel.

#### How to use
gfw_startup.sh -s <smart interface> -g <global interface>

* Smart interface

    Split traffic, domestic bound traffic will be forwarded to default route; restricted domains bound traffic will be forwarded to vpn tunnel


### Data
IP sets:
* LIBERTY_ADDRESS_GRP

    All dnsmasq resolved IPv4 address specified in conf/dnsmasq_gfw_github.conf and conf/dnsmasq_gfw_custom.conf will be stored in this ipset
* NETS_GLOBAL / ADDR_GLOBAL

    Any subnet in this ipset will be forwarded to remote servers.

DNSMASQ configuration files

