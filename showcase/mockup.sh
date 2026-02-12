#!/usr/bin/env bash
#
# Generate all showcase GIFs with macOS window frame
#
# Dependencies: asciinema, agg, imagemagick
#
# Usage: ./mockup.sh
#
# Output:
#   setup-gateway.gif
#   setup-edge.gif
#   user-add.gif
#   status.gif
#   stats.gif
#   test.gif
#   rule-add.gif
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Shared ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

QR='█████████████████████████████████████████
█████████████████████████████████████████
████ ▄▄▄▄▄ █   █▄▄ ▀▀██▀▀▄▀█▀█ ▄▄▄▄▄ ████
████ █   █ █ ▀▄ █▄▀ ▄  ▄▄▄▄ ▄█ █   █ ████
████ █▄▄▄█ █▀██▀▀██ ▀█▀ ▀▀█▄▀█ █▄▄▄█ ████
████▄▄▄▄▄▄▄█▄▀▄█ ▀ █▄▀ ▀▄▀▄▀ █▄▄▄▄▄▄▄████
████ ▄▀█ ▄▄▀▀▀▀▄▀  ▀▄▄▀███▄█▄██▄█▄ ▄▄████
████ █▀█▄█▄▄██▀ ▄██▄ ▀ ▀▀ ▀  ▀█▀▄▀▄ ▀████
████▄ ▄█ ▄▄▄█▀▄█▄█ ██ ▄ █▀▄▀▄▀ ▀█▄█▄▄████
████▄▀▄█▀ ▄▄▀ ▄█▀▀ ▀   ██▀ ▄▀▄ ▄  ▄▄█████
█████ ▄ ▀▀▄ ▀▄▄▄  ██▄ ▄██▄ ▀▀▀▄ █▀█ ▄████
████ ▄█▀▀ ▄█▀ ▄ ███▄▀  ▀█ ▀ █▀▄▄▀▄█▀████
████ ▀▀▄ █▄█     ▄▄ ▀█▀ ██ ▀▀▄▄▀█▀█▀█████
█████████▀▄▄▄▄  █▀█▄█ ██▀ █▄█▀█ ██▄ █████
████▄▄██▄▄▄█  █ ▀▄ ▀ ▄▄ ▄ ▄▀ ▄▄▄ ▄▄▀█████
████ ▄▄▄▄▄ █▀██▀▄▀    ▀█▀▀ ▀ █▄█ ████████
████ █   █ █▄█▀▀ █ ▀█ ▄ █ ▄▀ ▄     █▄████
████ █▄▄▄█ █▀▄█▀ ▀▀ █ █▀█ ▀▄▄▀ ▀▄█▄██████
████▄▄▄▄▄▄▄█▄▄▄▄██▄█▄▄▄▄█▄█▄▄▄█▄█▄▄█▄████
█████████████████████████████████████████
█████████████████████████████████████████'

GW_IP="104.28.55.73"; EDGE_IP="185.92.36.110"
SS_PORT="443"; HTTP_PORT="80"; SOCKS_PORT="1080"
DEMO_USER="john"
DEMO_PASS="bT5sD1fG8hY3oK7w"
DEMO_URI="ss://YWVzLTI1Ni1nY206YlQ1c0QxZkc4aFkzb0s3dw==@185.92.36.110:443#john"

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
        ((i++))
    done

    local DELAY_ARGS="" i=0
    while read -r delay; do
        [[ -z "$delay" ]] && delay=10
        DELAY_ARGS="$DELAY_ARGS -delay $delay $TMPDIR/out-$(printf '%04d' $i).png"
        ((i++))
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
    echo -n "Shadowsocks port [443]: "; prompt_default
    echo -n "HTTP proxy port [80]: "; prompt_default
    echo -n "SOCKS5 proxy port [1080]: "; prompt_default
    sleep 0.3

    echo -e "\n${GREEN}GATEWAY Ready!${NC}"
    sleep 0.2
    echo -e "\n${BOLD}Use on EDGE server:${NC}"
    echo -e "  IP:         ${YELLOW}${GW_IP}${NC}"
    echo -e "  SS Port:    ${YELLOW}${SS_PORT}${NC}"
    echo -e "  HTTP Port:  ${YELLOW}${HTTP_PORT}${NC}"
    echo -e "  SOCKS Port: ${YELLOW}${SOCKS_PORT}${NC}"
    echo -e "  Password:   ${YELLOW}Rk7xPm2wQ4nLs9Fj${NC}"
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
    echo -n "Gateway IP: "; prompt_type "$GW_IP"
    echo -n "Gateway port [443]: "; prompt_default
    echo -n "Gateway password: "; prompt_type "********"
    sleep 0.2

    echo -e "\n${BOLD}>>> Edge Settings${NC}"
    sleep 0.2
    echo -n "Shadowsocks port [443]: "; prompt_default
    echo -n "HTTP proxy port [80]: "; prompt_default
    echo -n "SOCKS5 proxy port [1080]: "; prompt_default
    sleep 0.3

    echo -e "\n${GREEN}EDGE Ready!${NC}"
    sleep 0.2
    echo -e "\n${BOLD}Chain:${NC} Client -> ${EDGE_IP} -> ${GW_IP}:${SS_PORT} -> Internet"
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
    echo -e "  SS Port:    ${YELLOW}${SS_PORT}${NC}"
    echo -e "  HTTP Port:  ${YELLOW}${HTTP_PORT}${NC}"
    echo -e "  SOCKS Port: ${YELLOW}${SOCKS_PORT}${NC}"
    echo -e "  Username:   ${YELLOW}${DEMO_USER}${NC}"
    echo -e "  Password:   ${YELLOW}********${NC}\n"
    sleep 0.8
    echo "$QR"
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
    echo -e "${GREEN}● Running${NC}"
    echo "Version: 25.1.30"
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

    echo -e "\n${BOLD}Testing proxy...${NC}\n"
    sleep 0.6
    echo -e "${GREEN}OK${NC} - Exit IP: ${YELLOW}${GW_IP}${NC}"
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

run_rule_add() {
    echo -ne "$PROMPT"
    sleep 0.5
    type_cmd "./xcp.sh rule add"; sleep 0.3; printf '\n'
    sleep 0.3

    echo -e "\n${BOLD}Add Routing Rule${NC}\n"
    sleep 0.3

    echo -e "${BOLD}Available outbounds:${NC}"
    echo "  proxy   - Through gateway proxy"
    echo "  direct  - Direct connection (bypass proxy)"
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
    __run_rule-add)      run_rule_add ;;
    *)
        record_demo "setup-gateway" 26
        record_demo "setup-edge" 26
        record_demo "user-add" 36
        record_demo "status" 8
        record_demo "stats" 12
        record_demo "test" 12
        record_demo "rule-add" 20
        echo ""
        echo "All done!"
        ;;
esac
