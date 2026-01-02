# Xray Chain Proxy

Chain proxy with two servers using Xray-core. EDGE (entry node) forwards traffic to GATEWAY (exit node). Hides GATEWAY IP, allows multiple EDGEs per GATEWAY, per-user stats and QR codes.

```
Client --> EDGE --> GATEWAY --> Internet
```

## Install

```bash
curl -sL https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh -o xcp.sh
chmod +x xcp.sh
```

## Gateway Setup

Run on your exit server (the one that connects to internet):

```bash
./xcp.sh install gateway
```

Input:
```
Listen port (default: 80): <GATEWAY_PORT>
```

Output:
```
GATEWAY Ready!

Use on EDGE server:
  IP:       <GATEWAY_IP>
  Port:     <GATEWAY_PORT>
  Password: <GATEWAY_PASSWORD>
```

Save these values for EDGE setup. An initial `edge` account is created automatically.

## Edge Setup

Run on your entry server (the one clients connect to):

```bash
./xcp.sh install edge
```

Input:
```
Gateway IP: <GATEWAY_IP>
Gateway port (default: 80): <GATEWAY_PORT>
Gateway password: <GATEWAY_PASSWORD>
Listen port (default: 80): <EDGE_PORT>
```

Output:
```
EDGE Ready!

Chain: Client -> <EDGE_IP>:<EDGE_PORT> -> <GATEWAY_IP>:<GATEWAY_PORT> -> Internet

Use on Xray client:
  IP:       <EDGE_IP>
  Port:     <EDGE_PORT>
  Password: <EDGE_PASSWORD>
```

An initial `edge` account is created automatically.

## Commands

| Command           | Description    |
| ----------------- | -------------- |
| `install gateway` | Setup gateway  |
| `install edge`    | Setup edge     |
| `account list`    | List accounts  |
| `account add`     | Add account    |
| `account remove`  | Remove account |
| `status`          | Show status    |
| `stats`           | Traffic stats  |
| `logs`            | View logs      |
| `test`            | Test proxy     |
| `update`          | Update Xray    |
| `uninstall`       | Remove Xray    |

## Files

| File   | Path                          |
| ------ | ----------------------------- |
| Binary | `/usr/local/xray/xray`        |
| Config | `/usr/local/xray/config.json` |
| Logs   | `/var/log/xray/`              |

## Links

- [Xray-core](https://github.com/XTLS/Xray-core)
