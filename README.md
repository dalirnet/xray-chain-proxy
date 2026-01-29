# Xray Chain Proxy

Enabling free internet access for people in countries isolated from the global internet, like **Iran** 😢

- ⚡ Built on Xray-core
- ⛓️ Chain proxy architecture with two servers
- 🔒 Multiple protocols: Shadowsocks, HTTP, SOCKS5
- 🌍 Reliable connectivity and freedom of information

```
Client ────► EDGE ────► GATEWAY ────► Internet
```

- **GATEWAY**: Exit node with unrestricted internet access
- **EDGE**: Entry node that forwards traffic to GATEWAY (or another EDGE)

### Multi-EDGE Architectures

**Parallel** - Multiple entry points:

```
Client A ───► EDGE 1 ───┐
                        ├───► GATEWAY ───► Internet
Client B ───► EDGE 2 ───┘
```

**Chained** - Extra hops for privacy:

```
Client ───► EDGE 1 ───► EDGE 2 ───► GATEWAY ───► Internet
```

EDGEs can connect to other EDGEs, not just GATEWAY. Configure each EDGE to point to the next hop in the chain.

---

## Prerequisites

- One GATEWAY server with unrestricted internet access
- One or more EDGE servers accessible to clients
- All servers running Debian/Ubuntu with root access

> Tested on Ubuntu 22.04.5 LTS. Other versions may work but might require adjustments.

---

## 🚀 Quick Start

### 1. Download

Run on both servers:

```bash
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh
```

### 2. Setup Gateway

On your exit server:

```bash
./xcp.sh setup gateway
```

### 3. Setup Edge(s)

On each entry server (can setup multiple):

```bash
./xcp.sh setup edge
```

Use the same GATEWAY credentials for all EDGE servers.

An initial `edge` user is created automatically on each server.

---

## Protocols & Ports

| Protocol    | Default Port | Description                        |
| ----------- | ------------ | ---------------------------------- |
| Shadowsocks | 443          | Encrypted proxy (looks like HTTPS) |
| HTTP        | 80           | Standard HTTP proxy                |
| SOCKS5      | 1080         | Standard SOCKS5 proxy              |

All protocols share the same username/password authentication.

---

## Commands

### Setup

| Command         | Description                          |
| --------------- | ------------------------------------ |
| `setup gateway` | Install and configure gateway server |
| `setup edge`    | Install and configure edge server    |

### Service

| Command   | Description                          |
| --------- | ------------------------------------ |
| `start`   | Start Xray service                   |
| `stop`    | Stop Xray service                    |
| `restart` | Restart Xray service                 |
| `status`  | Show Xray service status and version |

### Users

| Command    | Description                            |
| ---------- | -------------------------------------- |
| `user ls`  | List all users with passwords and URIs |
| `user add` | Add new user with QR code              |
| `user rm`  | Remove existing user                   |

### Monitoring

| Command         | Description                                 |
| --------------- | ------------------------------------------- |
| `stats`         | Show traffic statistics per user            |
| `logs [-f] [n]` | View last n logs, -f to follow in real-time |
| `test`          | Test proxy connection and run speed test    |

### Configuration

| Command      | Description                         |
| ------------ | ----------------------------------- |
| `config ls`  | Show current configuration          |
| `config set` | Set configuration (log level, port) |

### Maintenance

| Command     | Description                       |
| ----------- | --------------------------------- |
| `update`    | Update Xray to latest version     |
| `uninstall` | Remove Xray and all configuration |

---

## Files

| File   | Path                          |
| ------ | ----------------------------- |
| Binary | `/usr/local/xray/xray`        |
| Config | `/usr/local/xray/config.json` |
| Logs   | `/var/log/xray/`              |
| Cache  | `/tmp/xray-cache/`            |

---

## Dependencies

**Required:** `curl` `unzip` `jq`
**Optional:** `qrencode` (QR codes) `speedtest-cli` (speed test)

---

## Links

- [Xray-core](https://github.com/XTLS/Xray-core)

## License

MIT
