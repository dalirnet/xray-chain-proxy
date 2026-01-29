# Advanced

## Multi-EDGE Architectures

### Parallel EDGEs

Multiple entry points to the same GATEWAY:

```
Client A --> EDGE 1 --\
                       --> GATEWAY --> Internet
Client B --> EDGE 2 --/
```

Use cases:

- Load distribution
- Geographic diversity
- Redundancy

Setup: Run `setup edge` on each server with same GATEWAY credentials.

### Chained EDGEs

Multiple hops for extra privacy:

```
Client --> EDGE 1 --> EDGE 2 --> GATEWAY --> Internet
```

Use cases:

- Additional anonymity layers
- Bypassing deep packet inspection

Setup:

1. Setup GATEWAY normally
2. Setup EDGE 2 pointing to GATEWAY
3. Setup EDGE 1 pointing to EDGE 2 (use EDGE 2's credentials)

## Log Levels

| Level   | Description              |
| ------- | ------------------------ |
| none    | No logging               |
| warning | Warnings and errors only |
| info    | General information      |
| debug   | Detailed debug info      |

Change with:

```bash
./xcp.sh config set
# Select: 1) loglevel
```

## Firewall

Script auto-opens ports if UFW is active. For other firewalls, open:

- TCP/UDP on Shadowsocks port (443)
- TCP/UDP on HTTP port (80)
- TCP/UDP on SOCKS5 port (1080)

## Troubleshooting

### Xray won't start

Check config:

```bash
/usr/local/xray/xray run -test -config /usr/local/xray/config.json
```

Check systemd logs:

```bash
journalctl -u xray -n 50
```

### Connection refused

1. Check status: `./xcp.sh status`
2. Check firewall: `ufw status`
3. Check ports: `ss -tlnp | grep xray`

### EDGE can't reach GATEWAY

1. Verify GATEWAY IP/port
2. Check GATEWAY is running
3. Test: `curl -v telnet://GATEWAY_IP:443`
4. Check GATEWAY firewall

### Slow speeds

1. Run: `./xcp.sh test`
2. Check resources: `top`, `free -h`
3. Try different protocol
4. Check ISP throttling
