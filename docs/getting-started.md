# Getting Started

## Requirements

- Debian/Ubuntu servers with root access
- GATEWAY server with unrestricted internet
- EDGE server accessible to clients

## Install

```bash
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh
```

## Setup Gateway

```bash
./xcp.sh setup gateway
```

Save the output credentials for EDGE setup.

## Setup Edge

```bash
./xcp.sh setup edge
```

Enter GATEWAY IP, port (443), and password when prompted.

## Connect

Use any protocol with EDGE server credentials:

| Protocol    | Port | Config                                    |
| ----------- | ---- | ----------------------------------------- |
| Shadowsocks | 443  | Method: `aes-256-gcm`                     |
| HTTP        | 80   | `http://user:pass@EDGE_IP:80`             |
| SOCKS5      | 1080 | `socks5://user:pass@EDGE_IP:1080`         |

## Verify

```bash
./xcp.sh test
```

## Multi-EDGE

**Parallel** - Multiple EDGEs to same GATEWAY:
```
EDGE 1 --\
          --> GATEWAY --> Internet
EDGE 2 --/
```

**Chained** - Extra privacy with multiple hops:
```
Client --> EDGE 1 --> EDGE 2 --> GATEWAY --> Internet
```

For chained setup, configure EDGE 1 to point to EDGE 2 instead of GATEWAY.
