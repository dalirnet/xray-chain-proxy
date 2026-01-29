# Xray Chain Proxy

> Chain proxy for bypassing internet censorship

```
Client --> EDGE --> GATEWAY --> Internet
```

| Server    | Role                                         |
| --------- | -------------------------------------------- |
| `GATEWAY` | Exit node with unrestricted internet         |
| `EDGE`    | Entry node clients connect to                |

## Features

- **Multi-Protocol** - Shadowsocks (443), HTTP (80), SOCKS5 (1080)
- **Chain Architecture** - Multiple hops for privacy
- **User Management** - Add/remove users with QR codes
- **Traffic Stats** - Monitor bandwidth per user

## Quick Start

```bash
# Download
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh

# On exit server
./xcp.sh setup gateway

# On entry server  
./xcp.sh setup edge
```

## Commands

```
setup gateway|edge    Setup server
start|stop|restart    Control service
status                Show status
user ls|add|rm        Manage users
stats                 Traffic statistics
logs [-f] [n]         View logs
test                  Test connection
config ls|set         Configuration
update                Update Xray
uninstall             Remove Xray
```
