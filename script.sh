#!/usr/bin/env bash

#
# Xray Chain Proxy
#
# Chain proxy setup with two server types:
#   - GATEWAY: Exit node that connects to the internet
#   - EDGE: Entry node that clients connect to, forwards to GATEWAY
#
# Flow: Client --> EDGE --> [SSH tunnel] --> GATEWAY --> Internet
#
# The link between servers is always an SSH tunnel. The EDGE reaches the
# GATEWAY through a persistent SSH connection that forwards a loopback SOCKS5
# port, which Xray uses as its proxy outbound. It logs in with a password, as a
# dedicated shell-less SSH user the GATEWAY creates for it. Both servers run
# this script, and the GATEWAY end of the tunnel is its own Xray.
#
# Clients arrive over VLESS+REALITY or Shadowsocks - Shadowsocks authenticates
# with a password and VLESS with a uuid, one account carries both, and neither
# puts a credential on the wire in the clear. REALITY holds 443 and proxies
# handshakes it does not recognise to a real site, so a prober there gets a
# genuine TLS answer with that site's own certificate.
#
# Both roles listen on the same ports, so one firewall rule covers them:
#
#   Public:    22 (ssh, GATEWAY only), 80 (ip echo), 443 (vless/reality),
#              8443 (shadowsocks)
#   Loopback:  53 (dns), 10080 (tunnel), 10085 (stats api),
#              11080 (no-auth socks5 for diagnostics)
#
# Author: Amir Reza Dalir (dalirnet@gmail.com)
# License: MIT
#
# Usage:
#   script.sh setup gateway     - Setup gateway server
#   script.sh setup edge        - Setup edge server
#   script.sh start             - Start Xray service
#   script.sh stop              - Stop Xray service
#   script.sh restart           - Restart Xray service
#   script.sh status            - Show service status
#   script.sh user ls           - List all users
#   script.sh user add          - Add new user
#   script.sh user rm           - Remove user
#   script.sh stats             - Show traffic statistics
#   script.sh logs [-f] [n]     - Show logs (-f to follow)
#   script.sh test              - Test proxy and speed
#   script.sh config ls         - Show current config
#   script.sh config set        - Set log level, ports, DNS resolver or REALITY dest
#   script.sh dns ls            - Show the resolver and who may use it
#   script.sh dns add [ip]      - Allow a client to use this server for DNS
#   script.sh dns rm [ip]       - Revoke a client
#   script.sh rule ls           - List routing rules
#   script.sh rule add          - Add routing rule
#   script.sh rule rm           - Remove routing rule
#   script.sh link ls           - Show gateway SSH link
#   script.sh link set          - Change gateway SSH link
#   script.sh link restart      - Restart SSH tunnel
#   script.sh link logs [n]     - Show SSH tunnel logs
#   script.sh link health       - Check the tunnel end to end
#   script.sh update            - Update script and Xray
#   script.sh uninstall         - Remove Xray completely
#

set -euo pipefail

# Script info
readonly VERSION="3.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

# Directories and files
readonly XRAY_DIR="/usr/local/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly CACHE_DIR="/tmp/xray-cache"

# SSH tunnel (link between servers)
# TUNNEL_PORT is loopback-only on both ends: the edge forwards its local
# 127.0.0.1:10080 to the same port on the gateway, where a no-auth SOCKS5
# inbound hands the traffic to the gateway's Xray. Never firewalled open.
readonly TUNNEL_SERVICE="/etc/systemd/system/xray-tunnel.service"
readonly TUNNEL_HEALTH_SERVICE="/etc/systemd/system/xray-tunnel-health.service"
readonly TUNNEL_HEALTH_TIMER="/etc/systemd/system/xray-tunnel-health.timer"
readonly TUNNEL_HEALTH_STATE="/run/xcp-tunnel-health"
readonly TUNNEL_KNOWN_HOSTS="${XRAY_DIR}/known_hosts"
readonly TUNNEL_PASS_FILE="${XRAY_DIR}/tunnel_pass"
readonly TUNNEL_PORT=10080
readonly DEFAULT_SSH_PORT=22
readonly TUNNEL_SSH_USER="xcp"

# Xray's stats API, loopback only - `stats` reads per-user counters from it
readonly API_PORT=10085

# Kernel tuning for the border hop
readonly SYSCTL_DROPIN="/etc/sysctl.d/99-xcp.conf"

# Default ports. Both roles listen on the same set, so one provider firewall
# rule covers them: 22, 80, 443, 8443.
#
# Shadowsocks sits on 8443, which reads as alternate HTTPS and stays open on
# networks that close uncommon ports. Its canonical 8388 heads every block list
# and was measured blocked on a censored path where 8443 carried traffic.
readonly DEFAULT_SS_PORT=8443
readonly DEFAULT_DNS_PORT=53

# No-auth SOCKS5 on loopback, for `test` and for curl on the server itself.
# Never firewalled open, and no part of user management.
#
# Deliberately outside the 1008x block: 10085 is the conventional Xray API port,
# so its neighbours are the first thing a co-installed panel or a second Xray
# instance takes. 11080 is unregistered and sits below the ephemeral range.
readonly LOCAL_SOCKS_PORT=11080

# VLESS + REALITY. Port 443 is the point: REALITY proxies handshakes it does not
# recognise to the real dest site, so a prober gets a genuine TLS 1.3 answer with
# a valid certificate chain - which only reads as ordinary on the port HTTPS uses.
readonly DEFAULT_VLESS_PORT=443
# The dest lends REALITY its handshake, so it has to chain with what current
# clients send. www.microsoft.com answers TLS 1.3 with HTTP/2 yet returns a
# server hello REALITY cannot reuse - measured on Xray 26, the handshake never
# completes and every client is dropped before its uuid is read. Swap a dest
# with `config dest`; reality_verify_chain is what tells them apart.
readonly DEFAULT_REALITY_DEST="www.bing.com"
readonly REALITY_DEST_ALTERNATIVES="www.bing.com, dl.google.com, cdn.jsdelivr.net, www.cloudflare.com"
readonly REALITY_FLOW="xtls-rprx-vision"

# Loopback port the REALITY handshake check listens on, held only while it runs
readonly REALITY_PROBE_PORT=11081

# Port 80 answers with the caller's own IP, so `curl http://server` reports the
# address a connection arrives from. systemd owns the socket and hands each
# connection to a short-lived unprivileged responder, which keeps a web server
# out of the picture entirely.
readonly WEB_PORT=80
readonly WEB_SOCKET="/etc/systemd/system/xcp-web.socket"
readonly WEB_SERVICE="/etc/systemd/system/xcp-web@.service"
readonly WEB_RESPONDER="${XRAY_DIR}/ip-echo.sh"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/xcp.conf"

# DNS resolver the servers answer with (plain IP, tcp://IP or a DoH URL)
readonly DEFAULT_DNS="1.1.1.1"

# Xray settings
readonly ENCRYPTION_METHOD="aes-256-gcm"
readonly XRAY_FALLBACK_VERSION="v24.12.18"
readonly XRAY_RELEASE_URL="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

# Terminal colors (auto-detect support)
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# --- Logging ---

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit "${2:-1}"; }
log_step()    { echo -e "\n${BOLD}>>> $1${NC}"; }

# --- Validation ---

# Check if running as root
check_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root"
}

# Check if systemd is available
check_systemd() {
    command -v systemctl &>/dev/null || log_error "systemd is required"
}

# --- Guards ---
# Shared preconditions. Each reports the reason and exits, so the commands that
# use them read as a list of requirements rather than a stack of tests.

require_xray() {
    [[ -f "$XRAY_BIN" ]] || log_error "Xray not installed"
}

require_config() {
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"
}

require_accounts() {
    require_config
    jq -e '.inbounds[] | select(.tag == "ss-in") | .settings.clients' "$XRAY_CONFIG" &>/dev/null || \
        log_error "No accounts configured"
}

require_tunnel() {
    [[ -f "$TUNNEL_SERVICE" ]] || log_error "No tunnel configured"
}

# Link commands only apply to edge servers
require_edge() {
    require_config
    [[ "$(jq -r '.xcp.type // "unknown"' "$XRAY_CONFIG")" == "edge" ]] || \
        log_error "Only EDGE servers link to a gateway"
}

# Validate port number (1-65535)
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

# Validate IP address or domain name
validate_address() {
    local addr="$1"
    [[ -z "$addr" ]] && return 1

    # Check if valid IPv4
    if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra octets <<< "$addr"
        for octet in "${octets[@]}"; do
            [[ "$octet" -le 255 ]] || return 1
        done
        return 0
    fi

    # Check if valid domain
    [[ "$addr" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && return 0
    return 1
}

# Validate an IPv4 address or CIDR block (1.2.3.4 or 1.2.3.0/24)
validate_cidr() {
    local value="$1"
    local addr="${value%%/*}"
    local bits="${value#*/}"

    [[ -z "$value" ]] && return 1

    # Reject a domain here - firewall rules need an address, not a name that
    # could resolve somewhere else tomorrow
    [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    validate_address "$addr" || return 1

    [[ "$value" == */* ]] || return 0
    [[ "$bits" =~ ^[0-9]+$ ]] && [[ "$bits" -ge 0 ]] && [[ "$bits" -le 32 ]]
}

# Validate a DNS resolver: plain address, scheme://address or a DoH URL
validate_dns() {
    local dns="$1"
    [[ -z "$dns" ]] && return 1

    case "$dns" in
        https://*) [[ "$dns" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/[a-zA-Z0-9./_-]*$ ]] ;;
        *://*)     validate_address "${dns#*://}" ;;
        *)         validate_address "$dns" ;;
    esac
}

# --- Utilities ---

# Generate random password
generate_password() {
    local len="${1:-16}"
    openssl rand -base64 32 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$len" || \
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

# URL-safe base64 encoding
base64_urlsafe() {
    echo -n "$1" | base64 | tr '+/' '-_' | tr -d '='
}

# Format bytes to human readable
format_bytes() {
    local b=${1:-0}
    [[ ! "$b" =~ ^[0-9]+$ ]] && b=0
    ((b < 1024)) && echo "${b} B" && return
    ((b < 1048576)) && echo "$((b / 1024)) KB" && return
    ((b < 1073741824)) && echo "$((b / 1048576)) MB" && return
    echo "$((b / 1073741824)) GB"
}

# Get public IP address
get_public_ip() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 --max-time 10 "http://ip-api.com/line/?fields=query" 2>/dev/null | tr -d '[:space:]')
    validate_address "$ip" && echo "$ip" || echo "YOUR_SERVER_IP"
}

# Detect system architecture
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l|armv7)  echo "arm32-v7a" ;;
        i686|i386)     echo "32" ;;
        *)             log_error "Unsupported architecture" ;;
    esac
}

# Download with retry (prompts if file exists)
download_with_retry() {
    local url="$1"
    local output="$2"
    local retries="${3:-3}"
    local delay="${4:-5}"

    # Prompt if file already exists and is not empty
    if [[ -f "$output" && -s "$output" ]]; then
        read -rp "File exists: $(basename "$output"). Re-download? [y/N]: " ans
        [[ ! "$ans" =~ ^[Yy]$ ]] && return 0
        rm -f "$output"
    fi

    for ((i=1; i<=retries; i++)); do
        local curl_output
        curl_output=$(curl -L --progress-bar --fail -o "$output" "$url" \
            -w '%{speed_download}|%{time_total}|%{size_download}' 2>&1)

        if [[ $? -eq 0 ]]; then
            # Extract metrics from curl output
            local metrics=$(echo "$curl_output" | tail -1)
            local speed=$(echo "$metrics" | cut -d'|' -f1 | cut -d'.' -f1)
            local time=$(echo "$metrics" | cut -d'|' -f2)
            local size=$(echo "$metrics" | cut -d'|' -f3 | cut -d'.' -f1)

            # Format output
            echo
            echo "  Speed: $(format_bytes $speed)/s | Time: ${time}s | Size: $(format_bytes $size)"
            return 0
        fi

        # Remove failed partial download
        rm -f "$output"
        [[ $i -lt $retries ]] && log_warn "Download failed, retry $i/$retries in ${delay}s..." && sleep "$delay"
    done
    return 1
}

# --- Prompts ---

# Prompt for port number
prompt_port() {
    local prompt="$1" default="$2"
    local -n _port="$3"

    while true; do
        read -rp "$prompt (default: $default): " input
        input="${input:-$default}"
        validate_port "$input" && { _port="$input"; break; }
        echo -e "${RED}Invalid port${NC}"
    done
}

# Prompt for IP address
prompt_address() {
    local prompt="$1"
    local -n _addr="$2"

    while true; do
        read -rp "$prompt: " input
        validate_address "$input" && { _addr="$input"; break; }
        echo -e "${RED}Invalid IP/domain${NC}"
    done
}

# Prompt for password (hidden). Empty input generates a strong one when allowed.
prompt_password() {
    local prompt="$1" allow_empty="$2"
    local -n _pass="$3"
    local length="${4:-16}"

    if [[ "$allow_empty" == "true" ]]; then
        read -rsp "$prompt (empty=generate): " input
        echo
        [[ -z "$input" ]] && { input=$(generate_password "$length"); log_info "Generated: $input"; }
        _pass="$input"
    else
        while true; do
            read -rsp "$prompt: " input
            echo
            [[ -n "$input" ]] && { _pass="$input"; break; }
            echo -e "${RED}Cannot be empty${NC}"
        done
    fi
}

# Prompt for a DNS resolver: plain IP, tcp://IP or a DoH URL
prompt_dns() {
    local prompt="$1" default="$2"
    local -n _dns="$3"

    while true; do
        read -rp "$prompt (default: $default): " input
        input="${input:-$default}"
        validate_dns "$input" && { _dns="$input"; break; }
        echo -e "${RED}Invalid resolver - use an IP (1.1.1.1) or a DoH URL (https://dns.google/dns-query)${NC}"
    done
}

# --- Installation ---

# Check and install dependencies
check_dependencies() {
    log_step "Checking dependencies"

    # Required dependencies (sshpass carries the tunnel login)
    local required=()
    for cmd in curl unzip jq sshpass; do
        command -v "$cmd" &>/dev/null || required+=("$cmd")
    done

    if [[ ${#required[@]} -gt 0 ]]; then
        log_info "Installing required: ${required[*]}"
        apt-get update -qq && apt-get install -y -qq "${required[@]}" || log_error "Failed to install dependencies"
    fi

    # Optional dependencies (ignore if install fails)
    local optional=()
    command -v qrencode &>/dev/null      || optional+=("qrencode")
    command -v speedtest-cli &>/dev/null || optional+=("speedtest-cli")
    command -v dig &>/dev/null           || optional+=("dnsutils")

    if [[ ${#optional[@]} -gt 0 ]]; then
        log_info "Installing optional: ${optional[*]}"
        apt-get install -y -qq "${optional[@]}" 2>/dev/null || log_warn "Optional dependencies not installed: ${optional[*]}"
    fi

    log_success "Dependencies ready"
}

# Install Xray-core
install_xray() {
    log_step "Installing Xray-core"

    if [[ -f "$XRAY_BIN" ]]; then
        local ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
        log_info "Xray already installed (v$ver)"
        read -rp "Reinstall? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return 0
    fi

    local arch=$(get_arch)
    mkdir -p "$CACHE_DIR"

    log_info "Fetching latest version..."
    local version=$(curl -s --connect-timeout 10 "$XRAY_RELEASE_URL" 2>/dev/null | jq -r '.tag_name // empty' || echo "$XRAY_FALLBACK_VERSION")
    [[ -z "$version" ]] && version="$XRAY_FALLBACK_VERSION"
    log_info "Version: $version"

    local zip_file="$CACHE_DIR/Xray-linux-${arch}-${version}.zip"

    log_info "Downloading..."
    download_with_retry "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip" "$zip_file" || log_error "Download failed after retries"

    mkdir -p "$XRAY_DIR" "$LOG_DIR"
    unzip -o -q "$zip_file" -d "$XRAY_DIR" || log_error "Extract failed"
    chmod +x "$XRAY_BIN"

    read -rp "Download geo data (geoip.dat, geosite.dat)? [Y/n]: " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        log_info "Downloading geo data..."
        download_with_retry "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" "$XRAY_DIR/geoip.dat" || true
        download_with_retry "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" "$XRAY_DIR/geosite.dat" || true
    else
        log_info "Skipping geo data download"
    fi

    # Create systemd service
    cat > "$XRAY_SERVICE" << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target xray-tunnel.service
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=/usr/local/xray
ExecStart=/usr/local/xray/xray run -config /usr/local/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray --quiet 2>/dev/null || true

    log_success "Xray installed: $version"
}

# Validate Xray configuration
validate_config() {
    require_config
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" &>/dev/null || log_error "Invalid config"
    log_success "Configuration valid"
}

# Install a rewritten config, reading it from stdin.
# jq cannot write back into the file it is reading, so the new version always
# lands in a temp file first. It is only moved into place once it parses, which
# keeps a jq that died halfway from leaving a truncated config behind.
config_write() {
    local config="${1:-$XRAY_CONFIG}"
    local tmp
    tmp=$(mktemp)

    cat > "$tmp"

    if ! jq -e . "$tmp" &>/dev/null; then
        rm -f "$tmp"
        log_error "Config rewrite produced invalid JSON - the original is untouched"
    fi

    mv "$tmp" "$config"
}

# Check the config and load it. Every command that edits the config ends here.
apply_config() {
    apply_config
}

# True only when ufw is installed and enforcing.
# "Status: inactive" contains the word "active", so the anchor matters here -
# anything looser reports a firewall that is not filtering anything.
firewall_active() {
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"
}

# Open the given ports. Each argument is "port" for TCP or "port/proto" to pick
# one explicitly. Only inbounds that listen on a public address are passed in -
# loopback ones need no rule, on either side of the firewall.
#
# Shadowsocks is the only client protocol carrying UDP: REALITY sets
# streamSettings.network to tcp, the port 80 responder is a ListenStream socket,
# and SSH is TCP. Opening UDP on those would widen the surface for nothing.
configure_firewall() {
    local spec port proto

    firewall_active || return 0

    for spec in "$@"; do
        port="${spec%%/*}"
        proto="tcp"
        [[ "$spec" == */* ]] && proto="${spec#*/}"
        ufw allow "${port}/${proto}" &>/dev/null || true
    done

    log_info "Firewall: opened $*"
}

# Refuse to continue when something else already owns a port Xray needs.
#
# Setup rewrites the config and restarts everything anyway, so our own services
# are stopped first - otherwise a re-run would flag the ports this server
# already holds. Whatever is left is a genuine clash, and naming it here beats
# the generic "Xray failed to start" it would otherwise become.
#
# Port 53 is left out: systemd-resolved parks on 127.0.0.53, which is a
# different address, and free_dns_port handles the cases that do collide.
preflight_ports() {
    local port busy=()

    command -v ss &>/dev/null || return 0

    systemctl stop xray 2>/dev/null || true
    systemctl stop xray-tunnel 2>/dev/null || true

    for port in "$@"; do
        port_taken "$port" && busy+=("$port")
    done

    [[ ${#busy[@]} -eq 0 ]] && return 0

    log_warn "Ports already in use: ${busy[*]}"
    ss -H -lntup 2>/dev/null | grep -E "[[:space:]](127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]):($(IFS='|'; echo "${busy[*]}"))[[:space:]]" >&2
    log_error "Free those ports or choose different ones, then run setup again"
}

# Tune the kernel for a long, lossy international hop.
# cubic reads every lost packet as congestion and backs off, which on a shaped
# path means it spends most of its time backing off. BBR paces on measured
# bandwidth and round-trip time instead, so it keeps the link full where cubic
# gives up. The larger buffers let a high-latency connection hold enough data
# in flight to fill its bandwidth-delay product, which the defaults cap well
# below on a 150ms+ path.
tune_network() {
    log_step "Network Tuning"

    modprobe tcp_bbr 2>/dev/null || true

    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        log_warn "This kernel offers no BBR - keeping the current congestion control"
        return 0
    fi

    cat > "$SYSCTL_DROPIN" << 'EOF'
# Managed by xray-chain-proxy
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    sysctl -q --load "$SYSCTL_DROPIN" 2>/dev/null || true

    log_success "BBR congestion control and 16MB socket buffers active"
}

# --- DNS resolution ---
# Helpers for how this server resolves names. Who may ask it to is further
# down, under "DNS access".

# Plain resolver IP for the dokodemo-door redirect target.
# DoH URLs have no usable IP here, so fall back to the default resolver -
# A/AAAA answers still come from the built-in DNS client over DoH.
dns_ip() {
    local addr="${1#*://}"
    addr="${addr%%/*}"
    addr="${addr%%:*}"

    [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo "$addr" || echo "$DEFAULT_DNS"
}

# Force TCP for plain resolvers - the SSH tunnel carries no UDP.
# Scheme-qualified values (tcp://, https://, quic://) are passed through.
dns_over_tcp() {
    case "$1" in
        *://*) echo "$1" ;;
        *)     echo "tcp://$1" ;;
    esac
}

# True when something already listens on the given port, on loopback or on a
# public address. Without ss the answer is unknown, so it reports "free" and
# lets callers decide - claiming a clash we cannot see would block setup.
port_taken() {
    local port="$1"
    command -v ss &>/dev/null || return 1
    ss -H -lntu 2>/dev/null | grep -qE "[[:space:]](127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]):${port}[[:space:]]"
}

# dns-in binds 127.0.0.1:53, and systemd-resolved's stub sits on 127.0.0.53:53,
# so the two normally coexist. Some images still put dnsmasq or a resolver on
# 127.0.0.1:53 - only then turn the stub off and point the system at the real
# resolvers it already tracks, so name resolution keeps working here.
free_dns_port() {
    # Without ss the answer is unknown, so hand the port over rather than risk
    # a clash Xray would only report as a failed start
    if command -v ss &>/dev/null && ! port_taken "$DEFAULT_DNS_PORT"; then
        return 0
    fi

    systemctl is-active systemd-resolved &>/dev/null || return 0

    log_info "Freeing port ${DEFAULT_DNS_PORT} from systemd-resolved..."

    mkdir -p "$(dirname "$RESOLVED_DROPIN")"
    cat > "$RESOLVED_DROPIN" << EOF
[Resolve]
DNSStubListener=no
EOF

    systemctl restart systemd-resolved 2>/dev/null || true

    # /etc/resolv.conf pointed at the stub - follow the upstream list instead
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi

    log_success "Port ${DEFAULT_DNS_PORT} is free"
}

# Give the stub listener back (uninstall)
restore_dns_port() {
    [[ -f "$RESOLVED_DROPIN" ]] || return 0

    rm -f "$RESOLVED_DROPIN"
    systemctl restart systemd-resolved 2>/dev/null || true

    if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
}

# --- Port 80 responder ---

# Write the standalone responder the socket unit runs.
#
# It is a separate file, not `xcp.sh respond`, because the unit runs as nobody
# and xcp.sh normally lives in root's home, which nobody cannot read - that is
# an exec failure, so systemd closes the connection and the client sees RST.
# Keeping it here also means moving or renaming xcp.sh cannot break port 80.
#
# systemd sets REMOTE_ADDR for an Accept=yes socket, so the address comes from
# the kernel rather than from anything the client can claim.
web_write_responder() {
    mkdir -p "$XRAY_DIR"

    cat > "$WEB_RESPONDER" << 'RESPONDER'
#!/usr/bin/env bash
# Managed by xray-chain-proxy - answers one connection with the caller's IP.

ip="${REMOTE_ADDR:-unknown}"

# IPv4 arriving on a dual-stack socket shows up as ::ffff:1.2.3.4
ip="${ip#::ffff:}"

# Read the whole request head. stdin here is the socket itself, and exiting
# with bytes still unread makes the kernel send RST instead of FIN, which can
# destroy a response the client is still reading. Bounded by a deadline and a
# per-line size cap so a client that never terminates cannot hold this open.
deadline=$(( SECONDS + 3 ))
while (( SECONDS < deadline )); do
    read -r -t 1 -n 8192 line || break
    [[ -z "${line%$'\r'}" ]] && break
done

printf 'HTTP/1.1 200 OK\r\n'
printf 'Content-Type: text/plain; charset=utf-8\r\n'
printf 'Content-Length: %d\r\n' "$(( ${#ip} + 1 ))"
printf 'Connection: close\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'
printf '%s\n' "$ip"
RESPONDER

    # World-readable and executable: the unit runs as nobody
    chmod 755 "$WEB_RESPONDER"
}

# Install the socket and its per-connection responder.
# The responder faces the internet, so it runs as nobody with the filesystem
# read-only and privilege escalation off - systemd binds the privileged port
# and the responder never needs root.
# Install the socket and its per-connection responder.
#
# DynamicUser gives each worker a transient unprivileged identity, which systemd
# prefers over `User=nobody` - nobody is shared with every other service that
# picks it, and systemd warns about exactly that.
web_install() {
    web_write_responder

    cat > "$WEB_SOCKET" << EOF
[Unit]
Description=Xray Chain Proxy IP Echo Socket
Documentation=https://github.com/dalirnet/xray-chain-proxy

[Socket]
ListenStream=${WEB_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
EOF

    cat > "$WEB_SERVICE" << EOF
[Unit]
Description=Xray Chain Proxy IP Echo

[Service]
Type=simple
ExecStart=${WEB_RESPONDER}
StandardInput=socket
StandardOutput=socket
StandardError=journal
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6
RuntimeMaxSec=10
EOF

    systemctl daemon-reload
    systemctl enable xcp-web.socket --quiet 2>/dev/null || true

    if systemctl restart xcp-web.socket 2>/dev/null; then
        log_success "Port ${WEB_PORT} answers with the caller's IP"
    else
        log_warn "Port ${WEB_PORT} is already in use - skipping the IP responder"
        systemctl disable xcp-web.socket --quiet 2>/dev/null || true
        rm -f "$WEB_SOCKET" "$WEB_SERVICE"
        systemctl daemon-reload
    fi
}

# Remove the socket and responder (uninstall)
web_purge() {
    systemctl stop xcp-web.socket 2>/dev/null || true
    systemctl disable xcp-web.socket --quiet 2>/dev/null || true
    rm -f "$WEB_SOCKET" "$WEB_SERVICE" "$WEB_RESPONDER"
    systemctl daemon-reload 2>/dev/null || true
}

# --- REALITY ---

# 8 random bytes as hex. Falls back to /dev/urandom so openssl stays optional.
generate_shortid() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 8
    else
        head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# Generate the x25519 pair REALITY authenticates with.
# Xray labels the output "Private key/Public key" up to v24 and
# "PrivateKey/Password" from v25, so both spellings are read here.
# Prints "<private> <public>".
reality_keys() {
    local out priv pub

    out=$("$XRAY_BIN" x25519 2>/dev/null) || log_error "Failed to generate REALITY keys"

    # `|| true` matters here: with pipefail a non-matching grep fails the whole
    # substitution, and set -e would abort before the check below - turning an
    # unrecognised output format into a silent exit mid-setup
    priv=$(echo "$out" | grep -iE '^private ?key' | awk '{print $NF}' || true)
    pub=$(echo "$out" | grep -iE '^(public ?key|password)' | awk '{print $NF}' || true)

    [[ -n "$priv" && -n "$pub" ]] || \
        log_error "Could not read the REALITY keys from '${XRAY_BIN} x25519' - unexpected output format"

    echo "$priv $pub"
}

# A usable dest speaks TLS 1.3 and HTTP/2, and answers from this server.
# Camouflage only holds while the site it borrows stays reachable and unfiltered,
# so a name that fails here would hand probers a broken handshake to look at.
reality_check_dest() {
    local host="$1"

    command -v openssl &>/dev/null || return 0

    local out
    out=$(echo | timeout 10 openssl s_client -connect "${host}:443" -servername "$host" \
        -tls1_3 -alpn h2 2>/dev/null) || return 1

    echo "$out" | grep -q "TLSv1.3" && echo "$out" | grep -q "ALPN protocol: h2"
}

# Ask for the dest, keeping the default when it answers correctly
prompt_reality_dest() {
    local -n _dest="$1"
    local input

    while true; do
        read -rp "REALITY dest domain (default: ${DEFAULT_REALITY_DEST}): " input
        input="${input:-$DEFAULT_REALITY_DEST}"
        input="${input#*://}"
        input="${input%%/*}"
        input="${input%%:*}"

        if reality_check_dest "$input"; then
            _dest="$input"
            log_success "${input} serves TLS 1.3 with HTTP/2"
            break
        fi

        log_warn "${input} did not answer with TLS 1.3 and HTTP/2"
        read -rp "Use it anyway? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && { _dest="$input"; break; }
    done
}

# TLS 1.3 and HTTP/2 show the dest answers like the site REALITY wants to borrow.
# Whether a client actually completes the borrowed handshake is a separate
# question, and only a real connection answers it - a dest that fails here drops
# clients before their uuid is read, and the client sees an EOF that reads like
# bad credentials.
#
# Returns 0 when a client made the round trip, 1 when it failed, and 2 when the
# check could not run. Reporting success for a check that never ran would be
# worse than saying nothing.
reality_verify_chain() {
    local config="${1:-$XRAY_CONFIG}"

    command -v curl &>/dev/null || return 2
    [[ -x "$XRAY_BIN" && -f "$config" ]] || return 2

    local port dest pub sid uuid
    port=$(jq -r '.xcp.reality.port // empty' "$config")
    dest=$(jq -r '.xcp.reality.dest // empty' "$config")
    pub=$(jq -r '.xcp.reality.publicKey // empty' "$config")
    sid=$(jq -r '.xcp.reality.shortId // empty' "$config")
    uuid=$(jq -r '[.inbounds[]? | select(.tag == "vless-in") | .settings.clients[0].id][0] // empty' "$config" 2>/dev/null)

    [[ -n "$port" && -n "$dest" && -n "$pub" && -n "$uuid" ]] || return 2
    port_taken "$REALITY_PROBE_PORT" && return 2

    # Xray picks the config format from the file extension, so the probe needs a
    # .json name - it refuses to start on a bare mktemp file
    local dir probe
    dir=$(mktemp -d)
    probe="${dir}/probe.json"

    jq -nc --arg uuid "$uuid" --arg dest "$dest" --arg pub "$pub" --arg sid "$sid" \
        --arg flow "$REALITY_FLOW" --argjson port "$port" \
        --argjson listen "$REALITY_PROBE_PORT" '{
            log: {loglevel: "none"},
            inbounds: [{tag: "probe", port: $listen, listen: "127.0.0.1",
                protocol: "http", settings: {}}],
            outbounds: [{
                protocol: "vless",
                settings: {vnext: [{address: "127.0.0.1", port: $port,
                    users: [{id: $uuid, encryption: "none", flow: $flow}]}]},
                streamSettings: {network: "tcp", security: "reality",
                    realitySettings: {serverName: $dest, fingerprint: "chrome",
                        publicKey: $pub, shortId: $sid, spiderX: "/"}}
            }]
        }' > "$probe"

    "$XRAY_BIN" run -c "$probe" &>/dev/null &
    local pid=$! rc=1 i

    # Wait for the probe to listen rather than guessing at a fixed delay
    for i in {1..10}; do
        (exec 3<>"/dev/tcp/127.0.0.1/${REALITY_PROBE_PORT}") 2>/dev/null && break
        sleep 1
    done

    # The answer has to be an address, not just a successful exit. curl reports
    # success for any HTTP response it receives, including the error page the
    # proxy returns when the outbound never connected - which would pass a
    # completely broken inbound.
    local answer
    answer=$(curl -s --max-time 10 -x "http://127.0.0.1:${REALITY_PROBE_PORT}" \
        "http://ip-api.com/line/?fields=query" 2>/dev/null || true)
    [[ "$answer" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && rc=0

    kill "$pid" &>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$dir"

    return "$rc"
}

# Report the handshake check, naming the dest as the thing to change
reality_report_chain() {
    local dest="$1" rc=0

    reality_verify_chain || rc=$?

    case "$rc" in
        0) log_success "REALITY handshake verified through ${dest}" ;;
        2) log_info "Skipped the REALITY handshake check" ;;
        *) log_warn "${dest} answers TLS, and a client still failed to finish the handshake"
           log_warn "Clients are dropped before authentication - pick another dest with '${SCRIPT_NAME} config dest'"
           log_warn "Known good: ${REALITY_DEST_ALTERNATIVES}"
           return 1 ;;
    esac
}

# Collect everything the REALITY inbound and its share URIs need, as one JSON
# object the config generators take verbatim
reality_settings() {
    local dest="$1" port="$2"
    local keys priv pub

    keys=$(reality_keys)
    priv="${keys%% *}"
    pub="${keys##* }"

    jq -nc --arg dest "$dest" --arg priv "$priv" --arg pub "$pub" \
        --arg sid "$(generate_shortid)" --argjson port "$port" \
        '{port: $port, dest: $dest, privateKey: $priv, publicKey: $pub, shortId: $sid}'
}

# --- SSH access (gateway side) ---

# Ensure sshd is installed and running (the gateway must accept the tunnel)
check_ssh_server() {
    if [[ ! -x /usr/sbin/sshd ]] && ! command -v sshd &>/dev/null; then
        log_info "Installing openssh-server..."
        apt-get install -y -qq openssh-server 2>/dev/null || true
    fi

    if ! systemctl is-active ssh &>/dev/null && ! systemctl is-active sshd &>/dev/null; then
        log_warn "sshd is not running - EDGE servers will not be able to link here"
        return 1
    fi

    return 0
}

# Read the local sshd listen port (falls back to 22)
get_ssh_port() {
    local port
    port=$(grep -m1 -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || true)
    validate_port "${port:-x}" && echo "$port" || echo "$DEFAULT_SSH_PORT"
}

# Reload sshd under whichever unit name the distro uses
reload_sshd() {
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

# Create the dedicated tunnel user on the gateway.
# Shell-less and forward-only: it can open the tunnel and nothing else, so the
# edge never needs root SSH (many providers disable it anyway).
gateway_ssh_user() {
    local pass="$1"
    local shell="/usr/sbin/nologin"

    [[ -x "$shell" ]] || shell="/bin/false"

    if id -u "$TUNNEL_SSH_USER" &>/dev/null; then
        log_info "SSH user '${TUNNEL_SSH_USER}' already exists"
    else
        useradd --create-home --shell "$shell" "$TUNNEL_SSH_USER" 2>/dev/null || \
            log_error "Failed to create SSH user '${TUNNEL_SSH_USER}'"
        log_success "SSH user '${TUNNEL_SSH_USER}' created"
    fi

    echo "${TUNNEL_SSH_USER}:${pass}" | chpasswd || log_error "Failed to set SSH password"

    sshd_allow_tunnel_user
}

# Allow password login for the tunnel user only, restricted to the tunnel port.
# Appended at the end of sshd_config so the Match block overrides any global
# 'PasswordAuthentication no' (cloud images ship with that) without touching it.
sshd_allow_tunnel_user() {
    local config="/etc/ssh/sshd_config"
    local start="# --- xray-chain-proxy tunnel (managed) ---"
    local end="# --- end xray-chain-proxy tunnel ---"

    [[ -f "$config" ]] || { log_warn "sshd_config not found - configure SSH access manually"; return 1; }

    cp "$config" "${config}.xcp.bak"
    sed -i "/^${start}$/,/^${end}$/d" "$config"

    cat >> "$config" << EOF
${start}
Match User ${TUNNEL_SSH_USER}
    PasswordAuthentication yes
    KbdInteractiveAuthentication no
    PubkeyAuthentication no
    AllowTcpForwarding yes
    PermitOpen 127.0.0.1:${TUNNEL_PORT}
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
${end}
EOF

    if ! sshd -t 2>/dev/null; then
        mv "${config}.xcp.bak" "$config"
        log_error "sshd config test failed - reverted"
    fi

    rm -f "${config}.xcp.bak"
    reload_sshd
    log_success "sshd accepts tunnel logins from '${TUNNEL_SSH_USER}'"
}

# Remove the tunnel user and its sshd exception (gateway uninstall)
gateway_ssh_user_purge() {
    local config="/etc/ssh/sshd_config"
    local start="# --- xray-chain-proxy tunnel (managed) ---"
    local end="# --- end xray-chain-proxy tunnel ---"

    if [[ -f "$config" ]] && grep -qF "$start" "$config"; then
        sed -i "/^${start}$/,/^${end}$/d" "$config"
        sshd -t 2>/dev/null && reload_sshd
    fi

    id -u "$TUNNEL_SSH_USER" &>/dev/null && userdel -r "$TUNNEL_SSH_USER" 2>/dev/null || true
}

# --- SSH tunnel (edge side) ---

# Ensure the SSH client and sshpass are available (the tunnel logs in with a password)
check_ssh_client() {
    if ! command -v ssh &>/dev/null; then
        log_info "Installing openssh-client..."
        apt-get install -y -qq openssh-client 2>/dev/null || true
    fi
    command -v ssh &>/dev/null || log_error "ssh client is required for the chain link"

    if ! command -v sshpass &>/dev/null; then
        log_info "Installing sshpass..."
        apt-get install -y -qq sshpass 2>/dev/null || true
    fi
    command -v sshpass &>/dev/null || log_error "sshpass is required for password login"
}

# AES-GCM runs on the CPU's AES instructions where they exist and beats
# chacha20 there; without them chacha20 is the faster of the two. Choosing
# explicitly keeps a cheap VPS off the slow side of that trade.
ssh_cipher() {
    if grep -qiE '^(flags|features)[[:space:]]*:.*[[:space:]]aes([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
        echo "aes128-gcm@openssh.com"
    else
        echo "chacha20-poly1305@openssh.com"
    fi
}

# Shared SSH options (password auth only - no keys, no agent).
# IPQoS=none leaves the DSCP field alone: OpenSSH otherwise marks packets af21
# or cs1, which is a distinctive signature and can land the tunnel in a
# differently shaped queue. Keepalives every 10s give up after 30s of silence,
# so a dead socket is noticed within half a minute.
ssh_opts() {
    echo "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${TUNNEL_KNOWN_HOSTS}" \
         "-o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1" \
         "-o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes" \
         "-o IPQoS=none -c $(ssh_cipher)"
}

# Store the tunnel password root-only, so it never shows up in ps or the unit file
tunnel_save_password() {
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$1" > "$TUNNEL_PASS_FILE"
    chmod 600 "$TUNNEL_PASS_FILE"
}

# Test password login to the gateway
tunnel_can_login() {
    local host="$1" port="$2" user="$3"
    # shellcheck disable=SC2046
    sshpass -f "$TUNNEL_PASS_FILE" ssh $(ssh_opts) -p "$port" -n "${user}@${host}" true &>/dev/null
}

# Install and start the tunnel service
tunnel_install() {
    local host="$1" port="$2" user="$3"
    local ssh_bin sshpass_bin

    ssh_bin=$(command -v ssh)
    sshpass_bin=$(command -v sshpass)

    # StartLimitIntervalSec=0 keeps systemd retrying forever. Without it the
    # unit gives up permanently after 5 starts in 10s, and ssh exits instantly
    # on a refused connection or a DNS failure - so a gateway that is briefly
    # unreachable at boot would leave a dead tunnel that never comes back.
    cat > "$TUNNEL_SERVICE" << EOF
[Unit]
Description=Xray Chain Proxy SSH Tunnel
Documentation=https://github.com/dalirnet/xray-chain-proxy
After=network-online.target
Wants=network-online.target
Before=xray.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=${sshpass_bin} -f ${TUNNEL_PASS_FILE} ${ssh_bin} -N -T $(ssh_opts) -o ExitOnForwardFailure=yes -p ${port} -L 127.0.0.1:${TUNNEL_PORT}:127.0.0.1:${TUNNEL_PORT} ${user}@${host}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-tunnel --quiet 2>/dev/null || true
    systemctl restart xray-tunnel
}

# Periodic end-to-end check of the tunnel.
# Keepalives only prove the socket is alive. A throttled link keeps answering
# them while carrying nothing, which is the failure mode that matters most on a
# shaped path - fetching through the tunnel is what catches it.
tunnel_health_install() {
    local self
    self=$(readlink -f "$0")

    cat > "$TUNNEL_HEALTH_SERVICE" << EOF
[Unit]
Description=Xray Chain Proxy Tunnel Health Check
Documentation=https://github.com/dalirnet/xray-chain-proxy
After=xray-tunnel.service

[Service]
Type=oneshot
User=root
ExecStart=${self} link health
EOF

    cat > "$TUNNEL_HEALTH_TIMER" << EOF
[Unit]
Description=Xray Chain Proxy Tunnel Health Check

[Timer]
OnBootSec=2min
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable xray-tunnel-health.timer --quiet 2>/dev/null || true
    systemctl restart xray-tunnel-health.timer

    log_success "Health check runs every 60s (${self})"
}

# Wait until the tunnel's local SOCKS port accepts connections
tunnel_wait() {
    local i
    for i in {1..15}; do
        (exec 3<>"/dev/tcp/127.0.0.1/${TUNNEL_PORT}") 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Confirm the far end is a gateway set up with this script: the forwarded port
# must answer as a SOCKS5 proxy and carry traffic out to the internet.
tunnel_verify_gateway() {
    curl -s --proxy "socks5://127.0.0.1:${TUNNEL_PORT}" --connect-timeout 10 --max-time 20 \
        -o /dev/null "http://ip-api.com/line/?fields=query" 2>/dev/null
}

# Full tunnel setup: password login, service, gateway check
tunnel_setup() {
    local host="$1" port="$2" user="$3" pass="$4"

    log_step "SSH Tunnel"

    check_ssh_client
    tunnel_save_password "$pass"

    tunnel_can_login "$host" "$port" "$user" || \
        log_error "SSH login to ${user}@${host}:${port} failed - check the user and password"
    log_success "Password login to ${user}@${host} works"

    tunnel_install "$host" "$port" "$user"

    tunnel_wait || log_error "Tunnel failed to start - check: journalctl -u xray-tunnel"
    log_success "Tunnel up on 127.0.0.1:${TUNNEL_PORT}"

    if tunnel_verify_gateway; then
        log_success "Gateway reachable through the tunnel"
    else
        log_error "No proxy behind the tunnel - run '${SCRIPT_NAME} setup gateway' on ${host} first"
    fi

    tunnel_health_install
}

# Remove the tunnel service and stored password
tunnel_purge() {
    systemctl stop xray-tunnel-health.timer 2>/dev/null || true
    systemctl disable xray-tunnel-health.timer --quiet 2>/dev/null || true
    systemctl stop xray-tunnel 2>/dev/null || true
    systemctl disable xray-tunnel --quiet 2>/dev/null || true
    rm -f "$TUNNEL_SERVICE" "$TUNNEL_HEALTH_SERVICE" "$TUNNEL_HEALTH_TIMER" \
          "$TUNNEL_HEALTH_STATE" "$TUNNEL_PASS_FILE" "$TUNNEL_KNOWN_HOSTS"
    systemctl daemon-reload 2>/dev/null || true
}

# --- Config generators ---

# jq helper: insert rules before the first built-in tail rule.
# Falls back to "before the last rule" for configs written by older versions.
readonly JQ_INSERT_RULES='
def insert_rules($new):
  (.routing.rules | map(.xcp_tail == true) | index(true)) as $i
  | if ($new | length) == 0 then .
    elif $i == null then .routing.rules = (.routing.rules[:-1] + $new + .routing.rules[-1:])
    else .routing.rules = (.routing.rules[:$i] + $new + .routing.rules[$i:])
    end;
'

# Generate GATEWAY configuration
# The VLESS inbound, or nothing when REALITY is unconfigured. Carries its own
# trailing comma so it can sit in front of the other client inbounds.
gen_vless_inbound() {
    local clients="$1" reality="$2"

    [[ -n "$reality" && "$reality" != "null" ]] || return 0

    local port=$(echo "$reality" | jq -r '.port')
    local dest=$(echo "$reality" | jq -r '.dest')
    local priv=$(echo "$reality" | jq -r '.privateKey')
    local sid=$(echo "$reality" | jq -r '.shortId')
    # Accounts predating REALITY have no id and stay on the other protocols
    local vless_clients=$(echo "$clients" | jq --arg f "$REALITY_FLOW" \
        '[.[] | select(.id) | {id: .id, email: .email, flow: $f}]')

    cat << EOF
    {
      "tag": "vless-in",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": ${vless_clients},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}:443",
          "xver": 0,
          "serverNames": ["${dest}"],
          "privateKey": "${priv}",
          "shortIds": ["${sid}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
EOF
}

# Everything a share URI needs, kept in the xcp block. The private key stays in
# realitySettings, where only the server reads it.
gen_reality_meta() {
    echo "${1:-null}" | jq -c 'if . == null then null else {port, dest, publicKey, shortId} end' 2>/dev/null || echo null
}

# Logging, stats API and per-user accounting. Identical on both roles, and
# emitted with its trailing comma so it drops straight into the object.
gen_observability() {
    cat << EOF
  "log": {
    "loglevel": "error",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
EOF
}

# The inbounds both roles share: the stats hook, the loopback resolver, and the
# client protocols. Closes the inbounds array, so the last entry carries no
# trailing comma and anything role-specific goes in front of it.
gen_common_inbounds() {
    local dns_ip="$1" ss_port="$2" ss_clients="$3" reality="$4"

    cat << EOF
    {
      "tag": "api",
      "port": ${API_PORT},
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "dns-in",
      "port": ${DEFAULT_DNS_PORT},
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "${dns_ip}",
        "port": ${DEFAULT_DNS_PORT},
        "network": "tcp,udp"
      }
    },
$(gen_vless_inbound "$ss_clients" "$reality")
    {
      "tag": "ss-in",
      "port": ${ss_port},
      "protocol": "shadowsocks",
      "settings": {
        "clients": ${ss_clients},
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "local-in",
      "port": ${LOCAL_SOCKS_PORT},
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
EOF
}

# Clients arrive over VLESS+REALITY or Shadowsocks, both of which authenticate
# without sending a credential in the clear. The only SOCKS5 here is no-auth on
# loopback, for diagnostics.
gen_gateway_config() {
    local ss_port="$1" ss_clients="$2" dns="${3:-$DEFAULT_DNS}" reality="${4:-}"
    local dns_ip=$(dns_ip "$dns")

    cat << EOF
{
  "xcp": {
    "type": "gateway",
    "version": "${VERSION}",
    "dns": "${dns}",
    "reality": $(gen_reality_meta "$reality")
  },
  "dns": {
    "servers": ["${dns}"],
    "queryStrategy": "UseIPv4"
  },
$(gen_observability)
  "inbounds": [
    {
      "tag": "tunnel-in",
      "port": ${TUNNEL_PORT},
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
$(gen_common_inbounds "$dns_ip" "$ss_port" "$ss_clients" "$reality")
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "dns-out",
      "protocol": "dns"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "inboundTag": ["dns-in"],
        "outboundTag": "dns-out"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
}

# Generate EDGE configuration
# The gateway is always reached through the SSH tunnel's local SOCKS port,
# so gw_host/gw_port/ssh_user are metadata only (used by 'link ls' and rebuilds).
gen_edge_config() {
    local ss_port="$1" ss_clients="$2" gw_host="$3" gw_port="$4" ssh_user="$5" dns="${6:-$DEFAULT_DNS}" reality="${7:-}"
    # The tunnel carries TCP only, so queries must not leave over UDP
    local dns_server=$(dns_over_tcp "$dns")
    local dns_ip=$(dns_ip "$dns")

    cat << EOF
{
  "xcp": {
    "type": "edge",
    "version": "${VERSION}",
    "dns": "${dns}",
    "reality": $(gen_reality_meta "$reality"),
    "link": {
      "protocol": "ssh",
      "host": "${gw_host}",
      "port": ${gw_port},
      "user": "${ssh_user}"
    }
  },
  "dns": {
    "servers": ["${dns_server}"],
    "queryStrategy": "UseIPv4"
  },
$(gen_observability)
  "inbounds": [
$(gen_common_inbounds "$dns_ip" "$ss_port" "$ss_clients" "$reality")
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${TUNNEL_PORT}
          }
        ]
      }
    },
    {
      "tag": "dns-out",
      "protocol": "dns",
      "settings": {
        "network": "tcp"
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "inboundTag": ["dns-in"],
        "outboundTag": "dns-out"
      },
      {
        "type": "field",
        "network": "udp",
        "port": ${DEFAULT_DNS_PORT},
        "outboundTag": "dns-out"
      },
      {
        "type": "field",
        "network": "udp",
        "outboundTag": "blocked",
        "xcp_tail": true
      },
      {
        "type": "field",
        "inboundTag": ["vless-in", "ss-in", "local-in"],
        "outboundTag": "proxy",
        "xcp_tail": true
      }
    ]
  }
}
EOF
}

# Generate Shadowsocks URI (SIP002 format)
gen_ss_uri() {
    local method="$1" pass="$2" server="$3" port="$4" name="$5"
    echo "ss://$(base64_urlsafe "${method}:${pass}")@${server}:${port}#${name:-Proxy}"
}

# Generate a VLESS + REALITY share URI.
# fp=chrome makes the client's TLS handshake match a real Chrome one, which is
# the half of the disguise the client owns; the server handles the other half.
gen_vless_uri() {
    local id="$1" server="$2" reality="$3" name="$4"

    [[ -n "$reality" && "$reality" != "null" && -n "$id" ]] || return 0

    local port=$(echo "$reality" | jq -r '.port')
    local sni=$(echo "$reality" | jq -r '.dest')
    local pbk=$(echo "$reality" | jq -r '.publicKey')
    local sid=$(echo "$reality" | jq -r '.shortId')

    echo "vless://${id}@${server}:${port}?encryption=none&security=reality&type=tcp&flow=${REALITY_FLOW}&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&spx=%2F#${name:-Proxy}"
}

# --- Setup ---

# Setup GATEWAY server
setup_gateway() {
    echo -e "\n${BOLD}GATEWAY Setup${NC} (Exit Node)\n"

    check_root
    check_systemd
    check_dependencies
    install_xray
    tune_network

    log_step "Configure Ports"

    local SS_PORT DNS_SERVER VLESS_PORT
    prompt_port "VLESS (REALITY) port" "$DEFAULT_VLESS_PORT" VLESS_PORT
    prompt_port "Shadowsocks port" "$DEFAULT_SS_PORT" SS_PORT
    prompt_dns "DNS resolver" "$DEFAULT_DNS" DNS_SERVER

    preflight_ports "$WEB_PORT" "$VLESS_PORT" "$SS_PORT" "$LOCAL_SOCKS_PORT" "$API_PORT" "$TUNNEL_PORT"

    log_step "REALITY"

    local REALITY_DEST REALITY
    prompt_reality_dest REALITY_DEST
    REALITY=$(reality_settings "$REALITY_DEST" "$VLESS_PORT")
    log_success "REALITY keys generated, borrowing ${REALITY_DEST}"

    log_step "SSH Access"

    check_ssh_server || log_error "sshd must be running for EDGE servers to link here"

    # The edge logs in as this user with this password - generated unless given
    local TUNNEL_PASS
    prompt_password "Tunnel SSH password" true TUNNEL_PASS 32
    gateway_ssh_user "$TUNNEL_PASS"

    # Create initial client account. One account works across every protocol:
    # the password authenticates Shadowsocks/HTTP/SOCKS5, the uuid VLESS.
    local USER_PASS=$(generate_password 16)
    local USER_UUID=$("$XRAY_BIN" uuid)
    local USER_CLIENT="[{\"email\":\"default\",\"password\":\"${USER_PASS}\",\"method\":\"${ENCRYPTION_METHOD}\",\"id\":\"${USER_UUID}\"}]"

    free_dns_port

    gen_gateway_config "$SS_PORT" "$USER_CLIENT" "$DNS_SERVER" "$REALITY" > "$XRAY_CONFIG"
    validate_config
    # DNS, the diagnostics SOCKS and the tunnel landing stay on loopback
    configure_firewall "$WEB_PORT" "$VLESS_PORT" "$SS_PORT" "${SS_PORT}/udp"
    web_install

    systemctl restart xray
    sleep 2
    systemctl is-active xray &>/dev/null || log_error "Xray failed to start"

    reality_report_chain "$REALITY_DEST" || true

    local IP=$(get_public_ip)
    local SSH_PORT=$(get_ssh_port)

    echo -e "\n${GREEN}GATEWAY Ready!${NC}"
    echo -e "\n${BOLD}Use on EDGE server (setup edge):${NC}"
    echo -e "  Gateway:    ${YELLOW}$IP${NC}"
    echo -e "  SSH Port:   ${YELLOW}$SSH_PORT${NC}"
    echo -e "  SSH User:   ${YELLOW}$TUNNEL_SSH_USER${NC}"
    echo -e "  SSH Pass:   ${YELLOW}$TUNNEL_PASS${NC}"
    echo -e "\n${BOLD}Direct client access:${NC}"
    echo -e "  VLESS Port: ${YELLOW}$VLESS_PORT${NC} (REALITY, borrowing ${REALITY_DEST})"
    echo -e "  SS Port:    ${YELLOW}$SS_PORT${NC}"
    echo -e "  Username:   ${YELLOW}default${NC}"
    echo -e "  Password:   ${YELLOW}$USER_PASS${NC}"
    echo -e "\n${BOLD}Loopback only (127.0.0.1):${NC}"
    echo -e "  SOCKS Port: ${YELLOW}$LOCAL_SOCKS_PORT${NC} (diagnostics)"
    echo -e "  DNS Port:   ${YELLOW}$DEFAULT_DNS_PORT${NC} (${DNS_SERVER})"
    echo -e "\nRun '${SCRIPT_NAME} user ls' for the share URIs and QR codes.\n"
}

# Setup EDGE server
setup_edge() {
    echo -e "\n${BOLD}EDGE Setup${NC} (Entry Node)\n"

    check_root
    check_systemd
    check_dependencies
    install_xray
    tune_network

    log_step "Gateway Details"

    local GW_HOST GW_PORT GW_USER GW_PASS
    prompt_address "Gateway host" GW_HOST
    prompt_port "Gateway SSH port" "$DEFAULT_SSH_PORT" GW_PORT
    read -rp "Gateway SSH user (default: $TUNNEL_SSH_USER): " GW_USER
    GW_USER="${GW_USER:-$TUNNEL_SSH_USER}"
    prompt_password "Gateway SSH password" false GW_PASS

    log_step "Edge Settings"

    local SS_PORT DNS_SERVER VLESS_PORT
    prompt_port "VLESS (REALITY) port" "$DEFAULT_VLESS_PORT" VLESS_PORT
    prompt_port "Shadowsocks port" "$DEFAULT_SS_PORT" SS_PORT
    prompt_dns "DNS resolver" "$DEFAULT_DNS" DNS_SERVER

    preflight_ports "$WEB_PORT" "$VLESS_PORT" "$SS_PORT" "$LOCAL_SOCKS_PORT" "$API_PORT" "$TUNNEL_PORT"

    log_step "REALITY"

    local REALITY_DEST REALITY
    prompt_reality_dest REALITY_DEST
    REALITY=$(reality_settings "$REALITY_DEST" "$VLESS_PORT")
    log_success "REALITY keys generated, borrowing ${REALITY_DEST}"

    tunnel_setup "$GW_HOST" "$GW_PORT" "$GW_USER" "$GW_PASS"

    # Create initial client account. One account works across every protocol:
    # the password authenticates Shadowsocks/HTTP/SOCKS5, the uuid VLESS.
    local USER_PASS=$(generate_password 16)
    local USER_UUID=$("$XRAY_BIN" uuid)
    local USER_CLIENT="[{\"email\":\"default\",\"password\":\"${USER_PASS}\",\"method\":\"${ENCRYPTION_METHOD}\",\"id\":\"${USER_UUID}\"}]"

    free_dns_port

    gen_edge_config "$SS_PORT" "$USER_CLIENT" "$GW_HOST" "$GW_PORT" "$GW_USER" "$DNS_SERVER" "$REALITY" > "$XRAY_CONFIG"
    validate_config
    # DNS and the diagnostics SOCKS stay on loopback
    configure_firewall "$WEB_PORT" "$VLESS_PORT" "$SS_PORT" "${SS_PORT}/udp"
    web_install

    systemctl restart xray
    sleep 2
    systemctl is-active xray &>/dev/null || log_error "Xray failed to start"

    reality_report_chain "$REALITY_DEST" || true

    local IP=$(get_public_ip)

    echo -e "\n${GREEN}EDGE Ready!${NC}"
    echo -e "\n${BOLD}Chain:${NC} Client -> $IP -> ssh://$GW_HOST:$GW_PORT -> Internet"
    echo -e "\n${BOLD}Connection Details:${NC}"
    echo -e "  IP:         ${YELLOW}$IP${NC}"
    echo -e "  VLESS Port: ${YELLOW}$VLESS_PORT${NC} (REALITY, borrowing ${REALITY_DEST})"
    echo -e "  SS Port:    ${YELLOW}$SS_PORT${NC}"
    echo -e "  Username:   ${YELLOW}default${NC}"
    echo -e "  Password:   ${YELLOW}$USER_PASS${NC}"
    echo -e "\n  DNS:        ${YELLOW}${DNS_SERVER}${NC} (loopback ${DEFAULT_DNS_PORT})"
    echo -e "\nRun '${SCRIPT_NAME} user ls' for the share URIs and QR codes.\n"
}

# Setup command router
setup_cmd() {
    case "${1:-}" in
        gateway) setup_gateway ;;
        edge)    setup_edge ;;
        *)       echo -e "\nUsage: $SCRIPT_NAME setup <gateway|edge>\n" ;;
    esac
}

# --- Users ---

# List all users
user_ls() {
    require_accounts

    local IP=$(get_public_ip)
    local SS_PORT=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local REALITY=$(jq -c '.xcp.reality // null' "$XRAY_CONFIG")
    local clients=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .settings.clients[] | "\(.email)|\(.password)|\(.id // "")"' "$XRAY_CONFIG" 2>/dev/null)

    echo -e "\n${BOLD}Server:${NC} $IP"
    if [[ "$REALITY" != "null" ]]; then
        echo -e "${BOLD}VLESS:${NC} $(echo "$REALITY" | jq -r '.port') (REALITY → $(echo "$REALITY" | jq -r '.dest'))"
    fi
    echo -e "${BOLD}Shadowsocks:${NC} ${SS_PORT}"
    echo -e "\n${BOLD}Accounts:${NC}\n"

    if [[ -z "$clients" ]]; then
        echo "  No accounts"
    else
        local i=1
        while IFS='|' read -r email pass id; do
            local uri=$(gen_ss_uri "$ENCRYPTION_METHOD" "$pass" "$IP" "$SS_PORT" "$email")
            echo -e "${CYAN}$i) $email${NC}"
            echo -e "   Password: ${YELLOW}$pass${NC}"
            echo "   SS URI: $uri"

            local vless_uri=$(gen_vless_uri "$id" "$IP" "$REALITY" "$email")
            [[ -n "$vless_uri" ]] && echo "   VLESS URI: $vless_uri"

            echo
            i=$((i + 1))
        done <<< "$clients"
    fi
}

# Add new user
user_add() {
    check_root
    require_accounts

    local EMAIL PASS
    read -rp "Username: " EMAIL
    [[ -z "$EMAIL" ]] && log_error "Username required"
    jq -e --arg e "$EMAIL" '.inbounds[] | select(.tag == "ss-in") | .settings.clients[] | select(.email == $e)' "$XRAY_CONFIG" &>/dev/null && log_error "Account exists"

    prompt_password "Password" "true" PASS

    local SS_PORT=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local REALITY=$(jq -c '.xcp.reality // null' "$XRAY_CONFIG")
    local UUID=$("$XRAY_BIN" uuid)

    # One account, both protocols: the password authenticates Shadowsocks and
    # the uuid authenticates VLESS. The uuid is stored on the ss-in client so a
    # single record stays the source of truth.
    jq --arg e "$EMAIL" --arg p "$PASS" --arg m "$ENCRYPTION_METHOD" \
        --arg id "$UUID" --arg f "$REALITY_FLOW" \
        '.inbounds |= map(
            if .tag == "ss-in" then .settings.clients += [{"email":$e,"password":$p,"method":$m,"id":$id}]
            elif .tag == "vless-in" then .settings.clients += [{"id":$id,"email":$e,"flow":$f}]
            else . end
        )' \
        "$XRAY_CONFIG" | config_write

    apply_config
    sleep 1

    local IP=$(get_public_ip)
    local URI=$(gen_ss_uri "$ENCRYPTION_METHOD" "$PASS" "$IP" "$SS_PORT" "$EMAIL")
    local VLESS_URI=$(gen_vless_uri "$UUID" "$IP" "$REALITY" "$EMAIL")

    echo -e "\n${GREEN}Account '$EMAIL' Added${NC}"
    echo -e "  IP:         ${YELLOW}$IP${NC}"
    [[ -n "$VLESS_URI" ]] && \
        echo -e "  VLESS Port: ${YELLOW}$(echo "$REALITY" | jq -r '.port')${NC}"
    echo -e "  SS Port:    ${YELLOW}$SS_PORT${NC}"
    echo -e "  Username:   ${YELLOW}$EMAIL${NC}"
    echo -e "  Password:   ${YELLOW}$PASS${NC}\n"

    # VLESS carries UDP and resists probing, so it leads and gets the QR code
    if [[ -n "$VLESS_URI" ]]; then
        command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$VLESS_URI"
        echo "VLESS URI: $VLESS_URI"
        echo
    else
        command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$URI"
    fi

    echo "SS URI: $URI"
}

# Remove user
user_rm() {
    check_root
    require_accounts

    local EMAIL
    read -rp "Username to remove: " EMAIL
    [[ -z "$EMAIL" ]] && log_error "Username required"
    jq -e --arg e "$EMAIL" '.inbounds[] | select(.tag == "ss-in") | .settings.clients[] | select(.email == $e)' "$XRAY_CONFIG" &>/dev/null || log_error "Account not found"


    jq --arg e "$EMAIL" \
        '.inbounds |= map(
            if .tag == "ss-in" or .tag == "vless-in" then .settings.clients |= map(select(.email != $e))
            else . end
        )' \
        "$XRAY_CONFIG" | config_write

    apply_config

    log_success "Account '$EMAIL' removed"
}

# User command router
user_cmd() {
    case "${1:-}" in
        ls)   user_ls ;;
        add)  user_add ;;
        rm)   user_rm ;;
        *)    echo -e "\nUsage: $SCRIPT_NAME user <ls|add|rm>\n" ;;
    esac
}

# --- Service control ---

# Start Xray service (and the SSH tunnel, if configured)
service_start() {
    check_root
    require_xray
    [[ -f "$TUNNEL_SERVICE" ]] && systemctl start xray-tunnel 2>/dev/null || true
    systemctl start xray
    log_success "Xray started"
}

# Stop Xray service (and the SSH tunnel, if configured)
service_stop() {
    check_root
    systemctl stop xray 2>/dev/null || true
    [[ -f "$TUNNEL_SERVICE" ]] && systemctl stop xray-tunnel 2>/dev/null || true
    log_success "Xray stopped"
}

# Restart Xray service (and the SSH tunnel, if configured)
service_restart() {
    check_root
    require_xray
    [[ -f "$TUNNEL_SERVICE" ]] && systemctl restart xray-tunnel 2>/dev/null || true
    systemctl restart xray
    log_success "Xray restarted"
}

# --- Config ---

# Show current config
config_ls() {
    require_config

    local type=$(jq -r '.xcp.type // "unknown"' "$XRAY_CONFIG")
    local version=$(jq -r '.xcp.version // "unknown"' "$XRAY_CONFIG")
    local ss_port=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local dns=$(jq -r ".xcp.dns // \"$DEFAULT_DNS\"" "$XRAY_CONFIG")
    local loglevel=$(jq -r '.log.loglevel // "warning"' "$XRAY_CONFIG")
    local reality=$(jq -c '.xcp.reality // null' "$XRAY_CONFIG")

    echo -e "\n${BOLD}Config:${NC}\n"
    echo -e "  Type:       ${YELLOW}$type${NC}"
    echo -e "  Version:    ${YELLOW}$version${NC}"
    if [[ "$reality" != "null" ]]; then
        echo -e "  VLESS Port: ${YELLOW}$(echo "$reality" | jq -r '.port')${NC}"
        echo -e "  REALITY:    ${YELLOW}$(echo "$reality" | jq -r '.dest')${NC}"
    fi
    echo -e "  SS Port:    ${YELLOW}$ss_port${NC}"
    echo -e "  SOCKS Port: ${YELLOW}$LOCAL_SOCKS_PORT${NC} ${CYAN}(loopback)${NC}"
    echo -e "  DNS Port:   ${YELLOW}$DEFAULT_DNS_PORT${NC} ${CYAN}(loopback)${NC}"
    echo -e "  DNS Server: ${YELLOW}$dns${NC}"
    echo -e "  Log level:  ${YELLOW}$loglevel${NC}"

    if [[ "$type" == "edge" ]]; then
        local gw_host=$(jq -r '.xcp.link.host // "unknown"' "$XRAY_CONFIG")
        local gw_port=$(jq -r '.xcp.link.port // 22' "$XRAY_CONFIG")
        local gw_user=$(jq -r ".xcp.link.user // \"$TUNNEL_SSH_USER\"" "$XRAY_CONFIG")
        echo -e "  Gateway:    ${YELLOW}ssh://${gw_user}@${gw_host}:${gw_port}${NC}"
    fi

    echo
}

# Set log level
config_loglevel() {
    check_root
    require_config

    local current=$(jq -r '.log.loglevel // "warning"' "$XRAY_CONFIG")
    echo -e "\n${BOLD}Log Level${NC}\n"
    echo -e "Current: ${YELLOW}$current${NC}\n"
    echo "Options:"
    echo "  none    - No logging"
    echo "  warning - Warnings and errors only"
    echo "  info    - General information"
    echo "  debug   - Detailed debug info"
    echo

    local LEVEL
    read -rp "New level (none/warning/info/debug): " LEVEL

    case "$LEVEL" in
        none|warning|info|debug) ;;
        *) log_error "Invalid level. Use: none, warning, info, debug" ;;
    esac


    if [[ "$LEVEL" == "none" ]]; then
        jq '.log.loglevel = "none" | .log.access = "none" | .log.error = "none"' "$XRAY_CONFIG" | config_write
    else
        jq --arg l "$LEVEL" --arg a "${LOG_DIR}/access.log" --arg e "${LOG_DIR}/error.log" \
            '.log.loglevel = $l | .log.access = $a | .log.error = $e' "$XRAY_CONFIG" | config_write
    fi

    apply_config

    log_success "Log level set to '$LEVEL'"
}

# Change listen port
config_port() {
    check_root
    require_config

    local ss_current=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local vless_current=$(jq -r '[.inbounds[] | select(.tag == "vless-in") | .port][0] // ""' "$XRAY_CONFIG")

    echo -e "\n${BOLD}Listen Ports${NC}\n"
    [[ -n "$vless_current" ]] && echo -e "Current: VLESS:${YELLOW}$vless_current${NC} | SS:${YELLOW}$ss_current${NC}\n"
    [[ -z "$vless_current" ]] && echo -e "Current: SS:${YELLOW}$ss_current${NC}\n"

    local SS_PORT VLESS_PORT="$vless_current"
    [[ -n "$vless_current" ]] && prompt_port "VLESS (REALITY) port" "$vless_current" VLESS_PORT
    prompt_port "Shadowsocks port" "$ss_current" SS_PORT

    if [[ "$SS_PORT" == "$ss_current" && "$VLESS_PORT" == "$vless_current" ]]; then
        log_info "Ports unchanged"
        return
    fi

    # The share URIs are rebuilt from xcp.reality, so its port moves too
    jq --argjson ss "$SS_PORT" --arg vless "$VLESS_PORT" \
        '(if $vless == "" then . else
            (.inbounds |= map(if .tag == "vless-in" then .port = ($vless | tonumber) else . end))
            | (if .xcp.reality then .xcp.reality.port = ($vless | tonumber) else . end)
          end)
         | .inbounds |= map(if .tag == "ss-in" then .port = $ss else . end)' \
        "$XRAY_CONFIG" | config_write

    # Open the new ports before loading the config that listens on them
    configure_firewall ${VLESS_PORT:+"$VLESS_PORT"} "$SS_PORT" "${SS_PORT}/udp"
    apply_config

    log_success "Ports updated: ${VLESS_PORT:+VLESS:$VLESS_PORT }SS:$SS_PORT"
}

# Change the DNS resolver this server answers with
config_dns() {
    check_root
    require_config

    local type=$(jq -r '.xcp.type // "unknown"' "$XRAY_CONFIG")
    local current=$(jq -r ".xcp.dns // \"$DEFAULT_DNS\"" "$XRAY_CONFIG")

    echo -e "\n${BOLD}DNS Resolver${NC}\n"
    echo -e "Current: ${YELLOW}${current}${NC}\n"
    echo "  1) 1.1.1.1                          - Cloudflare"
    echo "  2) 8.8.8.8                          - Google"
    echo "  3) 9.9.9.9                          - Quad9"
    echo "  4) https://dns.google/dns-query     - Google DoH"
    echo "  5) https://cloudflare-dns.com/dns-query - Cloudflare DoH"
    echo "  6) custom"
    echo

    local choice DNS_SERVER
    read -rp "Select resolver (1-6): " choice

    case "$choice" in
        1) DNS_SERVER="1.1.1.1" ;;
        2) DNS_SERVER="8.8.8.8" ;;
        3) DNS_SERVER="9.9.9.9" ;;
        4) DNS_SERVER="https://dns.google/dns-query" ;;
        5) DNS_SERVER="https://cloudflare-dns.com/dns-query" ;;
        6) prompt_dns "Resolver" "$current" DNS_SERVER ;;
        *) log_error "Invalid option" ;;
    esac

    # Edges resolve over TCP - the SSH tunnel carries no UDP
    local server="$DNS_SERVER"
    [[ "$type" == "edge" ]] && server=$(dns_over_tcp "$DNS_SERVER")

    jq --arg dns "$DNS_SERVER" --arg server "$server" --arg ip "$(dns_ip "$DNS_SERVER")" \
        '.xcp.dns = $dns
         | .dns.servers = [$server]
         | .inbounds |= map(if .tag == "dns-in" then .settings.address = $ip else . end)' \
        "$XRAY_CONFIG" | config_write

    apply_config

    log_success "DNS resolver set to $DNS_SERVER"
}

# Change the site REALITY borrows its handshake from. The SNI in every share URI
# is this name, so the URIs are reissued and clients have to reimport them.
config_dest() {
    check_root
    require_config

    local current=$(jq -r '.xcp.reality.dest // empty' "$XRAY_CONFIG")
    [[ -n "$current" ]] || log_error "No REALITY inbound in the config"

    echo -e "\n${BOLD}REALITY Dest${NC}\n"
    echo -e "Current: ${YELLOW}${current}${NC}\n"

    local DEST
    prompt_reality_dest DEST

    jq --arg dest "$DEST" --arg target "${DEST}:443" \
        '.xcp.reality.dest = $dest
         | .inbounds |= map(if .tag == "vless-in"
             then .streamSettings.realitySettings.dest = $target
                | .streamSettings.realitySettings.serverNames = [$dest]
             else . end)' \
        "$XRAY_CONFIG" | config_write

    apply_config

    reality_report_chain "$DEST" || true

    log_success "REALITY dest set to ${DEST}"
    log_warn "The share URIs changed - run '${SCRIPT_NAME} user ls' and reimport them"
}

# Config set submenu
config_set() {
    echo -e "\n${BOLD}Set Config:${NC}\n"
    echo "  1) loglevel - Set log level"
    echo "  2) port     - Change listen port"
    echo "  3) dns      - Change DNS resolver"
    echo "  4) dest     - Change REALITY dest"
    echo

    local choice
    read -rp "Select option (1-4): " choice

    case "$choice" in
        1|loglevel) config_loglevel ;;
        2|port)     config_port ;;
        3|dns)      config_dns ;;
        4|dest)     config_dest ;;
        *)          log_error "Invalid option" ;;
    esac
}

# Config command router
config_cmd() {
    case "${1:-}" in
        ls)       config_ls ;;
        set)      config_set ;;
        loglevel) config_loglevel ;;
        port)     config_port ;;
        dns)      config_dns ;;
        dest)     config_dest ;;
        *)        echo -e "\nUsage: $SCRIPT_NAME config <ls|set|loglevel|port|dns|dest>\n" ;;
    esac
}

# --- DNS access ---
#
# By default the resolver answers on 127.0.0.1 only, which serves the chain and
# keeps the server off the open-resolver abuse lists. Allowing a client binds it
# to 0.0.0.0 and lets the firewall decide who reaches it.
#
# A source filter holds up against spoofing here: amplification works by putting
# the victim's address in the source field, and a packet claiming to come from
# an address that is not on the list gets dropped before anything is sent. The
# only reflection target left is an address already on the list - which is your
# own client, not an arbitrary victim.

# The firewall is what actually enforces the list, so an inactive one means the
# resolver stays on loopback no matter what the config says.
dns_apply_access() {
    local config="${1:-$XRAY_CONFIG}"
    local allow count listen="127.0.0.1"

    [[ -f "$config" ]] || return 0

    allow=$(jq -c '.xcp.dns_allow // []' "$config")
    count=$(echo "$allow" | jq 'length')

    if [[ "$count" -gt 0 ]]; then
        if firewall_active; then
            listen="0.0.0.0"
        else
            log_warn "ufw is not active - the resolver stays on loopback until it is"
        fi
    fi

    jq --arg l "$listen" '.inbounds |= map(if .tag == "dns-in" then .listen = $l else . end)' \
        "$config" | config_write "$config"
}

# Add or remove the port-53 rules for one source
dns_firewall_rule() {
    local action="$1" source="$2"

    firewall_active || return 0

    if [[ "$action" == "add" ]]; then
        ufw allow from "$source" to any port "$DEFAULT_DNS_PORT" proto udp &>/dev/null || true
        ufw allow from "$source" to any port "$DEFAULT_DNS_PORT" proto tcp &>/dev/null || true
    else
        ufw --force delete allow from "$source" to any port "$DEFAULT_DNS_PORT" proto udp &>/dev/null || true
        ufw --force delete allow from "$source" to any port "$DEFAULT_DNS_PORT" proto tcp &>/dev/null || true
    fi
}

# List the clients allowed to use this server as a resolver
dns_ls() {
    require_config

    local resolver=$(jq -r ".xcp.dns // \"$DEFAULT_DNS\"" "$XRAY_CONFIG")
    local listen=$(jq -r '[.inbounds[] | select(.tag == "dns-in") | .listen][0] // "127.0.0.1"' "$XRAY_CONFIG")
    local allow=$(jq -r '.xcp.dns_allow // [] | .[]' "$XRAY_CONFIG")

    echo -e "\n${BOLD}DNS:${NC}\n"
    echo -e "  Resolver: ${YELLOW}${resolver}${NC}  (change with '${SCRIPT_NAME} config set')"

    if [[ "$listen" == "127.0.0.1" ]]; then
        echo -e "  Reachable: ${YELLOW}loopback only${NC}"
    else
        echo -e "  Reachable: ${YELLOW}${listen}:${DEFAULT_DNS_PORT}${NC}, allowed sources only"
    fi

    # `ufw status` needs root, so without it the answer would be a guess
    if [[ $EUID -eq 0 ]] && ! firewall_active; then
        echo -e "  ${YELLOW}ufw is not active - the list is not enforced${NC}"
    fi

    echo -e "\n${BOLD}Allowed:${NC}\n"

    if [[ -z "$allow" ]]; then
        echo "  No clients - the resolver serves this server only"
    else
        local i=1
        while read -r entry; do
            echo -e "  ${CYAN}$i)${NC} $entry"
            i=$((i + 1))
        done <<< "$allow"
    fi

    echo
}

# Allow a client to use this server as a resolver
dns_add() {
    check_root
    require_config

    local SOURCE="${1:-}"
    [[ -z "$SOURCE" ]] && read -rp "Client IP or CIDR: " SOURCE
    validate_cidr "$SOURCE" || log_error "Invalid IP or CIDR - use 1.2.3.4 or 1.2.3.0/24"

    # A prefix this broad is an open resolver wearing a list, which is the one
    # outcome this whole mechanism exists to avoid
    if [[ "$SOURCE" == */* ]] && [[ "${SOURCE#*/}" -lt 8 ]]; then
        log_warn "/${SOURCE#*/} covers $(( 2 ** (32 - ${SOURCE#*/}) )) addresses - that is close to an open resolver"
        local ans
        read -rp "Add it anyway? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || log_error "Cancelled"
    fi

    jq -e --arg s "$SOURCE" '.xcp.dns_allow // [] | index($s)' "$XRAY_CONFIG" &>/dev/null && \
        log_error "'${SOURCE}' is already allowed"

    firewall_active || log_warn "ufw is not active - enable it with 'ufw enable' before relying on this"

    jq --arg s "$SOURCE" '.xcp.dns_allow = ((.xcp.dns_allow // []) + [$s])' \
        "$XRAY_CONFIG" | config_write

    dns_firewall_rule add "$SOURCE"
    dns_apply_access

    apply_config

    log_success "'${SOURCE}' may now use this server for DNS"
}

# Revoke a client's access to the resolver
dns_rm() {
    check_root
    require_config

    local SOURCE="${1:-}"
    [[ -z "$SOURCE" ]] && read -rp "Client IP or CIDR to remove: " SOURCE
    [[ -z "$SOURCE" ]] && log_error "IP or CIDR required"

    jq -e --arg s "$SOURCE" '.xcp.dns_allow // [] | index($s)' "$XRAY_CONFIG" &>/dev/null || \
        log_error "'${SOURCE}' is not on the list"

    jq --arg s "$SOURCE" '.xcp.dns_allow = ((.xcp.dns_allow // []) | map(select(. != $s)))' \
        "$XRAY_CONFIG" | config_write

    dns_firewall_rule delete "$SOURCE"
    dns_apply_access

    apply_config

    log_success "'${SOURCE}' can no longer use this server for DNS"
}

# DNS command router
dns_cmd() {
    case "${1:-}" in
        ls)  dns_ls ;;
        add) dns_add "${2:-}" ;;
        rm)  dns_rm "${2:-}" ;;
        *)   echo -e "\nUsage: $SCRIPT_NAME dns <ls|add|rm> [ip|cidr]\n" ;;
    esac
}

# --- Routing rules ---

# List routing rules
rule_ls() {
    require_config

    local type=$(jq -r '.xcp.type // "unknown"' "$XRAY_CONFIG")

    # Get custom rules (skip built-in API and private IP rules)
    local rules=$(jq -r '.routing.rules[] | select(.xcp_custom == true)' "$XRAY_CONFIG" 2>/dev/null)

    echo -e "\n${BOLD}Routing Rules (${type}):${NC}\n"

    if [[ -z "$rules" || "$rules" == "null" ]]; then
        echo "  No custom rules configured"
        echo
        return
    fi

    local count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$XRAY_CONFIG")
    local i=1

    jq -c '.routing.rules[] | select(.xcp_custom == true)' "$XRAY_CONFIG" | while IFS= read -r rule; do
        local outbound=$(echo "$rule" | jq -r '.outboundTag // "unknown"')
        local domain=$(echo "$rule" | jq -r '.domain // [] | join(", ")')
        local ip=$(echo "$rule" | jq -r '.ip // [] | join(", ")')

        echo -e "${CYAN}$i)${NC} → ${YELLOW}$outbound${NC}"
        [[ -n "$domain" && "$domain" != "" ]] && echo "   Domain: $domain"
        [[ -n "$ip" && "$ip" != "" ]] && echo "   IP: $ip"
        echo
        i=$((i + 1))
    done
}

# Add routing rule
rule_add() {
    check_root
    require_config

    local type=$(jq -r '.xcp.type // "unknown"' "$XRAY_CONFIG")

    echo -e "\n${BOLD}Add Routing Rule${NC}\n"

    # Show available outbound tags
    echo -e "${BOLD}Available outbounds:${NC}"
    if [[ "$type" == "gateway" ]]; then
        echo "  direct  - Direct connection"
        echo "  blocked - Block traffic"
    elif [[ "$type" == "edge" ]]; then
        echo "  proxy   - Through the gateway"
        echo "  direct  - Direct connection (bypass the gateway)"
        echo "  blocked - Block traffic"
    else
        log_error "Unknown server type"
    fi
    echo

    # Get outbound tag
    local OUTBOUND
    while true; do
        read -rp "Outbound tag: " OUTBOUND
        if [[ "$type" == "gateway" && ("$OUTBOUND" == "direct" || "$OUTBOUND" == "blocked") ]]; then
            break
        elif [[ "$type" == "edge" && ("$OUTBOUND" == "proxy" || "$OUTBOUND" == "direct" || "$OUTBOUND" == "blocked") ]]; then
            break
        else
            echo -e "${RED}Invalid outbound for $type server${NC}"
        fi
    done

    # Get rule type
    echo -e "\n${BOLD}Rule type:${NC}"
    echo "  1) Domain (e.g., google.com, domain:netflix.com, geosite:cn)"
    echo "  2) IP/CIDR (e.g., 8.8.8.8, 1.1.1.0/24, geoip:us)"
    echo

    local RULE_TYPE
    read -rp "Select type (1-2): " RULE_TYPE

    local RULE_VALUE DOMAIN_ARR IP_ARR
    case "$RULE_TYPE" in
        1)
            read -rp "Domain(s) [comma-separated]: " RULE_VALUE
            [[ -z "$RULE_VALUE" ]] && log_error "Domain required"
            # Convert comma-separated to JSON array
            DOMAIN_ARR=$(echo "$RULE_VALUE" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";""))')
            ;;
        2)
            read -rp "IP/CIDR(s) [comma-separated]: " RULE_VALUE
            [[ -z "$RULE_VALUE" ]] && log_error "IP required"
            # Convert comma-separated to JSON array
            IP_ARR=$(echo "$RULE_VALUE" | jq -R 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";""))')
            ;;
        *)
            log_error "Invalid type"
            ;;
    esac

    # Build the new rule
    local NEW_RULE
    if [[ "$RULE_TYPE" == "1" ]]; then
        NEW_RULE=$(jq -n --arg tag "$OUTBOUND" --argjson domains "$DOMAIN_ARR" \
            '{type: "field", domain: $domains, outboundTag: $tag, xcp_custom: true}')
    else
        NEW_RULE=$(jq -n --arg tag "$OUTBOUND" --argjson ips "$IP_ARR" \
            '{type: "field", ip: $ips, outboundTag: $tag, xcp_custom: true}')
    fi

    # Insert custom rule after API rule(s) but before catch-all rules
    # For gateway: after API and private IP rules
    # For edge: after API rule, before the UDP/client catch-all rules
    if [[ "$type" == "gateway" ]]; then
        # Gateway: append after all built-in rules (API, private IP)
        jq --argjson newrule "$NEW_RULE" \
            '.routing.rules += [$newrule]' \
            "$XRAY_CONFIG" | config_write
    elif [[ "$type" == "edge" ]]; then
        # Edge: insert before the built-in tail rules
        jq --argjson newrule "$NEW_RULE" \
            "$JQ_INSERT_RULES insert_rules([\$newrule])" \
            "$XRAY_CONFIG" | config_write
    else
        log_error "Unknown server type"
    fi

    apply_config

    log_success "Rule added: $RULE_VALUE → $OUTBOUND"
}

# Remove routing rule
rule_rm() {
    check_root
    require_config

    # Check if there are custom rules
    local count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$XRAY_CONFIG")

    if [[ "$count" -eq 0 ]]; then
        log_error "No custom rules to remove"
    fi

    # Show current rules
    rule_ls

    local INDEX
    read -rp "Rule number to remove (1-$count): " INDEX

    if [[ ! "$INDEX" =~ ^[0-9]+$ ]] || [[ "$INDEX" -lt 1 ]] || [[ "$INDEX" -gt "$count" ]]; then
        log_error "Invalid rule number"
    fi

    # Remove the INDEX-th custom rule while preserving order
    jq --argjson idx "$((INDEX - 1))" '
        .routing.rules |= (
            reduce .[] as $rule (
                {result: [], custom_count: 0};
                if $rule.xcp_custom == true then
                    if .custom_count == $idx then
                        {result: .result, custom_count: (.custom_count + 1)}
                    else
                        {result: (.result + [$rule]), custom_count: (.custom_count + 1)}
                    end
                else
                    {result: (.result + [$rule]), custom_count: .custom_count}
                end
            ) | .result
        )
    ' "$XRAY_CONFIG" | config_write

    apply_config

    log_success "Rule #$INDEX removed"
}

# Rule command router
rule_cmd() {
    case "${1:-}" in
        ls)  rule_ls ;;
        add) rule_add ;;
        rm)  rule_rm ;;
        *)   echo -e "\nUsage: $SCRIPT_NAME rule <ls|add|rm>\n" ;;
    esac
}

# --- Gateway link ---

# Show the gateway SSH link
link_ls() {
    require_edge

    local host=$(jq -r '.xcp.link.host // "unknown"' "$XRAY_CONFIG")
    local port=$(jq -r '.xcp.link.port // 22' "$XRAY_CONFIG")
    local user=$(jq -r ".xcp.link.user // \"$TUNNEL_SSH_USER\"" "$XRAY_CONFIG")

    echo -e "\n${BOLD}Gateway Link:${NC}\n"
    echo -e "  Protocol:   ${YELLOW}ssh${NC}"
    echo -e "  Gateway:    ${YELLOW}${user}@${host}:${port}${NC}"
    echo -e "  Auth:       ${YELLOW}password${NC}"
    echo -e "  Forward:    ${YELLOW}127.0.0.1:${TUNNEL_PORT}${NC} (loopback only)"

    if systemctl is-active xray-tunnel &>/dev/null; then
        echo -e "  Tunnel:     ${GREEN}● Running${NC}"
    else
        echo -e "  Tunnel:     ${RED}● Stopped${NC}"
    fi

    echo
}

# Change the gateway SSH link (rebuilds config, keeps users and rules)
link_set() {
    check_root
    require_edge

    local cur_host=$(jq -r '.xcp.link.host // ""' "$XRAY_CONFIG")
    local cur_port=$(jq -r '.xcp.link.port // 22' "$XRAY_CONFIG")
    local cur_user=$(jq -r ".xcp.link.user // \"$TUNNEL_SSH_USER\"" "$XRAY_CONFIG")

    echo -e "\n${BOLD}Change Gateway${NC}\n"
    [[ -n "$cur_host" ]] && echo -e "Current: ${YELLOW}${cur_user}@${cur_host}:${cur_port}${NC}\n"

    local GW_HOST GW_PORT GW_USER GW_PASS
    prompt_address "Gateway host" GW_HOST
    prompt_port "Gateway SSH port" "$cur_port" GW_PORT
    read -rp "Gateway SSH user (default: $cur_user): " GW_USER
    GW_USER="${GW_USER:-$cur_user}"
    prompt_password "Gateway SSH password" false GW_PASS

    tunnel_setup "$GW_HOST" "$GW_PORT" "$GW_USER" "$GW_PASS"

    # Rebuild the config, carrying over users, ports, dns, log settings and custom rules
    local clients=$(jq -c '.inbounds[] | select(.tag == "ss-in") | .settings.clients' "$XRAY_CONFIG")
    local ss_port=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local dns=$(jq -r ".xcp.dns // \"$DEFAULT_DNS\"" "$XRAY_CONFIG")
    local custom=$(jq -c '[.routing.rules[] | select(.xcp_custom == true)]' "$XRAY_CONFIG")
    local logcfg=$(jq -c '.log' "$XRAY_CONFIG")
    local dns_allow=$(jq -c '.xcp.dns_allow // []' "$XRAY_CONFIG")

    # xcp.reality carries everything but the private key, which lives in the
    # inbound. Both halves are needed to rebuild the VLESS inbound unchanged,
    # so existing clients keep working after the gateway moves.
    local reality=$(jq -c '
        (.xcp.reality // null) as $meta
        | if $meta == null then null
          else $meta + {privateKey: ([.inbounds[]
              | select(.tag == "vless-in")
              | .streamSettings.realitySettings.privateKey][0] // "")}
          end' "$XRAY_CONFIG")

    local TMP=$(mktemp)
    gen_edge_config "$ss_port" "$clients" "$GW_HOST" "$GW_PORT" "$GW_USER" "$dns" "$reality" > "$TMP"

    jq --argjson custom "$custom" --argjson log "$logcfg" --argjson allow "$dns_allow" \
        "$JQ_INSERT_RULES .log = \$log | .xcp.dns_allow = \$allow | insert_rules(\$custom)" \
        "$TMP" | config_write
    rm -f "$TMP"

    # The generator always emits a loopback resolver, so re-apply the allowlist
    dns_apply_access

    apply_config

    log_success "Gateway set to ${GW_USER}@${GW_HOST}:${GW_PORT}"
}

# Restart the SSH tunnel
link_restart() {
    check_root
    require_tunnel

    systemctl restart xray-tunnel
    tunnel_wait || log_error "Tunnel failed to start - check: journalctl -u xray-tunnel"
    systemctl restart xray

    log_success "Tunnel restarted"
}

# Show tunnel logs
link_logs() {
    require_tunnel
    journalctl -u xray-tunnel -n "${1:-50}" --no-pager
}

# One health check, run by xray-tunnel-health.timer every 60s.
# A single slow fetch is not an outage, so the tunnel is only restarted after
# two consecutive failures - the counter lives in /run and clears on success.
link_health() {
    check_root
    require_tunnel

    local fails=0
    [[ -f "$TUNNEL_HEALTH_STATE" ]] && fails=$(cat "$TUNNEL_HEALTH_STATE" 2>/dev/null || echo 0)
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0

    if tunnel_verify_gateway; then
        rm -f "$TUNNEL_HEALTH_STATE"
        return 0
    fi

    fails=$((fails + 1))
    printf '%s\n' "$fails" > "$TUNNEL_HEALTH_STATE"

    if [[ "$fails" -ge 2 ]]; then
        log_warn "Tunnel carried nothing for ${fails} checks - restarting"
        systemctl restart xray-tunnel
        tunnel_wait && systemctl restart xray
        rm -f "$TUNNEL_HEALTH_STATE"
    else
        log_warn "Tunnel check failed (${fails}/2)"
    fi
}

# Link command router
link_cmd() {
    case "${1:-}" in
        ls)      link_ls ;;
        set)     link_set ;;
        restart) link_restart ;;
        logs)    link_logs "${2:-50}" ;;
        health)  link_health ;;
        *)       echo -e "\nUsage: $SCRIPT_NAME link <ls|set|restart|logs|health>\n" ;;
    esac
}

# --- Status and diagnostics ---

# Sample the tunnel's own socket. rtt is the round trip and its variance is
# jitter; retrans counts segments the kernel had to send twice. A retrans total
# that climbs while the link is idle is the earliest sign of a shaped path,
# well before it shows up as slowness.
link_quality() {
    local host="$1"
    local stats

    command -v ss &>/dev/null || return 0

    stats=$(ss -tin "dst ${host}" 2>/dev/null | tr '\n' ' ')
    [[ -n "$stats" ]] || return 0

    # A socket can be established without carrying these counters yet, and under
    # pipefail a non-matching grep would abort `status` instead of just omitting
    # the line
    local rtt=$(echo "$stats" | grep -oE 'rtt:[0-9.]+/[0-9.]+' | head -1 | cut -d: -f2 || true)
    local retrans=$(echo "$stats" | grep -oE 'retrans:[0-9]+/[0-9]+' | head -1 | cut -d: -f2 || true)

    [[ -n "$rtt" ]] && echo -e "  RTT/jitter:  ${YELLOW}${rtt} ms${NC}"
    [[ -n "$retrans" ]] && echo -e "  Retrans:     ${YELLOW}${retrans}${NC}"

    # This reports, it does not test. Ending on a conditional would hand callers
    # a failure whenever a counter is missing, and take `status` down with it.
    return 0
}

# Show service status
show_status() {
    echo -e "\n${BOLD}Status:${NC}\n"

    if systemctl is-active xray &>/dev/null; then
        echo -e "Xray:   ${GREEN}● Running${NC}"
        [[ -f "$XRAY_BIN" ]] && echo "Version: $("$XRAY_BIN" version | head -1 | awk '{print $2}')"
    else
        echo -e "Xray:   ${RED}● Stopped${NC}"
    fi

    if [[ -f "$TUNNEL_SERVICE" ]]; then
        if systemctl is-active xray-tunnel &>/dev/null; then
            echo -e "Tunnel: ${GREEN}● Running${NC}"

            local gw_host=$(jq -r '.xcp.link.host // ""' "$XRAY_CONFIG" 2>/dev/null)
            [[ -n "$gw_host" ]] && link_quality "$gw_host"
        else
            echo -e "Tunnel: ${RED}● Stopped${NC}"
        fi

        if systemctl is-active xray-tunnel-health.timer &>/dev/null; then
            echo -e "Health: ${GREEN}● Checking every 60s${NC}"
        fi
    fi

    if [[ -f "$WEB_SOCKET" ]] && systemctl is-active xcp-web.socket &>/dev/null; then
        echo -e "Echo:   ${GREEN}● Answering on port ${WEB_PORT}${NC}"
    fi

    echo
}

# Show traffic statistics
show_stats() {
    require_xray
    systemctl is-active xray &>/dev/null || log_error "Xray not running"

    local stats=$("$XRAY_BIN" api statsquery --server="127.0.0.1:${API_PORT}" 2>/dev/null) || log_error "Stats unavailable"

    echo -e "\n${BOLD}Traffic Stats:${NC}\n"

    # Parse users from JSON
    local users=$(echo "$stats" | jq -r '.stat[] | select(.name | startswith("user>>>")) | .name | split(">>>")[1]' 2>/dev/null | sort -u)

    if [[ -n "$users" ]]; then
        echo -e "${CYAN}Users:${NC}"
        while read -r user; do
            local up=$(echo "$stats" | jq -r --arg u "$user" '.stat[] | select(.name == "user>>>\($u)>>>traffic>>>uplink") | .value // 0' 2>/dev/null)
            local down=$(echo "$stats" | jq -r --arg u "$user" '.stat[] | select(.name == "user>>>\($u)>>>traffic>>>downlink") | .value // 0' 2>/dev/null)
            [[ -z "$up" ]] && up=0
            [[ -z "$down" ]] && down=0
            echo "  $user: ↑$(format_bytes $up) ↓$(format_bytes $down)"
        done <<< "$users"
        echo
    fi

    echo -e "${CYAN}System:${NC}"

    local in_up=$(echo "$stats" | jq '[.stat[] | select(.name | startswith("inbound>>>") and endswith(">>>uplink")) | .value // 0] | add // 0' 2>/dev/null)
    local in_down=$(echo "$stats" | jq '[.stat[] | select(.name | startswith("inbound>>>") and endswith(">>>downlink")) | .value // 0] | add // 0' 2>/dev/null)
    echo "  Inbound:  ↑$(format_bytes $in_up) ↓$(format_bytes $in_down)"

    local out_up=$(echo "$stats" | jq '[.stat[] | select(.name | startswith("outbound>>>") and endswith(">>>uplink")) | .value // 0] | add // 0' 2>/dev/null)
    local out_down=$(echo "$stats" | jq '[.stat[] | select(.name | startswith("outbound>>>") and endswith(">>>downlink")) | .value // 0] | add // 0' 2>/dev/null)
    echo "  Outbound: ↑$(format_bytes $out_up) ↓$(format_bytes $out_down)"

    echo
}

# Show logs
show_logs() {
    local follow=false
    local n=50

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow) follow=true; shift ;;
            *)           n="$1"; shift ;;
        esac
    done

    if [[ ! -f "$LOG_DIR/access.log" ]]; then
        echo "No logs"
        return
    fi

    if [[ "$follow" == "true" ]]; then
        echo -e "${BOLD}Following logs (Ctrl+C to stop):${NC}\n"
        tail -f "$LOG_DIR/access.log"
    else
        echo -e "\n${BOLD}Logs (last $n):${NC}\n"
        tail -n "$n" "$LOG_DIR/access.log"
    fi
}

# Test proxy connection and speed
test_proxy() {
    systemctl is-active xray &>/dev/null || { echo -e "${RED}Xray not running${NC}"; return 1; }

    # EDGE server - the tunnel carries everything, so check it first
    if [[ $(jq -r '.xcp.type // ""' "$XRAY_CONFIG") == "edge" ]]; then
        echo -e "\n${BOLD}Testing tunnel...${NC}\n"

        local gw_host=$(jq -r '.xcp.link.host // "?"' "$XRAY_CONFIG")

        if systemctl is-active xray-tunnel &>/dev/null && tunnel_verify_gateway; then
            echo -e "${GREEN}OK${NC} - SSH tunnel to ${YELLOW}${gw_host}${NC} is up"
        else
            echo -e "${RED}Failed${NC} - SSH tunnel is down (journalctl -u xray-tunnel)"
            return 1
        fi
    fi

    # End to end through this server's own routing, using the loopback SOCKS
    echo -e "\n${BOLD}Testing proxy...${NC}\n"

    local socks_port=$(jq -r '[.inbounds[] | select(.tag == "local-in") | .port][0] // empty' "$XRAY_CONFIG")
    [[ -n "$socks_port" ]] || log_error "No local-in inbound - re-run setup to add it"

    local res=$(curl -s --proxy "socks5h://127.0.0.1:${socks_port}" --connect-timeout 10 --max-time 20 \
        "http://ip-api.com/line/?fields=query" 2>/dev/null)

    if [[ -n "$res" ]]; then
        echo -e "${GREEN}OK${NC} - Exit IP: ${YELLOW}$res${NC}"
    else
        echo -e "${RED}Failed${NC}"
        return 1
    fi

    # The VLESS inbound, handshake and all - a dest a client cannot complete the
    # handshake through shows up here and nowhere else
    local reality_dest=$(jq -r '.xcp.reality.dest // empty' "$XRAY_CONFIG")
    if [[ -n "$reality_dest" ]]; then
        echo -e "\n${BOLD}Testing REALITY...${NC}\n"

        local reality_rc=0
        reality_verify_chain || reality_rc=$?

        case "$reality_rc" in
            0) echo -e "${GREEN}OK${NC} - Handshake borrowed from ${YELLOW}${reality_dest}${NC}" ;;
            2) echo -e "${CYAN}Skipped${NC} - the handshake check could not run here" ;;
            *) echo -e "${RED}Failed${NC} - a client could not finish the handshake through ${YELLOW}${reality_dest}${NC}"
               echo -e "         Change it with '${SCRIPT_NAME} config dest' - known good: ${REALITY_DEST_ALTERNATIVES}" ;;
        esac
    fi

    # DNS service on port 53
    if command -v dig &>/dev/null; then
        echo -e "\n${BOLD}Testing DNS...${NC}\n"

        local dns=$(jq -r ".xcp.dns // \"$DEFAULT_DNS\"" "$XRAY_CONFIG")

        if dig +short +time=3 +tries=1 "@127.0.0.1" -p "$DEFAULT_DNS_PORT" example.com &>/dev/null; then
            echo -e "${GREEN}OK${NC} - Resolver ${YELLOW}${dns}${NC} answering on port ${DEFAULT_DNS_PORT}"
        else
            echo -e "${RED}Failed${NC} - No answer on port ${DEFAULT_DNS_PORT}"
        fi
    fi

    if command -v speedtest-cli &>/dev/null; then
        echo -e "\n${BOLD}Speed Test:${NC}\n"

        local result=$(speedtest-cli --simple 2>/dev/null)

        if [[ -n "$result" ]]; then
            local ping=$(echo "$result" | grep "Ping:" | awk '{print $2, $3}' || true)
            local down=$(echo "$result" | grep "Download:" | awk '{print $2, $3}' || true)
            local up=$(echo "$result" | grep "Upload:" | awk '{print $2, $3}' || true)

            echo -e "  Ping:     ${YELLOW}$ping${NC}"
            echo -e "  Download: ${YELLOW}$down${NC}"
            echo -e "  Upload:   ${YELLOW}$up${NC}"
        else
            echo -e "${RED}Speed test failed${NC}"
        fi

        echo
    fi
}

# --- Update ---

# Stamp the installed script version into the config (what `info` reports)
sync_config_version() {
    local version="$1" config="${2:-$XRAY_CONFIG}"

    [[ -f "$config" ]] || return 0
    [[ "$(jq -r '.xcp.version // ""' "$config")" == "$version" ]] && return 0

    jq --arg v "$version" '.xcp.version = $v' "$config" | config_write "$config"
}

# Update script from GitHub
update_script() {
    check_root

    local script_url="https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/script.sh"
    local current_version="$VERSION"

    log_info "Checking for script updates..."

    # Download new version to temp file
    local temp_script=$(mktemp)
    if ! curl -fsSL "$script_url" -o "$temp_script"; then
        rm -f "$temp_script"
        log_error "Failed to download script from GitHub"
    fi

    # Extract version from downloaded script
    # Without `|| true` a truncated download or an error page aborts here, and
    # the "Failed to determine remote version" check below never runs
    local new_version=$(grep -m1 '^readonly VERSION=' "$temp_script" | cut -d'"' -f2 || true)

    if [[ -z "$new_version" ]]; then
        rm -f "$temp_script"
        log_error "Failed to determine remote version"
    fi

    if [[ "$current_version" == "$new_version" ]]; then
        rm -f "$temp_script"
        sync_config_version "$current_version"
        log_success "Script already at latest version ($current_version)"
        return
    fi

    log_info "Updating script $current_version -> $new_version"

    # Get the path of the current script
    local script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    # Backup current script
    cp "$script_path" "${script_path}.bak"

    # Replace with new version
    cat "$temp_script" > "$script_path"
    chmod +x "$script_path"
    rm -f "$temp_script"

    sync_config_version "$new_version"

    log_success "Script updated to $new_version"
    log_info "Backup saved: ${script_path}.bak"
}

# Update Xray to latest version
update_xray() {
    check_root
    require_xray

    local current=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' || true)
    local latest=$(curl -s "$XRAY_RELEASE_URL" | jq -r '.tag_name // empty')

    if [[ "v$current" == "$latest" ]]; then
        log_success "Xray already at latest version ($current)"
        return
    fi

    log_info "Updating Xray $current -> $latest"

    local arch=$(get_arch)
    mkdir -p "$CACHE_DIR"
    local zip_file="$CACHE_DIR/Xray-linux-${arch}-${latest}.zip"

    download_with_retry "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${arch}.zip" "$zip_file" || log_error "Download failed after retries"

    systemctl stop xray
    unzip -o -q "$zip_file" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    systemctl start xray

    log_success "Xray updated to $latest"
}

# Update both script and Xray
update_all() {
    echo -e "\n${BOLD}Update Xray Chain Proxy${NC}\n"
    echo "1) Script only"
    echo "2) Xray only"
    echo "3) Both (recommended)"
    echo

    local choice
    read -rp "Select option (1-3, default: 3): " choice
    choice="${choice:-3}"

    case "$choice" in
        1)
            update_script
            ;;
        2)
            update_xray
            ;;
        3)
            update_script
            echo
            update_xray
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
}

# --- Uninstall ---

# Uninstall Xray completely
uninstall_xray() {
    read -rp "Remove Xray completely? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return

    local type=$(jq -r '.xcp.type // ""' "$XRAY_CONFIG" 2>/dev/null)

    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    tunnel_purge
    web_purge

    # Gateways also carry the tunnel user and its sshd exception
    [[ "$type" == "gateway" ]] && gateway_ssh_user_purge

    restore_dns_port
    rm -rf "$XRAY_DIR" "$XRAY_SERVICE" "$LOG_DIR"
    rm -f "$SYSCTL_DROPIN"
    systemctl daemon-reload

    log_success "Uninstalled"
}

# --- Help and dispatch ---

# Show help message
show_help() {
    cat << EOF

Xray Chain Proxy v${VERSION}

Usage: $SCRIPT_NAME <command>

Commands:
  setup gateway     Setup gateway (exit node)
  setup edge        Setup edge (entry node)

  start             Start Xray service
  stop              Stop Xray service
  restart           Restart Xray service
  status            Show service status

  user ls           List users
  user add          Add user
  user rm           Remove user

  stats             Show traffic stats
  logs [-f] [n]     Show logs (-f to follow)
  test              Test proxy and speed

  config ls         Show current config
  config set        Set log level, ports, DNS resolver or REALITY dest
                    (or go straight there: config loglevel|port|dns|dest)

  dns ls            Show the resolver and who may use it
  dns add [ip]      Allow a client to use this server for DNS
  dns rm [ip]       Revoke a client

  rule ls           List routing rules
  rule add          Add routing rule
  rule rm           Remove routing rule

  link ls           Show gateway SSH link
  link set          Change gateway SSH link
  link restart      Restart SSH tunnel
  link logs [n]     Show SSH tunnel logs
  link health       Check the tunnel end to end

  update            Update script and Xray
  uninstall         Remove Xray

Flow: Client --> EDGE --> [SSH tunnel] --> GATEWAY --> Internet

EOF
}

# Main entry point
main() {
    case "${1:-help}" in
        setup)     setup_cmd "${2:-}" ;;
        start)     service_start ;;
        stop)      service_stop ;;
        restart)   service_restart ;;
        status)    show_status ;;
        user)      user_cmd "${2:-}" ;;
        stats)     show_stats ;;
        logs)      shift; show_logs "$@" ;;
        test)      test_proxy ;;
        config)    config_cmd "${2:-}" ;;
        dns)       dns_cmd "${2:-}" "${3:-}" ;;
        rule)      rule_cmd "${2:-}" ;;
        link)      link_cmd "${2:-}" "${3:-}" ;;
        update)    update_all ;;
        uninstall) check_root; uninstall_xray ;;
        help|--help|-h) show_help ;;
        version|--version|-v) echo "v$VERSION" ;;
        *)         echo -e "${RED}Unknown: $1${NC}"; show_help; exit 1 ;;
    esac
}

main "$@"
