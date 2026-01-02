# Xray Chain Proxy

Enabling free internet access for people in countries isolated from the global internet, like Iran. Built on Xray-core, it uses a chain proxy architecture with two servers: EDGE (entry node) forwards traffic to GATEWAY (exit node), providing reliable connectivity and freedom of information. Uses Shadowsocks protocol for secure, encrypted communication.

```
Client --> EDGE --> GATEWAY --> Internet
```

## Prerequisites

- Two Debian/Ubuntu servers with root access
- GATEWAY: Exit server with unrestricted internet access
- EDGE: Entry server accessible to clients

> Tested on Ubuntu 22.04.5 LTS. Other Ubuntu/Debian versions may work but might require adjustments. Other distros require manual handling of install commands.

## Install

```bash
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh
```

## Setup

On your **gateway** server (exit node):

```bash
./xcp.sh setup gateway
```

On your **edge** server (entry node):

```bash
./xcp.sh setup edge
```

An initial `edge` user is created automatically on both servers.

## Commands

| Command         | Description                                 |
| --------------- | ------------------------------------------- |
| `setup gateway` | Install and configure gateway server        |
| `setup edge`    | Install and configure edge server           |
| `start`         | Start Xray service                          |
| `stop`          | Stop Xray service                           |
| `restart`       | Restart Xray service                        |
| `status`        | Show Xray service status and version        |
| `user ls`       | List all users with passwords and URIs      |
| `user add`      | Add new user with QR code                   |
| `user rm`       | Remove existing user                        |
| `stats`         | Show traffic statistics per user            |
| `logs [-f] [n]` | View last n logs, -f to follow in real-time |
| `test`          | Test proxy connection and run speed test    |
| `config ls`     | Show current configuration                  |
| `config set`    | Set configuration (log level, port)         |
| `update`        | Update Xray to latest version               |
| `uninstall`     | Remove Xray and all configuration           |

## Files

| File   | Path                          |
| ------ | ----------------------------- |
| Binary | `/usr/local/xray/xray`        |
| Config | `/usr/local/xray/config.json` |
| Logs   | `/var/log/xray/`              |

## Dependencies

**Required:** curl, unzip, jq
**Optional:** qrencode (QR codes), speedtest-cli (speed test)

## Links

- [Xray-core](https://github.com/XTLS/Xray-core)
