# Commands

## Setup

### `setup gateway`

Install and configure as exit node.

```bash
./xcp.sh setup gateway
```

Installs Xray, applies the BBR network tuning, then prompts for ports and a DNS resolver.

Next comes REALITY: it asks for a `dest` domain (default `www.microsoft.com`), checks that the domain answers with TLS 1.3 and HTTP/2, and generates the x25519 keypair and `shortId`.

Finally it sets up SSH access for the chain — the `xcp` tunnel user, its password (generated when left empty), and a `Match User xcp` block in `sshd_config` — creates the initial `default` user, and starts the port 80 IP responder. Prints the host, SSH port, user and password that edge setup asks for.

![Setup Gateway](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/setup-gateway.gif)

### `setup edge`

Install and configure as entry node.

```bash
./xcp.sh setup edge
```

Prompts for the gateway's SSH details (host, port, user, password), then local ports, a DNS resolver and a REALITY `dest` domain — each EDGE gets its own keypair, independent of the gateway's.

It then starts the `xray-tunnel` service, fetches a page through it to confirm the gateway answers, and installs the `xray-tunnel-health.timer` that keeps checking every 60 seconds.

![Setup Edge](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/setup-edge.gif)

## Service Control

### `start`

```bash
./xcp.sh start
```

### `stop`

```bash
./xcp.sh stop
```

### `restart`

```bash
./xcp.sh restart
```

> On an EDGE, `start` / `stop` / `restart` control the `xray-tunnel` service alongside Xray.

### `status`

```bash
./xcp.sh status
```

Shows running state, Xray version, and on EDGE servers the tunnel with its link quality.

```
Status:

Xray:   ● Running
Version: 24.12.18
Tunnel: ● Running
  RTT/jitter:  47.3/2.1 ms
  Retrans:     0/1841
Health: ● Checking every 60s
Echo:   ● Answering on port 80
```

`RTT/jitter` and `Retrans` are sampled from the tunnel's own socket with `ss -tin`. A retransmit total that climbs while the link is idle is the earliest sign of a shaped path — see [Reading link quality](advanced.md#reading-link-quality).

![Status](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/status.gif)

## User Management

### `user ls`

List all users with their passwords, plus a share URI for each protocol.

```bash
./xcp.sh user ls
```

Output:

```
Server: 5.6.7.8
VLESS: 443 (REALITY → www.microsoft.com)
Shadowsocks: 8388

Accounts:

1) edge
   Password: xxxxxxxx
   SS URI: ss://...
   VLESS URI: vless://...
```

### `user add`

Add new user interactively.

```bash
./xcp.sh user add
```

- Username: unique identifier
- Password: leave empty to auto-generate

One account covers both protocols: the password authenticates Shadowsocks and a generated UUID authenticates VLESS.

With `qrencode` installed it prints a QR code — of the VLESS URI where REALITY is configured, since that is the one to reach for on a restricted network.

![User Add](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/user-add.gif)

### `user rm`

Remove user by username.

```bash
./xcp.sh user rm
```

## Monitoring

### `stats`

Traffic statistics per user.

```bash
./xcp.sh stats
```

![Stats](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/stats.gif)

Output:

```
Users:
  edge: ↑1.2 MB ↓15.3 MB
  user1: ↑500 KB ↓2.1 MB

System:
  Inbound:  ↑1.7 MB ↓17.4 MB
  Outbound: ↑17.4 MB ↓1.7 MB
```

### `logs`

View access logs.

```bash
# Last 50 lines (default)
./xcp.sh logs

# Last 100 lines
./xcp.sh logs 100

# Follow in real-time
./xcp.sh logs -f
```

### `test`

Test proxy connection and speed.

```bash
./xcp.sh test
```

On EDGE: verifies the SSH tunnel carries traffic to the gateway. On both types: proxies a request through the loopback diagnostics SOCKS5 port (`127.0.0.1:11080`) to show the exit IP, resolves a name against the local resolver, and runs a speed test.

![Test](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/test.gif)

## Configuration

### `config ls`

Show current configuration.

```bash
./xcp.sh config ls
```

Output:

```
Config:

  Type:       edge
  Version:    3.x
  VLESS Port: 443
  REALITY:    www.microsoft.com
  SS Port:    8388
  SOCKS Port: 11080 (loopback)
  DNS Port:   53 (loopback)
  DNS Server: 1.1.1.1
  Log level:  error
  Gateway:    ssh://xcp@1.2.3.4:22
```

### `config set`

Change configuration interactively.

```bash
./xcp.sh config set
```

Options:

1. `loglevel` - Set log level (none/warning/info/debug)
2. `port` - Change listen ports
3. `dns` - Change the DNS resolver

Each is also reachable directly, skipping the menu:

```bash
./xcp.sh config loglevel
./xcp.sh config port
./xcp.sh config dns
```

The DNS menu offers Cloudflare, Google and Quad9, two DoH endpoints, or a custom address. On an EDGE the choice is rewritten to `tcp://` so queries fit through the tunnel; a DoH URL is kept as typed. The change restarts Xray.

```
DNS Resolver

Current: 1.1.1.1

  1) 1.1.1.1                          - Cloudflare
  2) 8.8.8.8                          - Google
  3) 9.9.9.9                          - Quad9
  4) https://dns.google/dns-query     - Google DoH
  5) https://cloudflare-dns.com/dns-query - Cloudflare DoH
  6) custom
```

## DNS Access

The resolver answers on `127.0.0.1` by default, which serves the chain and keeps the server off the open-resolver abuse lists. These commands let named clients reach it — useful for devices that can't run a proxy but can set a DNS server.

### `dns ls`

Show the resolver, whether it is reachable from outside, and who may use it.

```bash
./xcp.sh dns ls
```

```
DNS:

  Resolver: 1.1.1.1  (change with 'xcp.sh config set')
  Reachable: 0.0.0.0:53, allowed sources only

Allowed:

  1) 203.0.113.9
  2) 198.51.100.0/24
```

![DNS](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/dns-ls.gif)

### `dns add`

Allow a client, by address or CIDR block.

```bash
./xcp.sh dns add 203.0.113.9
./xcp.sh dns add 198.51.100.0/24
./xcp.sh dns add                    # prompts
```

The first allowed client binds `dns-in` to `0.0.0.0` and writes the matching `ufw` rules for 53/tcp and 53/udp.

`ufw` must be active — it is what enforces the list. With it inactive the resolver stays on loopback and says so, rather than opening a port nothing is filtering. Prefixes shorter than `/8` prompt for confirmation.

### `dns rm`

Revoke a client.

```bash
./xcp.sh dns rm 203.0.113.9
```

Removing the last allowed client puts the resolver back on loopback.

## Routing Rules

### `rule ls`

List all custom routing rules.

```bash
./xcp.sh rule ls
```

Shows rule number, outbound tag, and matched domains/IPs.

### `rule add`

Add new routing rule interactively.

```bash
./xcp.sh rule add
```

Prompts for outbound (direct/proxy/blocked), rule type, and values.

See [Routing Rules](routing.md) for detailed examples.

### `rule rm`

Remove routing rule by number.

```bash
./xcp.sh rule rm
```

Shows current rules, prompts for rule number to remove.

## Gateway Link

EDGE servers only. The link to the GATEWAY is an SSH tunnel.

### `link ls`

Show the gateway link and tunnel state.

```bash
./xcp.sh link ls
```

Output:

```
Gateway Link:

  Protocol:   ssh
  Gateway:    xcp@1.2.3.4:22
  Auth:       password
  Forward:    127.0.0.1:10080 (loopback only)
  Tunnel:     ● Running
```

![Link](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/link-ls.gif)

### `link set`

Point this EDGE at a different gateway.

```bash
./xcp.sh link set
```

Prompts for host, SSH port, SSH user and password, restarts the tunnel, verifies the new gateway answers, and rebuilds the config.

Users, ports, DNS resolver, log level and custom routing rules are preserved.

### `link restart`

Restart the SSH tunnel and Xray.

```bash
./xcp.sh link restart
```

Use this if the gateway rebooted or the connection is stuck.

### `link logs`

Show SSH tunnel logs.

```bash
./xcp.sh link logs        # last 50 lines
./xcp.sh link logs 200    # last 200 lines
```

Equivalent to `journalctl -u xray-tunnel`.

### `link health`

Fetch a page through the tunnel to confirm it carries traffic.

```bash
./xcp.sh link health
```

`xray-tunnel-health.timer` runs this every 60 seconds. Two consecutive failures restart the tunnel and Xray behind it, which catches a link that keeps answering keepalives while carrying almost nothing.

## Maintenance

### `update`

Update script and Xray to latest versions.

```bash
./xcp.sh update
```

Interactive menu to update:
- Script only (from GitHub)
- Xray only
- Both (recommended)

Configuration is preserved. Script backup saved as `script.sh.bak`.

### `uninstall`

Remove Xray completely.

```bash
./xcp.sh uninstall
```

Removes the binary, config, logs, systemd services and the stored tunnel password. On a GATEWAY it also deletes the `xcp` user and its `sshd_config` block, then reloads `sshd`.
