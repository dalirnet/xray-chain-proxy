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

## Gateway Setup

Run on your exit server (the one that connects to internet):

```bash
./xcp.sh install gateway
```

An initial `edge` account is created automatically.

## Edge Setup

Run on your entry server (the one clients connect to):

```bash
./xcp.sh install edge
```

An initial `edge` account is created automatically.

## Commands

| Command           | Description                |
| ----------------- | -------------------------- |
| `install gateway` | Setup gateway              |
| `install edge`    | Setup edge                 |
| `account list`    | List accounts              |
| `account add`     | Add account                |
| `account remove`  | Remove account             |
| `status`          | Show status                |
| `stats`           | Traffic stats              |
| `logs`            | View logs                  |
| `test`            | Test proxy                 |
| `update`          | Update Xray                |
| `config loglevel` | Set log level              |
| `config port`     | Change port                |
| `uninstall`       | Remove Xray                |

## Files

| File   | Path                          |
| ------ | ----------------------------- |
| Binary | `/usr/local/xray/xray`        |
| Config | `/usr/local/xray/config.json` |
| Logs   | `/var/log/xray/`              |

## Links

- [Xray-core](https://github.com/XTLS/Xray-core)
