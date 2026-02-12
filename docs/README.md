# Xray Chain Proxy

> **Version 2.1.0**

A powerful chain proxy solution for bypassing internet censorship, built on [Xray-core](https://github.com/XTLS/Xray-core).

![Setup Edge](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/png/setup-edge.png)

## How It Works

```
┌────────────┐      ┌────────────┐      ┌────────────┐      ┌──────────┐
│   Client   │ ──── │    EDGE    │ ──── │  GATEWAY   │ ──── │ Internet │
│   (You)    │      │  (Entry)   │      │   (Exit)   │      │          │
└────────────┘      └────────────┘      └────────────┘      └──────────┘
```

| Server    | Location            | Role                                       |
| --------- | ------------------- | ------------------------------------------ |
| `EDGE`    | Restricted region   | Entry point - clients connect here         |
| `GATEWAY` | Unrestricted region | Exit point - fetches content from internet |

**Why two servers?**

Users in isolated networks cannot directly access many websites. This tool creates a chain:

1. Your device connects to the **EDGE** server (in your region)
2. EDGE forwards traffic to the **GATEWAY** server (unrestricted region)
3. GATEWAY fetches the content from the internet
4. Response travels back: Internet → GATEWAY → EDGE → Your device

**Benefits:**

- EDGE server has low latency (it's close to you)
- GATEWAY server has unrestricted internet access
- Traffic between EDGE and GATEWAY is encrypted
- If EDGE gets blocked, you can easily replace it

## Supported Protocols

| Protocol    | Port | Method/Auth   | Best For                        |
| ----------- | ---- | ------------- | ------------------------------- |
| Shadowsocks | 443  | `aes-256-gcm` | Mobile apps, best compatibility |
| HTTP        | 80   | Basic auth    | Browser extensions, curl        |
| SOCKS5      | 1080 | Basic auth    | Applications, system-wide proxy |

> All protocols share the same username and password.

## Features

- **Multi-protocol support** - Shadowsocks, HTTP, and SOCKS5 on same server
- **Chain architecture** - Multiple hops for reliability and privacy
- **Strong encryption** - AES-256-GCM for Shadowsocks connections
- **User management** - Unlimited accounts with QR codes
- **Traffic statistics** - Monitor bandwidth per user
- **Simple CLI** - Docker-style commands

## Prerequisites

**Server requirements:**

- Debian/Ubuntu with root access
- Minimum 512MB RAM, 1 CPU

See [Providers](providers.md) for VPS recommendations.

## Installation

### 1. Download

Run on **both** GATEWAY and EDGE servers:

```bash
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh
```

### 2. Setup Gateway

On your exit server (unrestricted internet):

```bash
./xcp.sh setup gateway
```

You'll configure:

- Shadowsocks port (default: 443)
- HTTP port (default: 80)
- SOCKS5 port (default: 1080)

Save the output credentials:

```
GATEWAY Ready!

Use on EDGE server:
  IP:         1.2.3.4
  SS Port:    443
  Password:   xxxxxxxxxxxxxxxx
```

### 3. Setup Edge

On your entry server:

```bash
./xcp.sh setup edge
```

Enter the GATEWAY credentials when prompted:

- Gateway IP
- Gateway port (443)
- Gateway password

## Connect Clients

### Shadowsocks

Use any Shadowsocks client:

| Setting  | Value         |
| -------- | ------------- |
| Server   | EDGE IP       |
| Port     | 443           |
| Password | (from setup)  |
| Method   | `aes-256-gcm` |

See [Clients](clients.md) for recommended apps.

### HTTP Proxy

```
http://username:password@EDGE_IP:80
```

### SOCKS5 Proxy

```
socks5://username:password@EDGE_IP:1080
```

## Verify

Test the connection on EDGE server:

```bash
./xcp.sh test
```

Shows exit IP (should be GATEWAY's IP) and runs speed test.

## Common Commands

```bash
./xcp.sh start          # Start service
./xcp.sh stop           # Stop service
./xcp.sh status         # Show status
./xcp.sh user ls        # List users
./xcp.sh user add       # Add user
./xcp.sh stats          # Traffic statistics
./xcp.sh update         # Update Xray
```

For full documentation see [Commands](commands.md).

## Links

- [Xray-core Documentation](https://xtls.github.io/en/)
- [Project Repository](https://github.com/dalirnet/xray-chain-proxy)
- [Report Issues](https://github.com/dalirnet/xray-chain-proxy/issues)
