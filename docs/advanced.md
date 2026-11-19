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

Setup: Run `setup edge` on each server, pointing each at the GATEWAY's SSH.

### Chained EDGEs

Multiple hops for extra privacy:

```
Client --> EDGE 1 ==ssh==> EDGE 2 ==ssh==> GATEWAY --> Internet
```

Use cases:

- Additional anonymity layers
- Bypassing deep packet inspection

Setup:

1. Setup GATEWAY normally
2. Setup EDGE 2 pointing to the GATEWAY's SSH
3. Setup EDGE 1 pointing to EDGE 2's SSH

To let EDGE 2 accept a link, give it the tunnel user first, then point it at the GATEWAY:

```bash
./xcp.sh setup gateway   # on EDGE 2, creates the xcp SSH user and sshd rule
./xcp.sh setup edge      # then links EDGE 2 to the GATEWAY
```

The second command rewrites the config as an EDGE and keeps the SSH user, so EDGE 1 can now link in.

## Link Stability

The EDGE→GATEWAY hop crosses an international path, which is where latency, packet loss and traffic shaping live. Four things keep it up.

### Congestion control

Setup writes `/etc/sysctl.d/99-xcp.conf` on both servers:

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
```

`cubic`, the default, treats every lost packet as congestion and backs off — on a shaped path it spends most of its time backing off. BBR paces on measured bandwidth and round-trip time, so it keeps the link full where cubic gives up. The 16 MB buffers let a high-latency connection hold enough data in flight to fill its bandwidth-delay product, which the defaults cap well below on a 150 ms+ path.

A kernel that offers BBR gets it; anything else keeps its current congestion control, and setup reports which applied.

### Health checks

`ServerAliveInterval` proves the socket is alive. A shaped link answers keepalives while its throughput has collapsed, so an `xray-tunnel-health.timer` fetches a page through the tunnel every 60 seconds:

```bash
./xcp.sh link health     # run one check by hand
```

Two consecutive failures restart the tunnel and Xray behind it. One slow fetch counts as noise and clears on the next success.

### Restart policy

The `xray-tunnel` unit sets `StartLimitIntervalSec=0`, so systemd retries forever. The default limit of 5 starts in 10 seconds would strand the unit in a failed state whenever the gateway is briefly unreachable at boot, since `ssh` exits instantly on a refused connection or a DNS failure.

### Transport options

`ssh` runs with `IPQoS=none`, leaving the DSCP field alone. OpenSSH otherwise marks packets `af21`/`cs1`, which is a distinctive signature and can land the tunnel in a differently shaped queue. The cipher is pinned to `aes128-gcm@openssh.com` on CPUs with AES instructions and `chacha20-poly1305@openssh.com` elsewhere, which keeps a cheap VPS on the fast side of that trade.

### Reading link quality

```bash
./xcp.sh status
```

```
Tunnel: ● Running
  RTT/jitter:  47.3/2.1 ms
  Retrans:     0/1841
Health: ● Checking every 60s
```

RTT is the round trip and the second number is its variance — jitter above roughly 20% of the RTT is what makes a session feel unresponsive. `Retrans` counts segments the kernel had to send twice; a total that climbs while the link is idle is the earliest sign of a shaped path, well before it shows up as slowness.

On a middle EDGE, `127.0.0.1:10080` belongs to its own `ssh -L` listener. A tunnel arriving from EDGE 1 lands there and rides EDGE 2's tunnel onward, so the traffic crosses two SSH hops and exits through the GATEWAY's Xray:

```
EDGE 1 (Xray) ==ssh==> EDGE 2 (ssh -L) ==ssh==> GATEWAY (Xray) --> Internet
```

Routing rules and per-user stats apply on the EDGE the client connects to and on the GATEWAY. A middle EDGE forwards the bytes.

## SSH Tunnel Internals

| Item        | Value                                               |
| ----------- | --------------------------------------------------- |
| Service     | `xray-tunnel.service` (systemd, auto-restart)       |
| Login       | `sshpass -f /usr/local/xray/tunnel_pass` (mode 600) |
| Known hosts | `/usr/local/xray/known_hosts`                       |
| Forward     | `-L 127.0.0.1:10080:127.0.0.1:10080`                |
| Local end   | `127.0.0.1:10080`, used by Xray's `proxy` outbound  |
| Far end     | `127.0.0.1:10080`, the `tunnel-in` SOCKS5 inbound   |

Reading the password from a file keeps it out of `ps` and the unit file.

Keepalives, cipher choice and the restart policy are covered under [Link Stability](#link-stability).

### The tunnel user

Gateway setup creates `xcp` with `/usr/sbin/nologin` and appends this to `/etc/ssh/sshd_config`:

```
Match User xcp
    PasswordAuthentication yes
    AllowTcpForwarding yes
    PermitOpen 127.0.0.1:10080
    PermitTTY no
    X11Forwarding no
```

A `Match` block overrides the global settings for that user alone, so a server with `PasswordAuthentication no` keeps it everywhere else. `PermitOpen` limits the account to the one forward the chain uses. The config is checked with `sshd -t` and rolled back if the test fails.

### TCP-over-TCP

SSH is TCP, and so is most tunneled traffic, so a loss on the outer connection makes the inner one back off too. Setup already applies the mitigation — BBR and larger socket buffers, written to `/etc/sysctl.d/99-xcp.conf`. See [Congestion control](#congestion-control) for what it sets and why.

### UDP

SSH port forwarding carries TCP. The EDGE config handles this:

- Client DNS on UDP/53 is answered by the `dns-out` outbound, which resolves over TCP through the chain
- All other UDP is sent to `blocked` - QUIC and similar protocols fall back to TCP automatically

## DNS

Both server types run a resolver on `127.0.0.1:53`, TCP and UDP, built from three pieces:

| Piece            | Role                                                      |
| ---------------- | --------------------------------------------------------- |
| `dns-in` inbound | `dokodemo-door` on port 53, redirecting to the resolver   |
| `dns-out`        | Xray's `dns` outbound, answering from the built-in client |
| `.dns.servers`   | The resolver itself, stored as `.xcp.dns` in the config   |

`dns-in` listens on 53 by default; `config port` moves it to any port, and the resolver it forwards to stays on 53. A custom port is clear of `systemd-resolved` from the start, so the stub handover below applies to 53 only.

On an EDGE the resolver is written as `tcp://ADDRESS` so queries fit through the tunnel. A DoH URL is stored as typed and travels the chain over HTTPS.

```bash
./xcp.sh config set
# Select: 3) dns
```

Traffic arriving through VLESS or Shadowsocks resolves through this automatically, so clients work with whatever DNS they already have.

Loopback is the default because a resolver reachable from the internet gets found by scanners and used for amplification, which is a common reason providers suspend an account. To let a device query it directly, allow that device by address — see [DNS access](commands.md#dns-access):

```bash
./xcp.sh dns add 203.0.113.9
```

### systemd-resolved

Ubuntu runs a stub resolver on `127.0.0.53:53`. That is a different address from the `127.0.0.1:53` Xray binds, so the two normally coexist and setup leaves the stub alone.

Some images do put a resolver on `127.0.0.1:53` — NetworkManager's dnsmasq, for instance. Only then does setup hand the port over: it writes `DNSStubListener=no` to `/etc/systemd/resolved.conf.d/xcp.conf`, restarts `systemd-resolved`, and links `/etc/resolv.conf` to `/run/systemd/resolve/resolv.conf` so the server keeps resolving names. `uninstall` gives the stub listener back.

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

Script auto-opens ports if UFW is active. For other firewalls and for the provider's own security group, both roles need the same rules:

```
22, 80, 443, 8443/tcp
8443/udp
```

Both roles serve VLESS+REALITY (443), Shadowsocks (8443) or both, as chosen at setup — open only the ports of the enabled protocols. The GATEWAY additionally accepts the tunnel on SSH (22).

| Port   | Protocols | Why                                              |
| ------ | --------- | ------------------------------------------------ |
| `22`   | TCP       | SSH                                              |
| `80`   | TCP       | The IP responder is a `ListenStream` socket      |
| `443`  | TCP       | REALITY sets `streamSettings.network` to `tcp`   |
| `8443` | TCP + UDP | Shadowsocks sets `settings.network` to `tcp,udp` |

Shadowsocks is the only client protocol carrying UDP, so it is the only one that needs a UDP rule. Note that a UDP payload reaching an **EDGE** is dropped by the routing tail anyway, since the SSH tunnel carries TCP — Shadowsocks UDP only reaches the internet from a **GATEWAY**.

The ports above are defaults. With custom ports from setup or `config port`, open those instead — `ufw` gets them automatically.

Port `53` needs both TCP and UDP, and only from the clients you allow with `dns add`, so it gets a per-source rule. Ports `10080`, `10085` and `11080` stay bound to `127.0.0.1` and need no rule at all.

## REALITY

The VLESS inbound on 443 borrows a real site's TLS handshake. Handshakes from unknown clients are proxied to `dest`, so an active prober gets a genuine TLS 1.3 answer with that site's own valid certificate chain — a real certificate, presented by a real site.

### No domain required

Two names are involved and only one of them is yours to arrange — neither needs a DNS record pointing at your server:

- `dest` / `sni` is **someone else's** domain. You borrow its handshake, so the certificate stays that site's responsibility.
- Your server is reached by **bare IP**, which is what the share URI carries.

```
vless://<uuid>@203.0.113.9:443?...&sni=www.cloudflare.com&...
              ↑ your IP              ↑ the borrowed domain
```

The client opens TCP to your IP, then sends a ClientHello announcing the borrowed name. Plain VLESS+TLS and Trojan need a domain you control, a DNS record and a maintained certificate. REALITY works from a bare IP. Putting a domain in front of your server also works, and makes rotating the IP easier.

Setup generates the x25519 pair with `xray x25519` and a random 8-byte `shortId`. The private key stays in the inbound; the public half lives in the config's `xcp.reality` block, which is what rebuilds share URIs later.

### Choosing a dest

Setup checks the domain with `openssl s_client` and accepts it when it answers TLS 1.3 with HTTP/2. A good `dest`:

- Serves TLS 1.3 and HTTP/2
- Is reachable from the GATEWAY
- Stays unfiltered in the region your clients connect from — a blocked domain hands probers a broken handshake to look at
- Belongs to someone else, and ideally sits near the server

Check a candidate by hand:

```bash
openssl s_client -connect www.cloudflare.com:443 -tls1_3 -alpn h2 </dev/null 2>&1 \
  | grep -E 'Protocol|ALPN'
```

### Clock accuracy

REALITY authenticates with a timestamp. More than roughly 90 seconds of drift between client and server and authentication fails, with no error that points at the clock. Install `chrony` or enable `systemd-timesyncd` on both servers.

### UDP

VLESS carries UDP inside its TCP connection, so QUIC, calls and games work for clients connecting to a **GATEWAY** directly. On an **EDGE**, that traffic still stops at the routing rule that blocks UDP, because the SSH tunnel to the gateway carries TCP only.

## Port 80

Both roles answer on 80 (or the port chosen at setup or with `config port`) with the address the connection arrives from:

```bash
curl http://SERVER_IP     # 203.0.113.9
```

An `xcp-web.socket` systemd unit owns the port and hands each connection to a short-lived responder under `DynamicUser`, with `ProtectSystem=strict` and `NoNewPrivileges`. systemd owns the socket and each worker exits with its connection. If something already holds the port, setup reports it and skips the responder. Pick another port with `config port` to bring it back; the port is stored as `.xcp.web_port`.

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

### EDGE can't reach the GATEWAY

1. Check the tunnel: `./xcp.sh link ls`
2. Read tunnel logs: `./xcp.sh link logs`
3. Verify SSH by hand:
    ```bash
    ssh -p 22 xcp@GATEWAY_IP
    ```
    The `xcp` user is forward-only, so a successful login closes right away. That is the expected result.
4. Check the GATEWAY's `sshd` is running and its firewall allows the SSH port
5. Restart the tunnel: `./xcp.sh link restart`

### Setup says there is no proxy behind the tunnel

The SSH login worked, and the far end answered nothing on `127.0.0.1:10080`. Run `./xcp.sh setup gateway` on that server, confirm `./xcp.sh status` shows Xray running there, then re-run `./xcp.sh link set` on the EDGE.

### Password login is refused

On the GATEWAY, confirm the tunnel user and its sshd block survived a later edit:

```bash
id xcp
sshd -T -C user=xcp | grep -E 'passwordauthentication|permitopen'
```

Expected: `passwordauthentication yes` and `permitopen 127.0.0.1:10080`. Re-run `./xcp.sh setup gateway` to restore them and set a fresh password.

### Tunnel keeps restarting

Usually `ExitOnForwardFailure` firing because the local port is taken, or sshd refusing forwarding.

```bash
journalctl -u xray-tunnel -n 50
ss -tlnp | grep 10080                   # local port already used?
```

On the GATEWAY, confirm forwarding is allowed in `/etc/ssh/sshd_config`:

```
AllowTcpForwarding yes
```

### VLESS clients cannot connect

The server looks healthy, the port is open, and clients still fail — often looking like wrong credentials. The dest is the first thing to check.

REALITY borrows the dest's handshake and hands it to the client. A domain can answer TLS 1.3 with HTTP/2 and still return a hello REALITY cannot reuse, in which case every client is dropped before its uuid is read. Nothing in the server log looks alarming, and the client just sees the connection end.

```bash
./xcp.sh test          # reports whether a client completes the handshake
```

A failure there names the dest. Switch it and re-test:

```bash
./xcp.sh config dest   # try www.cloudflare.com, dl.google.com, cdn.jsdelivr.net, www.speedtest.net
./xcp.sh user ls       # the SNI changed, so reimport the URIs
```

Two other things worth confirming while you are here: the share URI matches the current keys, since `setup` issues new ones each run, and both clocks are accurate, since REALITY authenticates with a timestamp and drifts out past roughly 90 seconds.

### DNS returns nothing

The resolver answers on loopback, so test it from the server itself:

```bash
dig @127.0.0.1 example.com
ss -ulnp | grep :53
```

Expect `xray` on `127.0.0.1:53`. If something else holds it, apply the [systemd-resolved](#systemd-resolved) step by hand.

Querying from another machine needs that machine allowed first, and `ufw` active to enforce the list:

```bash
./xcp.sh dns ls                 # who may query, and whether it is enforced
./xcp.sh dns add 203.0.113.9
```

### Slow speeds

1. Run: `./xcp.sh test`
2. Check resources: `top`, `free -h`
3. Try different protocol
4. Check ISP throttling
