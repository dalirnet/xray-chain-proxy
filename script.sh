#!/usr/bin/env bash

#
# Xray Chain Proxy
#
# Chain proxy setup with two server types:
#   - GATEWAY: Exit node that connects to the internet
#   - EDGE: Entry node that clients connect to, forwards to GATEWAY
#
# Flow: Client --> EDGE --> GATEWAY --> Internet
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
#   script.sh config set        - Set config value
#   script.sh update            - Update Xray to latest version
#   script.sh uninstall         - Remove Xray completely
#

set -euo pipefail

# Constants
readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly XRAY_DIR="/usr/local/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly DEFAULT_PORT=80
readonly ENCRYPTION_METHOD="aes-256-gcm"
readonly XRAY_API_URL="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

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

# Logging functions
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit "${2:-1}"; }
log_step()    { echo -e "\n${BOLD}>>> $1${NC}"; }

# Check if running as root
check_root() {
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root"
}

# Check if systemd is available
check_systemd() {
    command -v systemctl &>/dev/null || log_error "systemd is required"
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

# Format bytes to human readable
format_bytes() {
    local b=${1:-0}
    [[ ! "$b" =~ ^[0-9]+$ ]] && b=0
    ((b < 1024)) && echo "${b} B" && return
    ((b < 1048576)) && echo "$((b / 1024)) KB" && return
    ((b < 1073741824)) && echo "$((b / 1048576)) MB" && return
    echo "$((b / 1073741824)) GB"
}

# Check and install dependencies
check_dependencies() {
    log_step "Checking dependencies"

    # Required dependencies
    local required=()
    for cmd in curl unzip jq; do
        command -v "$cmd" &>/dev/null || required+=("$cmd")
    done

    if [[ ${#required[@]} -gt 0 ]]; then
        log_info "Installing required: ${required[*]}"
        apt-get update -qq && apt-get install -y -qq "${required[@]}" || log_error "Failed to install dependencies"
    fi

    # Optional dependencies (ignore if install fails)
    local optional=()
    for cmd in qrencode speedtest-cli; do
        command -v "$cmd" &>/dev/null || optional+=("$cmd")
    done

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
    local tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" EXIT

    log_info "Fetching latest version..."
    local version=$(curl -s --connect-timeout 10 "$XRAY_API_URL" 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo "v24.12.18")
    log_info "Version: $version"

    log_info "Downloading..."
    curl -L --progress-bar -o "$tmp/xray.zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip" || log_error "Download failed"

    mkdir -p "$XRAY_DIR" "$LOG_DIR"
    unzip -o -q "$tmp/xray.zip" -d "$XRAY_DIR" || log_error "Extract failed"
    chmod +x "$XRAY_BIN"

    # Download geo data
    curl -sL -o "$XRAY_DIR/geoip.dat" "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" 2>/dev/null || true
    curl -sL -o "$XRAY_DIR/geosite.dat" "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" 2>/dev/null || true

    # Create systemd service
    cat > "$XRAY_SERVICE" << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target
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

    rm -rf "$tmp"
    trap - EXIT

    log_success "Xray installed: $version"
}

# Validate Xray configuration
validate_config() {
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" &>/dev/null || log_error "Invalid config"
    log_success "Configuration valid"
}

# Configure firewall
configure_firewall() {
    local port="$1"

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$port/tcp" &>/dev/null || true
        ufw allow "$port/udp" &>/dev/null || true
        log_info "Firewall: port $port opened"
    fi
}

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

# Prompt for password
prompt_password() {
    local prompt="$1" allow_empty="$2"
    local -n _pass="$3"

    if [[ "$allow_empty" == "true" ]]; then
        read -rp "$prompt (empty=generate): " input
        [[ -z "$input" ]] && { input=$(generate_password 16); log_info "Generated: $input"; }
        _pass="$input"
    else
        while true; do
            read -rp "$prompt: " input
            [[ -n "$input" ]] && { _pass="$input"; break; }
            echo -e "${RED}Cannot be empty${NC}"
        done
    fi
}

# Generate GATEWAY configuration
gen_gateway_config() {
    local port="$1" clients="$2"

    cat << EOF
{
  "xcp": {
    "type": "gateway",
    "version": "${VERSION}"
  },
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
  "inbounds": [
    {
      "tag": "api",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "ss-in",
      "port": ${port},
      "protocol": "shadowsocks",
      "settings": {
        "clients": ${clients},
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
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
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
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
gen_edge_config() {
    local port="$1" clients="$2" gw_ip="$3" gw_port="$4" gw_pass="$5"

    cat << EOF
{
  "xcp": {
    "type": "edge",
    "version": "${VERSION}"
  },
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
  "inbounds": [
    {
      "tag": "api",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "socks-local",
      "port": 8080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth"
      }
    },
    {
      "tag": "ss-in",
      "port": ${port},
      "protocol": "shadowsocks",
      "settings": {
        "clients": ${clients},
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "${gw_ip}",
            "port": ${gw_port},
            "method": "${ENCRYPTION_METHOD}",
            "password": "${gw_pass}"
          }
        ]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "inboundTag": ["socks-local", "ss-in"],
        "outboundTag": "proxy"
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

# Setup GATEWAY server
setup_gateway() {
    echo -e "\n${BOLD}GATEWAY Setup${NC} (Exit Node)\n"

    check_root
    check_systemd
    check_dependencies
    install_xray

    log_step "Configure"

    local PORT
    prompt_port "Listen port" "$DEFAULT_PORT" PORT

    # Create initial edge account
    local EDGE_PASS=$(generate_password 16)
    local EDGE_CLIENT="[{\"email\":\"edge\",\"password\":\"${EDGE_PASS}\",\"method\":\"${ENCRYPTION_METHOD}\"}]"

    gen_gateway_config "$PORT" "$EDGE_CLIENT" > "$XRAY_CONFIG"
    validate_config
    configure_firewall "$PORT"

    systemctl restart xray
    sleep 2
    systemctl is-active xray &>/dev/null || log_error "Xray failed to start"

    local IP=$(get_public_ip)

    echo -e "\n${GREEN}GATEWAY Ready!${NC}"
    echo -e "\n${BOLD}Use on EDGE server:${NC}"
    echo -e "  IP:       ${YELLOW}$IP${NC}"
    echo -e "  Port:     ${YELLOW}$PORT${NC}"
    echo -e "  Password: ${YELLOW}$EDGE_PASS${NC}\n"
}

# Setup EDGE server
setup_edge() {
    echo -e "\n${BOLD}EDGE Setup${NC} (Entry Node)\n"

    check_root
    check_systemd
    check_dependencies
    install_xray

    log_step "Gateway Details"

    local GW_IP GW_PORT GW_PASS
    prompt_address "Gateway IP" GW_IP
    prompt_port "Gateway port" "$DEFAULT_PORT" GW_PORT
    prompt_password "Gateway password" "false" GW_PASS

    log_step "Edge Settings"

    local PORT
    prompt_port "Listen port" "$DEFAULT_PORT" PORT

    # Create initial edge account
    local EDGE_PASS=$(generate_password 16)
    local EDGE_CLIENT="[{\"email\":\"edge\",\"password\":\"${EDGE_PASS}\",\"method\":\"${ENCRYPTION_METHOD}\"}]"

    gen_edge_config "$PORT" "$EDGE_CLIENT" "$GW_IP" "$GW_PORT" "$GW_PASS" > "$XRAY_CONFIG"
    validate_config
    configure_firewall "$PORT"

    systemctl restart xray
    sleep 2
    systemctl is-active xray &>/dev/null || log_error "Xray failed to start"

    local IP=$(get_public_ip)

    echo -e "\n${GREEN}EDGE Ready!${NC}"
    echo -e "\n${BOLD}Chain:${NC} Client -> $IP:$PORT -> $GW_IP:$GW_PORT -> Internet"
    echo -e "\n${BOLD}Use on Xray client:${NC}"
    echo -e "  IP:       ${YELLOW}$IP${NC}"
    echo -e "  Port:     ${YELLOW}$PORT${NC}"
    echo -e "  Password: ${YELLOW}$EDGE_PASS${NC}\n"
}

# List all users
user_ls() {
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"
    jq -e '.inbounds[] | select(.tag == "ss-in") | .settings.clients' "$XRAY_CONFIG" &>/dev/null || log_error "No accounts configured"

    local IP=$(get_public_ip)
    local PORT=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local clients=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .settings.clients[] | "\(.email)|\(.password)"' "$XRAY_CONFIG" 2>/dev/null)

    echo -e "\n${BOLD}Accounts:${NC}\n"

    if [[ -z "$clients" ]]; then
        echo "  No accounts"
    else
        local i=1
        while IFS='|' read -r email pass; do
            local uri=$(gen_ss_uri "$ENCRYPTION_METHOD" "$pass" "$IP" "$PORT" "$email")
            echo -e "${CYAN}$i) $email${NC}"
            echo -e "   Password: ${YELLOW}$pass${NC}"
            echo "   URI: $uri"
            echo
            ((i++))
        done <<< "$clients"
    fi
}

# Add new user
user_add() {
    check_root
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"
    jq -e '.inbounds[] | select(.tag == "ss-in") | .settings.clients' "$XRAY_CONFIG" &>/dev/null || log_error "No accounts configured"

    local EMAIL PASS
    read -rp "Username: " EMAIL
    [[ -z "$EMAIL" ]] && log_error "Username required"
    jq -e --arg e "$EMAIL" '.inbounds[] | select(.tag == "ss-in") | .settings.clients[] | select(.email == $e)' "$XRAY_CONFIG" &>/dev/null && log_error "Account exists"

    prompt_password "Password" "true" PASS

    local PORT=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local TMP=$(mktemp)

    jq --arg e "$EMAIL" --arg p "$PASS" --arg m "$ENCRYPTION_METHOD" \
        '.inbounds |= map(if .tag == "ss-in" then .settings.clients += [{"email":$e,"password":$p,"method":$m}] else . end)' \
        "$XRAY_CONFIG" > "$TMP" && mv "$TMP" "$XRAY_CONFIG"

    validate_config
    systemctl restart xray
    sleep 1

    local IP=$(get_public_ip)
    local URI=$(gen_ss_uri "$ENCRYPTION_METHOD" "$PASS" "$IP" "$PORT" "$EMAIL")

    echo -e "\n${GREEN}Account '$EMAIL' Added${NC}"
    echo -e "  IP:       ${YELLOW}$IP${NC}"
    echo -e "  Port:     ${YELLOW}$PORT${NC}"
    echo -e "  Password: ${YELLOW}$PASS${NC}\n"

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$URI"
    fi
    echo "$URI"
}

# Remove user
user_rm() {
    check_root
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"
    jq -e '.inbounds[] | select(.tag == "ss-in") | .settings.clients' "$XRAY_CONFIG" &>/dev/null || log_error "No accounts configured"

    local EMAIL
    read -rp "Username to remove: " EMAIL
    [[ -z "$EMAIL" ]] && log_error "Username required"
    jq -e --arg e "$EMAIL" '.inbounds[] | select(.tag == "ss-in") | .settings.clients[] | select(.email == $e)' "$XRAY_CONFIG" &>/dev/null || log_error "Account not found"

    local TMP=$(mktemp)

    jq --arg e "$EMAIL" \
        '.inbounds |= map(if .tag == "ss-in" then .settings.clients |= map(select(.email != $e)) else . end)' \
        "$XRAY_CONFIG" > "$TMP" && mv "$TMP" "$XRAY_CONFIG"

    validate_config
    systemctl restart xray

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

# Start Xray service
service_start() {
    check_root
    [[ -f "$XRAY_BIN" ]] || log_error "Xray not installed"
    systemctl start xray
    log_success "Xray started"
}

# Stop Xray service
service_stop() {
    check_root
    systemctl stop xray 2>/dev/null || true
    log_success "Xray stopped"
}

# Restart Xray service
service_restart() {
    check_root
    [[ -f "$XRAY_BIN" ]] || log_error "Xray not installed"
    systemctl restart xray
    log_success "Xray restarted"
}

# Set log level
config_loglevel() {
    check_root
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"

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

    local TMP=$(mktemp)

    if [[ "$LEVEL" == "none" ]]; then
        jq '.log.loglevel = "none" | .log.access = "none" | .log.error = "none"' "$XRAY_CONFIG" > "$TMP" && mv "$TMP" "$XRAY_CONFIG"
    else
        jq --arg l "$LEVEL" --arg a "${LOG_DIR}/access.log" --arg e "${LOG_DIR}/error.log" \
            '.log.loglevel = $l | .log.access = $a | .log.error = $e' "$XRAY_CONFIG" > "$TMP" && mv "$TMP" "$XRAY_CONFIG"
    fi

    validate_config
    systemctl restart xray

    log_success "Log level set to '$LEVEL'"
}

# Change listen port
config_port() {
    check_root
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"

    local current=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    echo -e "\n${BOLD}Listen Port${NC}\n"
    echo -e "Current: ${YELLOW}$current${NC}\n"

    local PORT
    prompt_port "New port" "$current" PORT

    if [[ "$PORT" == "$current" ]]; then
        log_info "Port unchanged"
        return
    fi

    local TMP=$(mktemp)
    jq --argjson p "$PORT" '.inbounds |= map(if .tag == "ss-in" then .port = $p else . end)' "$XRAY_CONFIG" > "$TMP" && mv "$TMP" "$XRAY_CONFIG"

    validate_config
    configure_firewall "$PORT"
    systemctl restart xray

    log_success "Port changed to $PORT"
}

# Show current config
config_ls() {
    [[ -f "$XRAY_CONFIG" ]] || log_error "Config not found"

    local type=$(jq -r '.xcp.type // "unknown"' "$XRAY_CONFIG")
    local version=$(jq -r '.xcp.version // "unknown"' "$XRAY_CONFIG")
    local port=$(jq -r '.inbounds[] | select(.tag == "ss-in") | .port' "$XRAY_CONFIG")
    local loglevel=$(jq -r '.log.loglevel // "warning"' "$XRAY_CONFIG")

    echo -e "\n${BOLD}Config:${NC}\n"
    echo -e "  Type:      ${YELLOW}$type${NC}"
    echo -e "  Version:   ${YELLOW}$version${NC}"
    echo -e "  Port:      ${YELLOW}$port${NC}"
    echo -e "  Log level: ${YELLOW}$loglevel${NC}"

    if [[ "$type" == "edge" ]]; then
        local gw_ip=$(jq -r '.outbounds[] | select(.tag == "proxy") | .settings.servers[0].address' "$XRAY_CONFIG")
        local gw_port=$(jq -r '.outbounds[] | select(.tag == "proxy") | .settings.servers[0].port' "$XRAY_CONFIG")
        echo -e "  Gateway:   ${YELLOW}$gw_ip:$gw_port${NC}"
    fi

    echo
}

# Config set submenu
config_set() {
    echo -e "\n${BOLD}Set Config:${NC}\n"
    echo "  1) loglevel - Set log level"
    echo "  2) port     - Change listen port"
    echo

    local choice
    read -rp "Select option (1-2): " choice

    case "$choice" in
        1|loglevel) config_loglevel ;;
        2|port)     config_port ;;
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
        *)        echo -e "\nUsage: $SCRIPT_NAME config <ls|set>\n" ;;
    esac
}

# Show service status
show_status() {
    echo -e "\n${BOLD}Status:${NC}\n"

    if systemctl is-active xray &>/dev/null; then
        echo -e "${GREEN}● Running${NC}"
        [[ -f "$XRAY_BIN" ]] && echo "Version: $("$XRAY_BIN" version | head -1 | awk '{print $2}')"
    else
        echo -e "${RED}● Stopped${NC}"
    fi

    echo
}

# Show traffic statistics
show_stats() {
    [[ -f "$XRAY_BIN" ]] || log_error "Xray not installed"
    systemctl is-active xray &>/dev/null || log_error "Xray not running"

    local stats=$("$XRAY_BIN" api statsquery --server=127.0.0.1:10085 2>/dev/null) || log_error "Stats unavailable"

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

    # EDGE server - test through proxy
    if [[ $(jq -r '.xcp.type // ""' "$XRAY_CONFIG") == "edge" ]]; then
        echo -e "\n${BOLD}Testing proxy...${NC}\n"

        local res=$(curl -s --proxy "socks5://127.0.0.1:8080" --connect-timeout 10 "http://ip-api.com/line/?fields=query" 2>/dev/null)

        if [[ -n "$res" ]]; then
            echo -e "${GREEN}OK${NC} - Exit IP: ${YELLOW}$res${NC}"
        else
            echo -e "${RED}Failed${NC}"
            return 1
        fi
    fi

    if command -v speedtest-cli &>/dev/null; then
        echo -e "\n${BOLD}Speed Test:${NC}\n"

        local result=$(speedtest-cli --simple 2>/dev/null)

        if [[ -n "$result" ]]; then
            local ping=$(echo "$result" | grep "Ping:" | awk '{print $2, $3}')
            local down=$(echo "$result" | grep "Download:" | awk '{print $2, $3}')
            local up=$(echo "$result" | grep "Upload:" | awk '{print $2, $3}')

            echo -e "  Ping:     ${YELLOW}$ping${NC}"
            echo -e "  Download: ${YELLOW}$down${NC}"
            echo -e "  Upload:   ${YELLOW}$up${NC}"
        else
            echo -e "${RED}Speed test failed${NC}"
        fi

        echo
    fi
}

# Update Xray to latest version
update_xray() {
    check_root
    [[ -f "$XRAY_BIN" ]] || log_error "Xray not installed"

    local current=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
    local latest=$(curl -s "$XRAY_API_URL" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ "v$current" == "$latest" ]]; then
        log_success "Already latest ($current)"
        return
    fi

    log_info "Updating $current -> $latest"

    local tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    curl -sL -o "$tmp/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-$(get_arch).zip" || log_error "Download failed"

    systemctl stop xray
    unzip -o -q "$tmp/xray.zip" -d "$XRAY_DIR"
    chmod +x "$XRAY_BIN"
    systemctl start xray

    log_success "Updated to $latest"
}

# Uninstall Xray completely
uninstall_xray() {
    read -rp "Remove Xray completely? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return

    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    rm -rf "$XRAY_DIR" "$XRAY_SERVICE" "$LOG_DIR"
    systemctl daemon-reload

    log_success "Uninstalled"
}

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
  config set        Set config value

  update            Update Xray
  uninstall         Remove Xray

Flow: Client --> EDGE --> GATEWAY --> Internet

EOF
}

# Setup command router
setup_cmd() {
    case "${1:-}" in
        gateway) setup_gateway ;;
        edge)    setup_edge ;;
        *)       echo -e "\nUsage: $SCRIPT_NAME setup <gateway|edge>\n" ;;
    esac
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
        update)    update_xray ;;
        uninstall) check_root; uninstall_xray ;;
        help|--help|-h) show_help ;;
        version|--version|-v) echo "v$VERSION" ;;
        *)         echo -e "${RED}Unknown: $1${NC}"; show_help; exit 1 ;;
    esac
}

main "$@"
