# Xray Chain Proxy

Chain proxy for bypassing internet censorship, built on [Xray-core](https://github.com/XTLS/Xray-core).

```
Client --> EDGE --> GATEWAY --> Internet
```

| Server    | Role                                 |
| --------- | ------------------------------------ |
| `GATEWAY` | Exit node with unrestricted internet |
| `EDGE`    | Entry node, forwards to GATEWAY      |

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

## Protocols

| Protocol    | Port | Method        |
| ----------- | ---- | ------------- |
| Shadowsocks | 443  | `aes-256-gcm` |
| HTTP        | 80   | Basic auth    |
| SOCKS5      | 1080 | Basic auth    |

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
rule ls|add|rm        Manage routing rules
update                Update Xray
uninstall             Remove Xray
```

## Development

Run tests without root access or Xray installation:

```bash
make test            # Run all tests
make check-deps      # Verify dependencies
make lint            # Check syntax
make version         # Show script version
make install         # Install to /usr/local/bin/xcp (requires sudo)
```

## Documentation

Full documentation available at [dalirnet.github.io/xray-chain-proxy](https://dalirnet.github.io/xray-chain-proxy/)

## License

MIT
