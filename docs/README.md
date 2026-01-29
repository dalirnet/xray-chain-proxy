# Xray Chain Proxy

> **Version 2.0.0** | [Changelog](changelog.md)

Chain proxy for bypassing internet censorship, built on [Xray-core](https://github.com/XTLS/Xray-core).

## Architecture

```
Client --> EDGE --> GATEWAY --> Internet
```

| Server    | Role                                 |
| --------- | ------------------------------------ |
| `GATEWAY` | Exit node with unrestricted internet |
| `EDGE`    | Entry node, forwards to GATEWAY      |

## Features

- Multi-protocol: Shadowsocks, HTTP, SOCKS5
- Chain architecture with multiple hops
- User management with QR codes
- Traffic statistics per user
- Auto-update support

## Protocols & Ports

| Protocol    | Port | Description                   |
| ----------- | ---- | ----------------------------- |
| Shadowsocks | 443  | Encrypted, looks like HTTPS   |
| HTTP        | 80   | Standard HTTP proxy           |
| SOCKS5      | 1080 | General purpose, supports UDP |

All protocols share the same username/password.

## Requirements

- Debian/Ubuntu with root access
- GATEWAY server with unrestricted internet
- EDGE server accessible to clients

## Files

| File   | Path                          |
| ------ | ----------------------------- |
| Binary | `/usr/local/xray/xray`        |
| Config | `/usr/local/xray/config.json` |
| Logs   | `/var/log/xray/`              |
| Cache  | `/tmp/xray-cache/`            |

## Dependencies

**Required:** `curl` `unzip` `jq`

**Optional:** `qrencode` (QR codes), `speedtest-cli` (speed test)
