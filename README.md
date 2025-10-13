# GFW jailbreak
This project supports router based gfw jailbreak

Supported router platforms:

* EdgeRouter 3.0
* VyOS 1.3.4
* Openwrt (Gl-inet SFT1200/MT3000 tested)

## GFW Jailbreak
This feature will use wireguard VPN as the encrypted tunnel. Up to three remote servers are supported, primary/secondary and backup server.

## Directory structure
```
gfw

├── dnsmasq
│   ├── dnsmasq_gfw_custom.conf
│   └── dnsmasq_gfw_github.conf
├── README.md
├── router
│   ├── bin
│   │   ├── gfw_peer_update.sh
│   │   ├── update_dnsmasq_rulesets.sh
│   │   └── wg_peer_update.sh
│   ├── conf
│   │   ├── dnsmasq_gfw_custom.conf
│   │   └── dnsmasq_gfw_github.conf
│   └── setup
│       └── glinet_setup.sh
└── server
    ├── azure
    │   └── azure-update-pip.ps1
    ├── bin
    │   └── sdwan-up.sh
    └── conf
        ├── sdw-keys.txt
        └── sdw-peers.conf
```

