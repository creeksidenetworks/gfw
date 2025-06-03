# gfw_openwrt

Scripts for GFW jailbreak on openwrt platform

Please upload the files to /etc/config/gfw/ and execute the following scripts one time

/etc/config/gfw/gfw-startup.sh

it will automatically update the /etc/rc.local and /etc/crontabs/root. 

Prerequisitis:

 - Prepare two wireguard vpn configurations. The wireguard configuration file is a simplified format as below:
	
    Address = `<your-ip>`/`<cidr>`  
    PrivateKey = `<`your-private-key`>`  
    PublicKey = `<`peer-server-public-key`>`  
    AllowedIPs = 0.0.0.0/0  
    Endpoint = `<`server-fqdn`>`:`<`server-port`>`  
    PersistentKeepalive = 25  

