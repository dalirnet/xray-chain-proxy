# Getting Started

## Prerequisites

You need **two servers**:

| Server    | Location            | Role                                 |
| --------- | ------------------- | ------------------------------------ |
| `EDGE`    | Restricted region   | Entry point that clients connect to  |
| `GATEWAY` | Unrestricted region | Exit point with free internet access |

**Why two servers?**

Users in isolated networks cannot directly access many websites. This tool creates a chain:

1. Your device connects to the **EDGE** server (in your region)
2. EDGE forwards traffic to the **GATEWAY** server (unrestricted region)
3. GATEWAY fetches the content from the internet
4. Response travels back: Internet → GATEWAY → EDGE → Your device

```
[Restricted]                [Unrestricted]
You --> EDGE server    -->  GATEWAY server  -->  Internet
        (local DC)          (free region)        (blocked sites)
```

**Benefits of this setup:**

- EDGE server has low latency (it's close to you)
- GATEWAY server has unrestricted internet access
- Traffic between EDGE and GATEWAY is encrypted
- If EDGE gets blocked, you can easily replace it

**Server requirements:**

- Debian/Ubuntu with root access
- Minimum 512MB RAM, 1 CPU

See [Providers](providers.md) for VPS recommendations.

## Download

Run on both GATEWAY and EDGE servers:

```bash
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh
```

## Setup Gateway

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

## Setup Edge

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
