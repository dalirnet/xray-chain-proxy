# Commands

## Setup

### `setup gateway`

Install and configure as exit node.

```bash
./xcp.sh setup gateway
```

Prompts for ports, installs Xray, creates initial `edge` user.

### `setup edge`

Install and configure as entry node.

```bash
./xcp.sh setup edge
```

Prompts for GATEWAY connection details and local ports.

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

### `status`

```bash
./xcp.sh status
```

Shows running state and Xray version.

## User Management

### `user ls`

List all users with passwords and Shadowsocks URIs.

```bash
./xcp.sh user ls
```

Output:

```
Server: 5.6.7.8
Ports: SS:443 | HTTP:80 | SOCKS5:1080

Accounts:

1) edge
   Password: xxxxxxxx
   SS URI: ss://...
```

### `user add`

Add new user interactively.

```bash
./xcp.sh user add
```

- Username: unique identifier
- Password: leave empty to auto-generate

Shows QR code if `qrencode` is installed.

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

On EDGE: tests chain connectivity, shows exit IP, runs speed test.

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
  Version:    2.0.0
  SS Port:    443
  HTTP Port:  80
  SOCKS Port: 1080
  Log level:  error
  Gateway:    1.2.3.4:443
```

### `config set`

Change configuration interactively.

```bash
./xcp.sh config set
```

Options:

1. `loglevel` - Set log level (none/warning/info/debug)
2. `port` - Change listen ports

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

Removes binary, config, logs, and systemd service.
