#!/usr/bin/env bash
#
# Generate all showcase GIFs with macOS window frame
#
# Dependencies: asciinema, agg, imagemagick
#
# Usage: ./mockup.sh                       # record all demos
#        ./mockup.sh setup-edge status    # record only the named demos
#
# Output:
#   setup-gateway.gif
#   setup-edge.gif
#   user-add.gif
#   status.gif
#   stats.gif
#   test.gif
#   link-ls.gif
#   dns-ls.gif
#   rule-add.gif
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Shared ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

QR='█████████████████████████████
████ ▄▄▄▄▄ █▀▄▀▄██ ▄▄▄▄▄ ████
████ █   █ █▄ ▀▄▀█ █   █ ████
████ █▄▄▄█ █ █▀▀██ █▄▄▄█ ████
████▄▄▄▄▄▄▄█ █▄█ █▄▄▄▄▄▄▄████
████▄ ▄▀▄▄▄▀▄█▀▄▀▀▀▄██▄▀▄████
████▄█▄██▄▄█▀▀▄▀▄█▀▄▀ █▄▀████
████ ▄▄▄▄▄ █▀▀▄██▀ █▄█ ▀█████
████ █   █ █ ▀ ▀▄█▄▄▄ ▄██████
████ █▄▄▄█ █ █ ▀▀▀▀▄ ▄▀▀█████
████▄▄▄▄▄▄▄█▄██▄█▄██▄██▄█████
█████████████████████████████'

GW_IP="104.28.55.73"; EDGE_IP="185.92.36.110"
SS_PORT="8443"; LOCAL_SOCKS_PORT="11080"; DNS_PORT="53"
VLESS_PORT="443"; REALITY_DEST="www.bing.com"
SSH_USER="xcp"; SSH_PASS="kQ8vR2mZpL4xN7wD"; DNS_SERVER="1.1.1.1"
DEMO_USER="john"
DEMO_PASS="bT5sD1fG8hY3oK7w"
DEMO_URI="ss://YWVzLTI1Ni1nY206YlQ1c0QxZkc4aFkzb0s3dw==@185.92.36.110:8443#john"
DEMO_VLESS="vless://8f3a1c2e-5b7d-4e91-a6f0-2d84bc9e1357@185.92.36.110:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.bing.com&fp=chrome&pbk=T9xKp2mVqL8nR4wZ3cJ7yB5dF1hG6sA0eN2uX8vC4kM&sid=a1b2c3d4e5f60718&spx=%2F#john"

PROMPT="${GREEN}root@ubuntu${NC}:${CYAN}~${NC}# "

type_cmd() { for ((i=0;i<${#1};i++)); do printf '%s' "${1:$i:1}"; sleep 0.04; done; }
type_input() { for ((i=0;i<${#1};i++)); do printf '%s' "${1:$i:1}"; sleep 0.05; done; }
enter() { sleep 0.3; printf '\n'; }
# prompt_default: user reads the prompt, pauses, then presses enter (accepts default)
prompt_default() { sleep 0.6; printf '\n'; }
# prompt_type: user reads the prompt, pauses, types value, then presses enter
prompt_type() { sleep 0.5; type_input "$1"; sleep 0.3; printf '\n'; }

# --- Window wrapper ---
wrap_window() {
    local INPUT="$1" OUTPUT="$2" BG_COLOR="$3" BAR_COLOR="$4"
    local TITLE_HEIGHT=36
    local DOT_Y=$((TITLE_HEIGHT / 2))

    local WIDTH=$(magick identify -format "%w" "$INPUT[0]")
    local HEIGHT=$(magick identify -format "%h" "$INPUT[0]")

    local TOTAL_W=$((WIDTH + 20))
    local TOTAL_H=$((HEIGHT + TITLE_HEIGHT + 20))

    magick -size "${TOTAL_W}x${TOTAL_H}" "xc:${BG_COLOR}" \
        -fill "$BAR_COLOR" \
        -draw "rectangle 0,0 $((TOTAL_W-1)),$TITLE_HEIGHT" \
        -fill "#ff5f57" -draw "circle 20,$DOT_Y 26,$DOT_Y" \
        -fill "#febc2e" -draw "circle 40,$DOT_Y 46,$DOT_Y" \
        -fill "#28c840" -draw "circle 60,$DOT_Y 66,$DOT_Y" \
        /tmp/window-frame.png

    local TMPDIR=$(mktemp -d)
    magick identify -format "%T\n" "$INPUT" > "$TMPDIR/delays.txt"
    magick "$INPUT" -coalesce "$TMPDIR/frame-%04d.png"

    local i=0
    for frame in "$TMPDIR"/frame-*.png; do
        magick /tmp/window-frame.png "$frame" \
            -geometry "+10+$((TITLE_HEIGHT + 10))" \
            -composite \
            "$TMPDIR/out-$(printf '%04d' $i).png"
        i=$((i + 1))
    done

    local DELAY_ARGS="" i=0
    while read -r delay; do
        [[ -z "$delay" ]] && delay=10
        DELAY_ARGS="$DELAY_ARGS -delay $delay $TMPDIR/out-$(printf '%04d' $i).png"
        i=$((i + 1))
    done < "$TMPDIR/delays.txt"

    eval magick $DELAY_ARGS -loop 0 "$OUTPUT"
    rm -rf "$TMPDIR" /tmp/window-frame.png
}

# --- Record + wrap a single demo ---
record_demo() {
    local NAME="$1" ROWS="$2"
    local CAST="$SCRIPT_DIR/$NAME.cast"

    local GIF_DIR="$SCRIPT_DIR/gif"
    local PNG_DIR="$SCRIPT_DIR/png"
    mkdir -p "$GIF_DIR" "$PNG_DIR"

    echo "Recording $NAME..."
    asciinema rec --window-size "80x${ROWS}" --overwrite -c "$0 __run_${NAME}" "$CAST"

    local GIF_RAW="$GIF_DIR/$NAME-raw.gif"
    local GIF_FINAL="$GIF_DIR/$NAME.gif"
    agg --theme github-dark --font-size 16 "$CAST" "$GIF_RAW"
    rm -f "$CAST"

    echo "Wrapping $NAME..."
    wrap_window "$GIF_RAW" "$GIF_FINAL" "#171B21" "#1F2329"
    rm -f "$GIF_RAW"

    # Extract last frame as PNG
    local PNG_FINAL="$PNG_DIR/$NAME.png"
    local LAST_FRAME=$(magick identify "$GIF_FINAL" | tail -1 | sed 's/.*\[\([0-9]*\)\].*/\1/')
    magick "${GIF_FINAL}[${LAST_FRAME}]" "$PNG_FINAL"

    echo "Saved: $GIF_FINAL"
    echo "Saved: $PNG_FINAL"
    echo ""
}

# =====================
# Demo scenes
# =====================

run_setup_gateway() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh setup gateway"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}GATEWAY Setup${NC} (Exit Node)\n"
    sleep 0.3

    echo -e "\n${BOLD}>>> Checking dependencies${NC}"
    sleep 0.4
    echo -e "${GREEN}[OK]${NC} Dependencies ready"
    sleep 0.3

    echo -e "\n${BOLD}>>> Installing Xray-core${NC}"
    sleep 0.3
    echo -e "${CYAN}[INFO]${NC} Version: v25.1.30"
    sleep 0.2
    echo -e "${GREEN}[OK]${NC} Xray installed"
    sleep 0.3

    echo -e "\n${BOLD}>>> Configure Ports${NC}"
    sleep 0.2
    echo -n "VLESS (REALITY) port [443]: "; prompt_default
    echo -n "Shadowsocks port [8443]: "; prompt_default
    echo -n "DNS resolver [1.1.1.1]: "; prompt_default
    sleep 0.3

    echo -e "\n${BOLD}>>> REALITY${NC}"
    sleep 0.2
    echo -n "REALITY dest domain (default: ${REALITY_DEST}): "; prompt_default
    sleep 0.4
    echo -e "${GREEN}[OK]${NC} ${REALITY_DEST} serves TLS 1.3 with HTTP/2"
    sleep 0.2
    echo -e "${GREEN}[OK]${NC} REALITY keys generated, borrowing ${REALITY_DEST}"
    sleep 0.3

    echo -e "\n${BOLD}>>> SSH Access${NC}"
    sleep 0.2
    echo -n "Tunnel SSH password (empty=generate): "; prompt_default
    echo -e "${CYAN}[INFO]${NC} Generated: ${SSH_PASS}"
    sleep 0.3
    echo -e "${GREEN}[OK]${NC} SSH user '${SSH_USER}' created"
    sleep 0.3
    echo -e "${GREEN}[OK]${NC} sshd accepts tunnel logins from '${SSH_USER}'"
    sleep 0.4

    echo -e "\n${GREEN}GATEWAY Ready!${NC}"
    sleep 0.2
    echo -e "\n${BOLD}Use on EDGE server (setup edge):${NC}"
    echo -e "  Gateway:    ${YELLOW}${GW_IP}${NC}"
    echo -e "  SSH Port:   ${YELLOW}22${NC}"
    echo -e "  SSH User:   ${YELLOW}${SSH_USER}${NC}"
    echo -e "  SSH Pass:   ${YELLOW}${SSH_PASS}${NC}"
    echo -e "\n${BOLD}Direct client access:${NC}"
    echo -e "  VLESS Port: ${YELLOW}${VLESS_PORT}${NC} (REALITY, borrowing ${REALITY_DEST})"
    echo -e "  SS Port:    ${YELLOW}${SS_PORT}${NC}"
    echo -e "  Username:   ${YELLOW}default${NC}"
    echo -e "  Password:   ${YELLOW}Rk7xPm2wQ4nLs9Fj${NC}"
    echo -e "\n${BOLD}Loopback only (127.0.0.1):${NC}"
    echo -e "  SOCKS Port: ${YELLOW}${LOCAL_SOCKS_PORT}${NC} (diagnostics)"
    echo -e "  DNS Port:   ${YELLOW}${DNS_PORT}${NC} (${DNS_SERVER})"
    sleep 0.1
}

run_setup_edge() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh setup edge"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}EDGE Setup${NC} (Entry Node)\n"
    sleep 0.3

    echo -e "\n${BOLD}>>> Checking dependencies${NC}"
    sleep 0.4
    echo -e "${GREEN}[OK]${NC} Dependencies ready"
    sleep 0.3

    echo -e "\n${BOLD}>>> Installing Xray-core${NC}"
    sleep 0.3
    echo -e "${CYAN}[INFO]${NC} Version: v25.1.30"
    sleep 0.2
    echo -e "${GREEN}[OK]${NC} Xray installed"
    sleep 0.3

    echo -e "\n${BOLD}>>> Gateway Details${NC}"
    sleep 0.2
    echo -n "Gateway host: "; prompt_type "$GW_IP"
    echo -n "Gateway SSH port [22]: "; prompt_default
    echo -n "Gateway SSH user [xcp]: "; prompt_default
    echo -n "Gateway SSH password: "; prompt_default
    sleep 0.2

    echo -e "\n${BOLD}>>> Edge Settings${NC}"
    sleep 0.2
    echo -n "VLESS (REALITY) port [443]: "; prompt_default
    echo -n "Shadowsocks port [8443]: "; prompt_default
    echo -n "DNS resolver [1.1.1.1]: "; prompt_default
    sleep 0.3

    echo -e "\n${BOLD}>>> REALITY${NC}"
    sleep 0.2
    echo -n "REALITY dest domain (default: ${REALITY_DEST}): "; prompt_default
    sleep 0.4
    echo -e "${GREEN}[OK]${NC} ${REALITY_DEST} serves TLS 1.3 with HTTP/2"
    sleep 0.2
    echo -e "${GREEN}[OK]${NC} REALITY keys generated, borrowing ${REALITY_DEST}"
    sleep 0.3

    echo -e "\n${BOLD}>>> SSH Tunnel${NC}"
    sleep 0.4
    echo -e "${GREEN}[OK]${NC} Password login to ${SSH_USER}@${GW_IP} works"
    sleep 0.4
    echo -e "${GREEN}[OK]${NC} Tunnel up on 127.0.0.1:10080"
    sleep 0.5
    echo -e "${GREEN}[OK]${NC} Gateway reachable through the tunnel"
    sleep 0.3

    echo -e "\n${GREEN}EDGE Ready!${NC}"
    sleep 0.2
    echo -e "\n${BOLD}Chain:${NC} Client -> ${EDGE_IP} -> ssh://${GW_IP}:22 -> Internet"
    sleep 0.1
}

run_user_add() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh user add"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -n "Username: "; prompt_type "$DEMO_USER"
    echo -n "Password (empty=generate): "; prompt_default
    sleep 0.3

    echo -e "\n${GREEN}Account '${DEMO_USER}' Added${NC}"
    sleep 0.2
    echo -e "  IP:         ${YELLOW}${EDGE_IP}${NC}"
    echo -e "  VLESS Port: ${YELLOW}${VLESS_PORT}${NC}"
    echo -e "  SS Port:    ${YELLOW}${SS_PORT}${NC}"
    echo -e "  Username:   ${YELLOW}${DEMO_USER}${NC}"
    echo -e "  Password:   ${YELLOW}********${NC}\n"
    sleep 0.8
    echo "$QR"
    echo ""
    echo "VLESS URI: ${DEMO_VLESS}"
    echo ""
    echo "SS URI: ${DEMO_URI}"
    sleep 0.1
}

run_status() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh status"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}Status:${NC}\n"
    sleep 0.3
    echo -e "Xray:   ${GREEN}● Running${NC}"
    echo "Version: 25.1.30"
    sleep 0.2
    echo -e "Tunnel: ${GREEN}● Running${NC}"
    sleep 0.2
    echo -e "  RTT/jitter:  ${YELLOW}47.3/2.1 ms${NC}"
    echo -e "  Retrans:     ${YELLOW}0/1841${NC}"
    sleep 0.2
    echo -e "Health: ${GREEN}● Checking every 60s${NC}"
    sleep 0.2
    echo -e "Echo:   ${GREEN}● Answering on port 80${NC}"
    sleep 0.1
}

run_stats() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh stats"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}Traffic Stats:${NC}\n"
    sleep 0.3
    echo -e "${CYAN}Users:${NC}"
    sleep 0.2
    echo "  john:  ↑2.4 MB ↓15.7 MB"
    sleep 0.1
    echo "  alice: ↑512 KB ↓8.3 MB"
    sleep 0.3

    echo -e "\n${CYAN}System:${NC}"
    sleep 0.2
    echo "  Inbound:  ↑18.2 MB ↓89.5 MB"
    echo "  Outbound: ↑17.8 MB ↓87.1 MB"
    sleep 0.1
}

run_test() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh test"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}Testing tunnel...${NC}\n"
    sleep 0.5
    echo -e "${GREEN}OK${NC} - SSH tunnel to ${YELLOW}${GW_IP}${NC} is up"
    sleep 0.3

    echo -e "\n${BOLD}Testing proxy...${NC}\n"
    sleep 0.6
    echo -e "${GREEN}OK${NC} - Exit IP: ${YELLOW}${GW_IP}${NC}"
    sleep 0.3

    echo -e "\n${BOLD}Testing DNS...${NC}\n"
    sleep 0.5
    echo -e "${GREEN}OK${NC} - Resolver ${YELLOW}${DNS_SERVER}${NC} answering on port ${DNS_PORT}"
    sleep 0.3

    echo -e "\n${BOLD}Speed Test:${NC}\n"
    sleep 0.4
    echo -e "  Ping:     ${YELLOW}12.45 ms${NC}"
    sleep 0.2
    echo -e "  Download: ${YELLOW}87.32 Mbit/s${NC}"
    sleep 0.2
    echo -e "  Upload:   ${YELLOW}41.58 Mbit/s${NC}"
    sleep 0.1
}

run_link_ls() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh link ls"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}Gateway Link:${NC}\n"
    sleep 0.3
    echo -e "  Protocol:   ${YELLOW}ssh${NC}"
    sleep 0.2
    echo -e "  Gateway:    ${YELLOW}${SSH_USER}@${GW_IP}:22${NC}"
    sleep 0.2
    echo -e "  Auth:       ${YELLOW}password${NC}"
    sleep 0.2
    echo -e "  Forward:    ${YELLOW}127.0.0.1:10080${NC} (loopback only)"
    sleep 0.2
    echo -e "  Tunnel:     ${GREEN}● Running${NC}"
    sleep 0.1
}

run_dns_ls() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh dns ls"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}DNS:${NC}\n"
    sleep 0.3
    echo -e "  Resolver: ${YELLOW}${DNS_SERVER}${NC}  (change with 'xcp.sh config set')"
    sleep 0.2
    echo -e "  Reachable: ${YELLOW}0.0.0.0:${DNS_PORT}${NC}, allowed sources only"
    sleep 0.3
    echo -e "\n${BOLD}Allowed:${NC}\n"
    sleep 0.2
    echo -e "  ${CYAN}1)${NC} 203.0.113.9"
    sleep 0.2
    echo -e "  ${CYAN}2)${NC} 198.51.100.0/24"
    sleep 0.1
}

run_rule_add() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh rule add"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}Add Routing Rule${NC}\n"
    sleep 0.3

    echo -e "${BOLD}Available outbounds:${NC}"
    echo "  proxy   - Through the gateway"
    echo "  direct  - Direct connection (bypass the gateway)"
    echo "  blocked - Block traffic"
    echo ""
    sleep 0.3

    echo -n "Outbound tag: "; prompt_type "direct"

    echo -e "\n${BOLD}Rule type:${NC}"
    echo "  1) Domain (e.g., google.com, geosite:cn)"
    echo "  2) IP/CIDR (e.g., 8.8.8.8, geoip:us)"
    echo ""
    sleep 0.3

    echo -n "Select type (1-2): "; prompt_type "1"
    echo -n "Domain(s) [comma-separated]: "; prompt_type "google.com, youtube.com"
    sleep 0.3

    echo -e "\n${GREEN}[OK]${NC} Rule added: google.com, youtube.com → direct"
    sleep 0.1
}

# --- Main ---
case "${1:-}" in
    __run_setup-gateway) run_setup_gateway ;;
    __run_setup-edge)    run_setup_edge ;;
    __run_user-add)      run_user_add ;;
    __run_status)        run_status ;;
    __run_stats)         run_stats ;;
    __run_test)          run_test ;;
    __run_link-ls)       run_link_ls ;;
    __run_dns-ls)        run_dns_ls ;;
    __run_rule-add)      run_rule_add ;;
    *)
        # Heights must clear each demo's output or the recording scrolls and
        # the top of the frame is lost. Check with:
        #   ./mockup.sh __run_<name> | wc -l
        DEMOS=(
            "setup-gateway:47"
            "setup-edge:38"
            "user-add:29"
            "status:13"
            "stats:12"
            "test:20"
            "link-ls:11"
            "dns-ls:12"
            "rule-add:20"
        )

        for entry in "${DEMOS[@]}"; do
            name="${entry%%:*}"; rows="${entry##*:}"

            # No args: record everything. Otherwise only the named demos.
            if [[ $# -gt 0 ]]; then
                match=0
                for want in "$@"; do [[ "$want" == "$name" ]] && match=1; done
                [[ $match -eq 1 ]] || continue
            fi

            record_demo "$name" "$rows"
        done
        echo ""
        echo "All done!"
        ;;
esac
