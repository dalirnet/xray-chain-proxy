#!/usr/bin/env bash

#
# Xray Chain Proxy - Test Suite
#
# Tests core functionality and JSON operations
#
# Usage:
#   ./test.sh          - Run all tests
#

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Script under test
readonly SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/script.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# --- Test Utilities ---

test_assert() {
    local description="$1"
    local condition="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if eval "$condition"; then
        echo -e "  ${GREEN}✓${NC} $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $description"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

test_section() {
    echo -e "\n${BOLD}${CYAN}>>> $1${NC}"
}

# Run script.sh functions in a clean shell (drops the trailing 'main' call)
xcp_call() {
    local lib="/tmp/xcp-lib-$$.sh"
    sed '$d' "$SCRIPT_PATH" > "$lib"
    bash -c "source '$lib'; $*"
    local rc=$?
    rm -f "$lib"
    return $rc
}

# --- Tests ---

test_json_operations() {
    test_section "Testing JSON Operations"

    local TEST_DIR="/tmp/xcp-test-$$"
    local TEST_JSON="$TEST_DIR/test.json"
    mkdir -p "$TEST_DIR"

    cat > "$TEST_JSON" << 'EOF'
{
  "xcp": {"type": "gateway", "version": "2.0.0"},
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}
    ]
  }
}
EOF

    local server_type=$(jq -r '.xcp.type' "$TEST_JSON")
    test_assert "Read server type" "[[ '$server_type' == 'gateway' ]]" || true

    local rule='{"type":"field","domain":["example.com"],"outboundTag":"direct","xcp_custom":true}'
    jq --argjson rule "$rule" '.routing.rules += [$rule]' "$TEST_JSON" > "$TEST_JSON.tmp" && mv "$TEST_JSON.tmp" "$TEST_JSON"

    local count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$TEST_JSON")
    test_assert "Add custom rule" "[[ '$count' -eq 1 ]]" || true

    local domain=$(jq -r '.routing.rules[] | select(.xcp_custom == true) | .domain[0]' "$TEST_JSON")
    test_assert "Rule content correct" "[[ '$domain' == 'example.com' ]]" || true

    jq '.routing.rules |= map(select(.xcp_custom != true))' "$TEST_JSON" > "$TEST_JSON.tmp" && mv "$TEST_JSON.tmp" "$TEST_JSON"

    count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$TEST_JSON")
    test_assert "Remove custom rule" "[[ '$count' -eq 0 ]]" || true

    rm -rf "$TEST_DIR"
}

test_rule_management() {
    test_section "Testing Rule Management"

    local TEST_DIR="/tmp/xcp-test-$$"
    local TEST_CONFIG="$TEST_DIR/config.json"
    mkdir -p "$TEST_DIR"

    # Gateway - Add blocking rule with domain
    cat > "$TEST_CONFIG" << 'EOF'
{
  "xcp": {"type": "gateway"},
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
    ]
  }
}
EOF

    local new_rule='{"type":"field","domain":["ads.com"],"outboundTag":"blocked","xcp_custom":true}'
    jq --argjson rule "$new_rule" '.routing.rules += [$rule]' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    local count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$TEST_CONFIG")
    test_assert "Gateway: Add domain blocking rule" "[[ '$count' -eq 1 ]]" || true

    local domain=$(jq -r '.routing.rules[] | select(.xcp_custom == true) | .domain[0]' "$TEST_CONFIG")
    test_assert "Gateway: Rule domain is correct" "[[ '$domain' == 'ads.com' ]]" || true

    # Gateway - Add direct rule with IP
    new_rule='{"type":"field","ip":["1.1.1.1"],"outboundTag":"direct","xcp_custom":true}'
    jq --argjson rule "$new_rule" '.routing.rules += [$rule]' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$TEST_CONFIG")
    test_assert "Gateway: Add multiple rules" "[[ '$count' -eq 2 ]]" || true

    # Gateway - Add rule with geosite
    new_rule='{"type":"field","domain":["geosite:category-ads"],"outboundTag":"blocked","xcp_custom":true}'
    jq --argjson rule "$new_rule" '.routing.rules += [$rule]' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    local geosite=$(jq -r '[.routing.rules[] | select(.xcp_custom == true)] | .[2].domain[0]' "$TEST_CONFIG")
    test_assert "Gateway: Add geosite rule" "[[ '$geosite' == 'geosite:category-ads' ]]" || true

    # Edge - Add direct rule
    cat > "$TEST_CONFIG" << 'EOF'
{
  "xcp": {"type": "edge"},
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
      {"type": "field", "inboundTag": ["ss-in"], "outboundTag": "proxy"}
    ]
  }
}
EOF

    new_rule='{"type":"field","domain":["netflix.com"],"outboundTag":"direct","xcp_custom":true}'
    jq --argjson rule "$new_rule" '.routing.rules = (.routing.rules[:-1] + [$rule] + .routing.rules[-1:])' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    local rule_index=$(jq -r '.routing.rules[1].xcp_custom' "$TEST_CONFIG")
    test_assert "Edge: Rule inserted before catch-all" "[[ '$rule_index' == 'true' ]]" || true

    local outbound=$(jq -r '.routing.rules[1].outboundTag' "$TEST_CONFIG")
    test_assert "Edge: Direct outbound set correctly" "[[ '$outbound' == 'direct' ]]" || true

    # Edge - Add geoip:ir rule (should go before catch-all, after first custom rule)
    new_rule='{"type":"field","ip":["geoip:ir"],"outboundTag":"direct","xcp_custom":true}'
    jq --argjson rule "$new_rule" '.routing.rules = (.routing.rules[:-1] + [$rule] + .routing.rules[-1:])' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$TEST_CONFIG")
    test_assert "Edge: Add multiple custom rules" "[[ '$count' -eq 2 ]]" || true

    local geoip=$(jq -r '.routing.rules[2].ip[0]' "$TEST_CONFIG")
    test_assert "Edge: GeoIP rule correct" "[[ '$geoip' == 'geoip:ir' ]]" || true

    # Edge - Add blocked rule (should be inserted before catch-all)
    new_rule='{"type":"field","domain":["malware.com"],"outboundTag":"blocked","xcp_custom":true}'
    jq --argjson rule "$new_rule" '.routing.rules = (.routing.rules[:-1] + [$rule] + .routing.rules[-1:])' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    outbound=$(jq -r '[.routing.rules[] | select(.xcp_custom == true and .domain[0] == "malware.com")] | .[0].outboundTag' "$TEST_CONFIG")
    test_assert "Edge: Blocked outbound set correctly" "[[ '$outbound' == 'blocked' ]]" || true

    # Edge - Verify catch-all is still last
    local last_rule_tag=$(jq -r '.routing.rules[-1].inboundTag[0]' "$TEST_CONFIG")
    test_assert "Edge: Catch-all still last" "[[ '$last_rule_tag' == 'ss-in' ]]" || true

    # Edge - Verify rule order is correct
    local rule_order=$(jq -r '.routing.rules | map(select(.xcp_custom == true) | .outboundTag) | join(",")' "$TEST_CONFIG")
    test_assert "Edge: Rule order maintained" "[[ '$rule_order' == 'direct,direct,blocked' ]]" || true

    # Edge - Test removing middle custom rule while preserving order
    jq --argjson idx 1 '
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
    ' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    count=$(jq '[.routing.rules[] | select(.xcp_custom == true)] | length' "$TEST_CONFIG")
    test_assert "Edge: Remove rule reduces count" "[[ '$count' -eq 2 ]]" || true

    last_rule_tag=$(jq -r '.routing.rules[-1].inboundTag[0]' "$TEST_CONFIG")
    test_assert "Edge: Catch-all still last after removal" "[[ '$last_rule_tag' == 'ss-in' ]]" || true

    rule_order=$(jq -r '.routing.rules | map(select(.xcp_custom == true) | .outboundTag) | join(",")' "$TEST_CONFIG")
    test_assert "Edge: Rule order preserved after removal" "[[ '$rule_order' == 'direct,blocked' ]]" || true

    rm -rf "$TEST_DIR"
}

test_user_management() {
    test_section "Testing User Management"

    local TEST_DIR="/tmp/xcp-test-$$"
    local TEST_CONFIG="$TEST_DIR/config.json"
    mkdir -p "$TEST_DIR"

    cat > "$TEST_CONFIG" << 'EOF'
{
  "inbounds": [
    {
      "tag": "ss-in",
      "settings": {
        "clients": [
          {"email": "user1", "password": "pass1", "method": "aes-256-gcm", "id": "aaaaaaaa-1111-2222-3333-444444444444"}
        ]
      }
    },
    {
      "tag": "vless-in",
      "settings": {
        "clients": [
          {"id": "aaaaaaaa-1111-2222-3333-444444444444", "email": "user1", "flow": "xtls-rprx-vision"}
        ]
      }
    }
  ]
}
EOF

    local user_count=$(jq '.inbounds[] | select(.tag == "ss-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "List users" "[[ '$user_count' -eq 1 ]]" || true

    # Add user
    local client='{"email":"user2","password":"pass2","method":"aes-256-gcm","id":"bbbbbbbb-1111-2222-3333-444444444444"}'
    local vless='{"id":"bbbbbbbb-1111-2222-3333-444444444444","email":"user2","flow":"xtls-rprx-vision"}'

    jq --argjson c "$client" --argjson v "$vless" '
      .inbounds |= map(
        if .tag == "ss-in" then .settings.clients += [$c]
        elif .tag == "vless-in" then .settings.clients += [$v]
        else . end
      )' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    user_count=$(jq '.inbounds[] | select(.tag == "ss-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "Add user" "[[ '$user_count' -eq 2 ]]" || true

    # Remove user
    jq '.inbounds |= map(
      if .tag == "ss-in" or .tag == "vless-in" then .settings.clients |= map(select(.email != "user2"))
      else . end
    )' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    user_count=$(jq '.inbounds[] | select(.tag == "ss-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "Remove user" "[[ '$user_count' -eq 1 ]]" || true

    local vless_count=$(jq '.inbounds[] | select(.tag == "vless-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "Removal reaches VLESS too" "[[ '$vless_count' -eq 1 ]]" || true

    rm -rf "$TEST_DIR"
}

test_ssh_link() {
    test_section "Testing SSH Link"

    local TEST_DIR="/tmp/xcp-test-$$"
    local EDGE="$TEST_DIR/edge.json"
    local GW="$TEST_DIR/gateway.json"
    mkdir -p "$TEST_DIR"

    local clients='[{"email":"default","password":"pass1","method":"aes-256-gcm"}]'

    xcp_call "gen_edge_config 8388 '$clients' 203.0.113.9 2222 xcp" > "$EDGE"
    xcp_call "gen_gateway_config 8388 '$clients'" > "$GW"

    test_assert "Edge config is valid JSON" "jq -e . '$EDGE' >/dev/null" || true
    test_assert "Gateway config is valid JSON" "jq -e . '$GW' >/dev/null" || true

    # Link metadata
    local proto=$(jq -r '.xcp.link.protocol' "$EDGE")
    test_assert "Edge link protocol is ssh" "[[ '$proto' == 'ssh' ]]" || true

    local gw=$(jq -r '"\(.xcp.link.user)@\(.xcp.link.host):\(.xcp.link.port)"' "$EDGE")
    test_assert "Edge stores gateway details" "[[ '$gw' == 'xcp@203.0.113.9:2222' ]]" || true

    # Proxy outbound goes through the tunnel, not shadowsocks
    local proto_out=$(jq -r '.outbounds[] | select(.tag == "proxy") | .protocol' "$EDGE")
    test_assert "Edge proxy outbound is socks" "[[ '$proto_out' == 'socks' ]]" || true

    local target=$(jq -r '.outbounds[] | select(.tag == "proxy") | "\(.settings.servers[0].address):\(.settings.servers[0].port)"' "$EDGE")
    test_assert "Edge proxy targets tunnel port" "[[ '$target' == '127.0.0.1:10080' ]]" || true

    local ss_out=$(jq '[.outbounds[] | select(.protocol == "shadowsocks")] | length' "$EDGE")
    test_assert "Edge has no shadowsocks outbound" "[[ '$ss_out' -eq 0 ]]" || true

    # The tunnel lands on the gateway's loopback SOCKS inbound
    local hook=$(jq -r '.inbounds[] | select(.tag == "tunnel-in") | "\(.listen):\(.port)"' "$GW")
    test_assert "Gateway exposes tunnel landing port" "[[ '$hook' == '127.0.0.1:10080' ]]" || true

    # The edge must leave 10080 free for the ssh -L listener
    local edge_hook=$(jq '[.inbounds[] | select(.port == 10080)] | length' "$EDGE")
    test_assert "Edge keeps tunnel port free" "[[ '$edge_hook' -eq 0 ]]" || true

    # Only Shadowsocks is public here - REALITY is unconfigured in this config,
    # and api, tunnel, dns and the diagnostics SOCKS stay on loopback
    local public=$(jq -r '[.inbounds[] | select(.listen != "127.0.0.1") | .port] | sort | join(",")' "$EDGE")
    test_assert "Edge exposes only 8388" "[[ '$public' == '8388' ]]" || true

    local gw_public=$(jq -r '[.inbounds[] | select(.listen != "127.0.0.1") | .port] | sort | join(",")' "$GW")
    test_assert "Gateway exposes only 8388" "[[ '$gw_public' == '8388' ]]" || true

    # Nothing authenticates with a cleartext credential any more
    local plaintext=$(jq '[.inbounds[] | select(.tag == "http-in" or .tag == "socks-in")] | length' "$GW")
    test_assert "Gateway has no HTTP/SOCKS5 user inbound" "[[ '$plaintext' -eq 0 ]]" || true

    local edge_plaintext=$(jq '[.inbounds[] | select(.tag == "http-in" or .tag == "socks-in")] | length' "$EDGE")
    test_assert "Edge has no HTTP/SOCKS5 user inbound" "[[ '$edge_plaintext' -eq 0 ]]" || true

    # The only SOCKS5 left is no-auth on loopback, for `test` and local curl
    local diag=$(jq -r '.inbounds[] | select(.tag == "local-in") | "\(.listen):\(.port)/\(.settings.auth)"' "$EDGE")
    test_assert "Edge keeps a loopback diagnostics SOCKS" "[[ '$diag' == '127.0.0.1:11080/noauth' ]]" || true

    local gw_diag=$(jq -r '.inbounds[] | select(.tag == "local-in") | "\(.listen):\(.port)/\(.settings.auth)"' "$GW")
    test_assert "Gateway keeps a loopback diagnostics SOCKS" "[[ '$gw_diag' == '127.0.0.1:11080/noauth' ]]" || true

    # Xray leaves 80 to the systemd IP-echo socket, and takes 443 only when
    # REALITY is configured - which these configs are not
    local reserved=$(jq '[.inbounds[] | select(.port == 80 or .port == 443)] | length' "$EDGE")
    test_assert "Edge leaves 80/443 to their own services" "[[ '$reserved' -eq 0 ]]" || true

    local gw_reserved=$(jq '[.inbounds[] | select(.port == 80 or .port == 443)] | length' "$GW")
    test_assert "Gateway leaves 80/443 to their own services" "[[ '$gw_reserved' -eq 0 ]]" || true

    # TCP-only transport handling
    local udp_block=$(jq -r '[.routing.rules[] | select(.network == "udp" and .outboundTag == "blocked")] | length' "$EDGE")
    test_assert "Edge blocks remaining UDP" "[[ '$udp_block' -eq 1 ]]" || true

    local dns_tcp=$(jq -r '.dns.servers[0]' "$EDGE")
    test_assert "Edge resolves DNS over TCP" "[[ '$dns_tcp' == 'tcp://1.1.1.1' ]]" || true

    # Catch-all stays last
    local last=$(jq -r '.routing.rules[-1].outboundTag' "$EDGE")
    test_assert "Edge catch-all is last rule" "[[ '$last' == 'proxy' ]]" || true

    rm -rf "$TEST_DIR"
}

test_dns_service() {
    test_section "Testing DNS Service"

    local TEST_DIR="/tmp/xcp-test-$$"
    local EDGE="$TEST_DIR/edge.json"
    local GW="$TEST_DIR/gateway.json"
    mkdir -p "$TEST_DIR"

    local clients='[{"email":"default","password":"pass1","method":"aes-256-gcm"}]'

    xcp_call "gen_edge_config 8388 '$clients' 203.0.113.9 22 xcp 9.9.9.9" > "$EDGE"
    xcp_call "gen_gateway_config 8388 '$clients' 9.9.9.9" > "$GW"

    # Both server types answer DNS on 53, bound to loopback so neither becomes
    # an open resolver the internet can use for amplification
    local edge_dns=$(jq -r '.inbounds[] | select(.tag == "dns-in") | "\(.listen):\(.port)/\(.settings.network)"' "$EDGE")
    test_assert "Edge serves DNS on loopback 53 tcp+udp" "[[ '$edge_dns' == '127.0.0.1:53/tcp,udp' ]]" || true

    local gw_dns=$(jq -r '.inbounds[] | select(.tag == "dns-in") | "\(.listen):\(.port)/\(.settings.network)"' "$GW")
    test_assert "Gateway serves DNS on loopback 53 tcp+udp" "[[ '$gw_dns' == '127.0.0.1:53/tcp,udp' ]]" || true

    local dns_route=$(jq -r '[.routing.rules[] | select(.inboundTag == ["dns-in"] and .outboundTag == "dns-out")] | length' "$EDGE")
    test_assert "Edge routes dns-in to dns-out" "[[ '$dns_route' -eq 1 ]]" || true

    # Client UDP DNS is converted to TCP; the resolver's own TCP queries must not
    # match a port-53 rule or they would loop back into dns-out
    local dns_udp=$(jq -r '[.routing.rules[] | select(.port == 53)] | map(.network) | join(",")' "$EDGE")
    test_assert "Edge port-53 rule is UDP only" "[[ '$dns_udp' == 'udp' ]]" || true

    # Chosen resolver reaches both the dns block and the redirect target
    test_assert "Edge stores chosen resolver" "[[ \"\$(jq -r '.xcp.dns' '$EDGE')\" == '9.9.9.9' ]]" || true
    test_assert "Edge queries it over TCP" "[[ \"\$(jq -r '.dns.servers[0]' '$EDGE')\" == 'tcp://9.9.9.9' ]]" || true
    test_assert "Gateway queries it over UDP" "[[ \"\$(jq -r '.dns.servers[0]' '$GW')\" == '9.9.9.9' ]]" || true
    test_assert "Redirect target is the resolver" \
        "[[ \"\$(jq -r '.inbounds[] | select(.tag == \"dns-in\") | .settings.address' '$EDGE')\" == '9.9.9.9' ]]" || true

    # DoH: kept verbatim for the dns block, redirect falls back to a plain IP
    xcp_call "gen_edge_config 8388 '$clients' 203.0.113.9 22 xcp https://dns.google/dns-query" > "$EDGE"
    test_assert "DoH resolver kept verbatim" \
        "[[ \"\$(jq -r '.dns.servers[0]' '$EDGE')\" == 'https://dns.google/dns-query' ]]" || true
    test_assert "DoH redirect falls back to an IP" \
        "[[ \"\$(jq -r '.inbounds[] | select(.tag == \"dns-in\") | .settings.address' '$EDGE')\" == '1.1.1.1' ]]" || true

    # Resolver validation
    test_assert "Accepts plain IP" "xcp_call \"validate_dns 8.8.8.8\"" || true
    test_assert "Accepts tcp:// resolver" "xcp_call \"validate_dns tcp://8.8.8.8\"" || true
    test_assert "Accepts DoH URL" "xcp_call \"validate_dns https://dns.google/dns-query\"" || true
    test_assert "Rejects garbage" "! xcp_call \"validate_dns 'not a resolver'\"" || true

    rm -rf "$TEST_DIR"
}

test_rule_insertion() {
    test_section "Testing Rule Insertion"

    local TEST_DIR="/tmp/xcp-test-$$"
    local CONFIG="$TEST_DIR/config.json"
    mkdir -p "$TEST_DIR"

    # Current layout: tail rules marked with xcp_tail
    cat > "$CONFIG" << 'EOF'
{
  "routing": {
    "rules": [
      {"outboundTag": "api"},
      {"outboundTag": "dns-out"},
      {"outboundTag": "blocked", "xcp_tail": true},
      {"outboundTag": "proxy", "xcp_tail": true}
    ]
  }
}
EOF

    local new='{"type":"field","domain":["netflix.com"],"outboundTag":"direct","xcp_custom":true}'
    xcp_call "jq --argjson n '$new' \"\$JQ_INSERT_RULES insert_rules([\\\$n])\" '$CONFIG'" > "$CONFIG.out"

    local order=$(jq -r '[.routing.rules[].outboundTag] | join(",")' "$CONFIG.out")
    test_assert "Rule lands before tail rules" "[[ '$order' == 'api,dns-out,direct,blocked,proxy' ]]" || true

    # Legacy layout: no xcp_tail markers, insert before the last rule
    cat > "$CONFIG" << 'EOF'
{
  "routing": {
    "rules": [
      {"outboundTag": "api"},
      {"outboundTag": "proxy"}
    ]
  }
}
EOF

    xcp_call "jq --argjson n '$new' \"\$JQ_INSERT_RULES insert_rules([\\\$n])\" '$CONFIG'" > "$CONFIG.out"

    order=$(jq -r '[.routing.rules[].outboundTag] | join(",")' "$CONFIG.out")
    test_assert "Legacy config falls back correctly" "[[ '$order' == 'api,direct,proxy' ]]" || true

    rm -rf "$TEST_DIR"
}

test_link_hardening() {
    test_section "Testing Link Hardening"

    local opts
    opts=$(xcp_call "ssh_opts")

    # Keepalives every 10s, three strikes - a dead socket surfaces in 30s
    test_assert "Keepalive interval is 10s" "[[ '$opts' == *'ServerAliveInterval=10'* ]]" || true
    test_assert "Keepalive gives up after 3" "[[ '$opts' == *'ServerAliveCountMax=3'* ]]" || true

    # OpenSSH marks packets af21/cs1 by default, which is both a signature and a
    # way into a differently shaped queue
    test_assert "DSCP marking is off" "[[ '$opts' == *'IPQoS=none'* ]]" || true

    test_assert "Cipher is pinned" "[[ '$opts' == *'-c '* ]]" || true

    local cipher
    cipher=$(xcp_call "ssh_cipher")
    test_assert "Cipher is one of the two fast ones" \
        "[[ '$cipher' == 'aes128-gcm@openssh.com' || '$cipher' == 'chacha20-poly1305@openssh.com' ]]" || true

    # Password login only - the tunnel user has no key and no agent
    test_assert "Password auth only" "[[ '$opts' == *'PubkeyAuthentication=no'* ]]" || true
}

test_reality() {
    test_section "Testing VLESS + REALITY"

    local TEST_DIR="/tmp/xcp-test-$$"
    local EDGE="$TEST_DIR/edge.json"
    local GW="$TEST_DIR/gateway.json"
    mkdir -p "$TEST_DIR"

    local uuid='11111111-2222-3333-4444-555555555555'
    local clients="[{\"email\":\"john\",\"password\":\"p1\",\"method\":\"aes-256-gcm\",\"id\":\"${uuid}\"}]"
    local reality='{"port":443,"dest":"www.microsoft.com","privateKey":"PRIV","publicKey":"PUB","shortId":"0123456789abcdef"}'

    xcp_call "gen_gateway_config 8388 '$clients' 1.1.1.1 '$reality'" > "$GW"
    xcp_call "gen_edge_config 8388 '$clients' 203.0.113.9 22 xcp 1.1.1.1 '$reality'" > "$EDGE"

    test_assert "Gateway config is valid JSON" "jq -e . '$GW' >/dev/null" || true
    test_assert "Edge config is valid JSON" "jq -e . '$EDGE' >/dev/null" || true

    # REALITY takes 443 - the port that makes borrowing a real site convincing
    local vless=$(jq -r '.inbounds[] | select(.tag == "vless-in") | "\(.port)/\(.protocol)/\(.streamSettings.security)"' "$GW")
    test_assert "Gateway serves VLESS+REALITY on 443" "[[ '$vless' == '443/vless/reality' ]]" || true

    local edge_vless=$(jq -r '.inbounds[] | select(.tag == "vless-in") | "\(.port)/\(.protocol)/\(.streamSettings.security)"' "$EDGE")
    test_assert "Edge serves VLESS+REALITY on 443" "[[ '$edge_vless' == '443/vless/reality' ]]" || true

    # dest carries a port, serverNames does not - mixing them breaks the handshake
    local dest=$(jq -r '.inbounds[] | select(.tag == "vless-in") | .streamSettings.realitySettings.dest' "$GW")
    test_assert "dest includes the TLS port" "[[ '$dest' == 'www.microsoft.com:443' ]]" || true

    local sni=$(jq -r '.inbounds[] | select(.tag == "vless-in") | .streamSettings.realitySettings.serverNames[0]' "$GW")
    test_assert "serverNames is the bare host" "[[ '$sni' == 'www.microsoft.com' ]]" || true

    # flow must match on both ends, and only works over plain TCP
    local flow=$(jq -r '.inbounds[] | select(.tag == "vless-in") | .settings.clients[0].flow' "$GW")
    test_assert "Client flow is xtls-rprx-vision" "[[ '$flow' == 'xtls-rprx-vision' ]]" || true

    local net=$(jq -r '.inbounds[] | select(.tag == "vless-in") | .streamSettings.network' "$GW")
    test_assert "Transport is TCP" "[[ '$net' == 'tcp' ]]" || true

    # The private key stays in the inbound; the rest is public and reusable
    local meta=$(jq -c '.xcp.reality' "$GW")
    test_assert "xcp.reality keeps the public half" \
        "[[ '$meta' == '{\"port\":443,\"dest\":\"www.microsoft.com\",\"publicKey\":\"PUB\",\"shortId\":\"0123456789abcdef\"}' ]]" || true

    test_assert "Private key stays out of xcp" "! jq -e '.xcp.reality.privateKey' '$GW' >/dev/null 2>&1" || true

    local priv=$(jq -r '.inbounds[] | select(.tag == "vless-in") | .streamSettings.realitySettings.privateKey' "$GW")
    test_assert "Private key lives in the inbound" "[[ '$priv' == 'PRIV' ]]" || true

    # Edge routes VLESS through the tunnel like every other client protocol
    local tail=$(jq -c '.routing.rules[-1].inboundTag' "$EDGE")
    test_assert "Edge routes vless-in to the gateway" "[[ '$tail' == *'vless-in'* ]]" || true

    # 443 is public on both roles
    local gw_public=$(jq -r '[.inbounds[] | select(.listen != "127.0.0.1") | .port] | sort | join(",")' "$GW")
    test_assert "Gateway exposes 443 and 8388" "[[ '$gw_public' == '443,8388' ]]" || true

    # Share URI carries everything a client needs
    local uri=$(xcp_call "gen_vless_uri '$uuid' 5.6.7.8 '$reality' john")
    test_assert "URI targets the REALITY port" "[[ '$uri' == 'vless://'*'@5.6.7.8:443?'* ]]" || true
    test_assert "URI carries the public key" "[[ '$uri' == *'pbk=PUB'* ]]" || true
    test_assert "URI carries the shortId" "[[ '$uri' == *'sid=0123456789abcdef'* ]]" || true
    test_assert "URI carries the flow" "[[ '$uri' == *'flow=xtls-rprx-vision'* ]]" || true
    test_assert "URI carries the SNI" "[[ '$uri' == *'sni=www.microsoft.com'* ]]" || true
    test_assert "URI mimics a Chrome handshake" "[[ '$uri' == *'fp=chrome'* ]]" || true

    # One account spans both protocols - the same jq user_add and user_rm run
    local new_uuid='99999999-8888-7777-6666-555555555555'
    jq --arg e "alice" --arg p "pw" --arg m "aes-256-gcm" --arg id "$new_uuid" --arg f "xtls-rprx-vision" \
        '.inbounds |= map(
            if .tag == "ss-in" then .settings.clients += [{"email":$e,"password":$p,"method":$m,"id":$id}]
            elif .tag == "vless-in" then .settings.clients += [{"id":$id,"email":$e,"flow":$f}]
            else . end
        )' "$GW" > "$GW.tmp" && mv "$GW.tmp" "$GW"

    local spread=$(jq -c '[.inbounds[]
        | select(.tag == "ss-in" or .tag == "vless-in")
        | .settings.clients | length] | unique' "$GW")
    test_assert "Adding a user reaches both protocols" "[[ '$spread' == '[2]' ]]" || true

    local same_id=$(jq -r '[.inbounds[]
        | select(.tag == "ss-in" or .tag == "vless-in")
        | .settings.clients[] | select(.email == "alice") | .id] | unique | length' "$GW")
    test_assert "Shadowsocks and VLESS share one uuid" "[[ '$same_id' -eq 1 ]]" || true

    jq --arg e "alice" \
        '.inbounds |= map(
            if .tag == "ss-in" or .tag == "vless-in" then .settings.clients |= map(select(.email != $e))
            else . end
        )' "$GW" > "$GW.tmp" && mv "$GW.tmp" "$GW"

    local left=$(jq -c '[.inbounds[]
        | select(.tag == "ss-in" or .tag == "vless-in")
        | .settings.clients | length] | unique' "$GW")
    test_assert "Removing a user clears both protocols" "[[ '$left' == '[1]' ]]" || true

    # Without REALITY the inbound is absent and the rest of the config still stands
    xcp_call "gen_gateway_config 8388 '$clients' 1.1.1.1" > "$GW"
    test_assert "Config without REALITY is valid JSON" "jq -e . '$GW' >/dev/null" || true

    local none=$(jq '[.inbounds[] | select(.tag == "vless-in")] | length' "$GW")
    test_assert "No REALITY means no vless inbound" "[[ '$none' -eq 0 ]]" || true
    test_assert "No REALITY means null metadata" "[[ \"\$(jq -r '.xcp.reality' '$GW')\" == 'null' ]]" || true

    # Accounts predating REALITY have no uuid and stay on the other protocols
    local legacy='[{"email":"old","password":"p2","method":"aes-256-gcm"}]'
    xcp_call "gen_gateway_config 8388 '$legacy' 1.1.1.1 '$reality'" > "$GW"
    test_assert "Legacy account config is valid JSON" "jq -e . '$GW' >/dev/null" || true

    local legacy_clients=$(jq '[.inbounds[] | select(.tag == "vless-in") | .settings.clients[]] | length' "$GW")
    test_assert "Account without a uuid skips VLESS" "[[ '$legacy_clients' -eq 0 ]]" || true

    test_assert "No URI without a uuid" "[[ -z \"\$(xcp_call \"gen_vless_uri '' 5.6.7.8 '$reality' old\")\" ]]" || true

    rm -rf "$TEST_DIR"
}

test_ip_echo() {
    test_section "Testing IP Echo (port 80)"

    local lib="/tmp/xcp-echo-lib-$$.sh"
    sed '$d' "$SCRIPT_PATH" > "$lib"

    # $lib is in scope here - bash locals are visible to functions it calls
    run_echo() {
        printf 'GET / HTTP/1.1\r\n\r\n' | REMOTE_ADDR="$1" bash -c "source '$lib'; web_respond" 2>/dev/null
    }

    local out
    out=$(run_echo "5.6.7.8")
    test_assert "Answers 200" "[[ '$out' == 'HTTP/1.1 200 OK'* ]]" || true
    test_assert "Body is the caller's IP" "[[ '$out' == *'5.6.7.8'* ]]" || true
    test_assert "Closes the connection" "[[ '$out' == *'Connection: close'* ]]" || true

    # IPv4 on a dual-stack socket arrives mapped - the client wants the bare form
    out=$(run_echo "::ffff:203.0.113.9")
    test_assert "Strips the IPv6-mapped prefix" "[[ '$out' == *$'\r\n\r\n203.0.113.9'* ]]" || true

    # A mismatched Content-Length leaves the client waiting for bytes that never come
    local len
    len=$(run_echo "203.0.113.9" | grep -i '^Content-Length:' | tr -d '\r' | awk '{print $2}')
    test_assert "Content-Length matches the body" "[[ '$len' -eq $(printf '203.0.113.9\n' | wc -c) ]]" || true

    # Headers must end with CRLF or strict clients reject the response
    test_assert "Headers use CRLF" "[[ \"\$(run_echo 5.6.7.8 | head -1 | od -c | grep -c '\\\\r')\" -ge 1 ]]" || true

    # systemd sets REMOTE_ADDR; without it the responder still answers cleanly
    out=$(printf 'GET / HTTP/1.1\r\n\r\n' | bash -c "source '$lib'; unset REMOTE_ADDR; web_respond" 2>/dev/null)
    test_assert "Answers even without REMOTE_ADDR" "[[ '$out' == 'HTTP/1.1 200 OK'* ]]" || true

    rm -f "$lib"
}

test_dns_access() {
    test_section "Testing DNS Access"

    local TEST_DIR="/tmp/xcp-test-$$"
    local CONFIG="$TEST_DIR/config.json"
    mkdir -p "$TEST_DIR"

    # Addresses only - a firewall rule needs something that cannot resolve
    # somewhere else tomorrow
    test_assert "Accepts a plain IP" "xcp_call \"validate_cidr 1.2.3.4\"" || true
    test_assert "Accepts a CIDR block" "xcp_call \"validate_cidr 1.2.3.0/24\"" || true
    test_assert "Accepts /32" "xcp_call \"validate_cidr 1.2.3.4/32\"" || true
    test_assert "Rejects /33" "! xcp_call \"validate_cidr 1.2.3.4/33\"" || true
    test_assert "Rejects a bad octet" "! xcp_call \"validate_cidr 1.2.3.256\"" || true
    test_assert "Rejects a domain" "! xcp_call \"validate_cidr example.com\"" || true
    test_assert "Rejects a short address" "! xcp_call \"validate_cidr 1.2.3\"" || true
    test_assert "Rejects a non-numeric prefix" "! xcp_call \"validate_cidr 1.2.3.4/abc\"" || true

    # "Status: inactive" contains "active", so a loose match reports a firewall
    # that is filtering nothing - and the allowlist would be enforced by nobody
    test_assert "Inactive ufw reads as inactive" \
        "! echo 'Status: inactive' | grep -q '^Status: active'" || true
    test_assert "Active ufw reads as active" \
        "echo 'Status: active' | grep -q '^Status: active'" || true

    # An empty list keeps the resolver on loopback
    echo '{"xcp":{"type":"edge"},"inbounds":[{"tag":"dns-in","listen":"0.0.0.0","port":53}]}' > "$CONFIG"
    xcp_call "dns_apply_access '$CONFIG'" &>/dev/null || true
    test_assert "No allowed clients means loopback" \
        "[[ \"\$(jq -r '.inbounds[0].listen' '$CONFIG')\" == '127.0.0.1' ]]" || true

    # With clients listed but no firewall running, it stays on loopback rather
    # than trusting a list nothing enforces
    echo '{"xcp":{"type":"edge","dns_allow":["1.2.3.4"]},"inbounds":[{"tag":"dns-in","listen":"0.0.0.0","port":53}]}' > "$CONFIG"
    xcp_call "firewall_active() { return 1; }; dns_apply_access '$CONFIG'" &>/dev/null || true
    test_assert "Inactive firewall forces loopback" \
        "[[ \"\$(jq -r '.inbounds[0].listen' '$CONFIG')\" == '127.0.0.1' ]]" || true

    # With both a list and an enforcing firewall, it opens up
    echo '{"xcp":{"type":"edge","dns_allow":["1.2.3.4"]},"inbounds":[{"tag":"dns-in","listen":"127.0.0.1","port":53}]}' > "$CONFIG"
    xcp_call "firewall_active() { return 0; }; dns_apply_access '$CONFIG'" &>/dev/null || true
    test_assert "Allowed clients plus a firewall opens the bind" \
        "[[ \"\$(jq -r '.inbounds[0].listen' '$CONFIG')\" == '0.0.0.0' ]]" || true

    # The list survives a gateway change, which rebuilds the config from scratch
    local clients='[{"email":"a","password":"p","method":"aes-256-gcm"}]'
    xcp_call "gen_edge_config 8388 '$clients' 1.2.3.4 22 xcp" > "$CONFIG"
    test_assert "Generated config starts on loopback" \
        "[[ \"\$(jq -r '.inbounds[] | select(.tag == \"dns-in\") | .listen' '$CONFIG')\" == '127.0.0.1' ]]" || true

    rm -rf "$TEST_DIR"
}

test_firewall() {
    test_section "Testing Firewall Rules"

    local LOG="/tmp/xcp-ufw-$$.log"

    # Capture what ufw would be asked to do
    local harness="firewall_active() { return 0; }
        ufw() { echo \"ufw \$*\" >> '$LOG'; }
        log_info() { :; }"

    : > "$LOG"
    xcp_call "$harness; configure_firewall 80 443 8388 8388/udp" &>/dev/null || true

    test_assert "Bare port opens TCP" "grep -q 'ufw allow 80/tcp' '$LOG'" || true
    test_assert "port/proto is honoured" "grep -q 'ufw allow 8388/udp' '$LOG'" || true

    # Only Shadowsocks carries UDP - REALITY is streamSettings.network=tcp, the
    # port 80 responder is a ListenStream socket, and SSH is TCP. A blanket
    # tcp+udp open would widen the surface for nothing.
    test_assert "REALITY port gets no UDP rule" "! grep -q 'ufw allow 443/udp' '$LOG'" || true
    test_assert "IP echo port gets no UDP rule" "! grep -q 'ufw allow 80/udp' '$LOG'" || true
    test_assert "One rule per argument" "[[ \$(grep -c 'ufw allow' '$LOG') -eq 4 ]]" || true

    # An inactive firewall writes nothing rather than reporting rules it did not make
    : > "$LOG"
    xcp_call "firewall_active() { return 1; }
        ufw() { echo \"ufw \$*\" >> '$LOG'; }
        configure_firewall 80 8388/udp" &>/dev/null || true
    test_assert "Inactive firewall writes no rules" "[[ ! -s '$LOG' ]]" || true

    # The inbound settings the rules are derived from
    local clients='[{"email":"a","password":"p","method":"aes-256-gcm","id":"aa-bb"}]'
    local reality='{"port":443,"dest":"a.com","privateKey":"P","publicKey":"K","shortId":"ab"}'
    local CFG="/tmp/xcp-fw-$$.json"
    xcp_call "gen_gateway_config 8388 '$clients' 1.1.1.1 '$reality'" > "$CFG"

    test_assert "Shadowsocks accepts TCP and UDP" \
        "[[ \"\$(jq -r '.inbounds[]|select(.tag==\"ss-in\")|.settings.network' '$CFG')\" == 'tcp,udp' ]]" || true
    test_assert "REALITY is TCP only" \
        "[[ \"\$(jq -r '.inbounds[]|select(.tag==\"vless-in\")|.streamSettings.network' '$CFG')\" == 'tcp' ]]" || true
    test_assert "DNS accepts TCP and UDP" \
        "[[ \"\$(jq -r '.inbounds[]|select(.tag==\"dns-in\")|.settings.network' '$CFG')\" == 'tcp,udp' ]]" || true

    rm -f "$LOG" "$CFG"
}

test_port_preflight() {
    test_section "Testing Port Preflight"

    local BUSY='tcp LISTEN 0 4096 0.0.0.0:8388 0.0.0.0:* users:(("nginx",pid=999,fd=6))'

    test_assert "Sees a port in use" \
        "xcp_call \"ss() { echo '$BUSY'; }; port_taken 8388\"" || true
    test_assert "Sees a free port as free" \
        "! xcp_call \"ss() { echo '$BUSY'; }; port_taken 443\"" || true

    # Without ss the answer is unknown - reporting a clash would block setup on
    # a machine that is actually fine
    test_assert "No ss means no claimed clash" \
        "! xcp_call \"PATH=/nonexistent; port_taken 8388\"" || true

    # Free ports pass silently
    test_assert "All free passes" \
        "xcp_call \"systemctl() { :; }; ss() { echo ''; }; preflight_ports 443 8388\"" || true

    # A clash aborts rather than letting Xray fail to start later with no reason
    test_assert "A clash aborts setup" \
        "! xcp_call \"systemctl() { :; }; ss() { echo '$BUSY'; }; preflight_ports 443 8388\" 2>/dev/null" || true

    # Captured rather than piped: preflight exits non-zero by design, and a
    # `| grep -q` would report that exit (or SIGPIPE) instead of the match
    local msg
    msg=$(xcp_call "systemctl() { :; }; ss() { echo '$BUSY'; }; preflight_ports 8388" 2>&1 || true)
    test_assert "The clash names the port" "[[ '$msg' == *8388* ]]" || true
    test_assert "The clash names the holder" "[[ '$msg' == *nginx* ]]" || true

    # The diagnostic port stays off the 1008x block, where 10085 is the Xray API
    # convention and its neighbours get taken by panels and second instances
    local sp
    sp=$(grep -oE '^readonly LOCAL_SOCKS_PORT=[0-9]+' "$SCRIPT_PATH" | grep -oE '[0-9]+')
    test_assert "Diagnostic port avoids the Xray API block" \
        "[[ '$sp' -lt 10080 || '$sp' -gt 10089 ]]" || true
    test_assert "Diagnostic port is below the ephemeral range" "[[ '$sp' -lt 32768 ]]" || true

    # Loopback ports must not collide with each other
    local ports
    ports=$(grep -oE '^readonly (TUNNEL_PORT|API_PORT|LOCAL_SOCKS_PORT)=[0-9]+' "$SCRIPT_PATH" | grep -oE '[0-9]+$' | sort)
    test_assert "Loopback ports are distinct" \
        "[[ \$(echo '$ports' | wc -l) -eq \$(echo '$ports' | sort -u | wc -l) ]]" || true
}

test_pipefail_paths() {
    test_section "Testing set -e / pipefail Paths"

    # The script runs under `set -euo pipefail`. A non-matching grep inside a
    # command substitution fails the whole substitution, which aborts the script
    # before any guard below it can report a useful reason. These lock in the
    # places where that would otherwise turn a bad input into a silent exit.

    local lib="/tmp/xcp-pf-$$.sh"
    sed '$d' "$SCRIPT_PATH" | sed 's#^readonly XRAY_BIN=.*#readonly XRAY_BIN="/tmp/xcp-pf-xray-'$$'"#' > "$lib"
    local fake="/tmp/xcp-pf-xray-$$"

    # Unrecognised x25519 output must say so rather than exit silently
    printf '#!/bin/sh\nprintf "unexpected\\n"\n' > "$fake"; chmod +x "$fake"
    local out
    out=$(bash -c "source '$lib'; reality_keys" 2>&1 || true)
    # Compared via a flag: the message embeds quoted paths, which would break
    # an eval'd condition that interpolated it directly
    local got=no; [[ "$out" == *"unexpected output format"* ]] && got=yes
    test_assert "Bad x25519 output explains itself" "[[ '$got' == yes ]]" || true

    printf '#!/bin/sh\nprintf "Private key: P1\\nPublic key: K1\\n"\n' > "$fake"
    out=$(bash -c "source '$lib'; reality_keys" 2>&1 || true)
    test_assert "v24 key format still parses" "[[ '$out' == 'P1 K1' ]]" || true

    printf '#!/bin/sh\nprintf "PrivateKey: P2\\nPassword: K2\\n"\n' > "$fake"
    out=$(bash -c "source '$lib'; reality_keys" 2>&1 || true)
    test_assert "v25 key format still parses" "[[ '$out' == 'P2 K2' ]]" || true

    # link_quality reports, it does not test - a socket without counters must
    # not take `status` down with it
    out=$(bash -c "set -euo pipefail; source '$lib'
        ss(){ echo 'ESTAB 0 0 a:22 b:33'; }
        link_quality 1.2.3.4; echo READY" 2>&1 || true)
    got=no; [[ "$out" == *READY* ]] && got=yes
    test_assert "Missing rtt counters do not abort status" "[[ '$got' == yes ]]" || true

    out=$(bash -c "set -euo pipefail; source '$lib'
        ss(){ echo 'ESTAB 0 0 a:22 b:33 rtt:47.3/2.1 retrans:0/1841'; }
        link_quality 1.2.3.4" 2>&1 || true)
    got=no; [[ "$out" == *47.3/2.1* && "$out" == *0/1841* ]] && got=yes
    test_assert "Present counters still render" "[[ '$got' == yes ]]" || true

    # The port 80 responder must consume the whole request head: leaving bytes
    # unread makes the kernel send RST instead of FIN, which can lose the reply
    local left
    left=$(printf 'GET / HTTP/1.1\r\nHost: x\r\nUser-Agent: c\r\nAccept: */*\r\n\r\n' | \
        bash -c "source '$lib'; REMOTE_ADDR=1.2.3.4 web_respond >/dev/null; cat" 2>/dev/null || true)
    test_assert "Responder drains the full request" "[[ -z '$left' ]]" || true

    # A client that closes without the blank terminator must not hang a worker
    out=$(printf 'GET / HTTP/1.1\r\n' | bash -c "source '$lib'; REMOTE_ADDR=9.9.9.9 web_respond" 2>&1 || true)
    got=no; [[ "$out" == "HTTP/1.1 200 OK"* ]] && got=yes
    test_assert "Truncated request still answers" "[[ '$got' == yes ]]" || true

    rm -f "$lib" "$fake"
}

test_config_write() {
    test_section "Testing Config Writes"

    local TEST_DIR="/tmp/xcp-test-$$"
    local CONFIG="$TEST_DIR/config.json"
    mkdir -p "$TEST_DIR"

    echo '{"keep":"original"}' > "$CONFIG"
    xcp_call "echo '{\"keep\":\"replaced\"}' | config_write '$CONFIG'" &>/dev/null || true
    test_assert "Valid JSON replaces the config" \
        "[[ \"\$(jq -r '.keep' '$CONFIG')\" == 'replaced' ]]" || true

    # A jq that dies partway still writes something to the pipe, so the guard is
    # what stops a truncated config from being installed
    xcp_call "printf '{\"keep\": tru' | config_write '$CONFIG'" &>/dev/null || true
    test_assert "Truncated JSON leaves the original in place" \
        "[[ \"\$(jq -r '.keep' '$CONFIG')\" == 'replaced' ]]" || true

    xcp_call "printf '' | config_write '$CONFIG'" &>/dev/null || true
    test_assert "Empty output leaves the original in place" \
        "[[ \"\$(jq -r '.keep' '$CONFIG')\" == 'replaced' ]]" || true

    test_assert "Config stays valid JSON throughout" "jq -e . '$CONFIG' >/dev/null" || true

    rm -rf "$TEST_DIR"
}

test_version_sync() {
    test_section "Testing Version Sync"

    local TEST_DIR="/tmp/xcp-test-$$"
    local CONFIG="$TEST_DIR/config.json"
    mkdir -p "$TEST_DIR"

    # Config stamped by an older script version
    echo '{"xcp":{"type":"edge","version":"2.0.0"},"outbounds":[]}' > "$CONFIG"

    xcp_call "sync_config_version 3.1.0 '$CONFIG'"
    local version=$(jq -r '.xcp.version' "$CONFIG")
    test_assert "Update stamps new version into config" "[[ '$version' == '3.1.0' ]]" || true

    local type=$(jq -r '.xcp.type' "$CONFIG")
    test_assert "Version sync keeps other xcp fields" "[[ '$type' == 'edge' ]]" || true

    # Config predating the xcp block
    echo '{"outbounds":[]}' > "$CONFIG"
    xcp_call "sync_config_version 3.1.0 '$CONFIG'"
    version=$(jq -r '.xcp.version' "$CONFIG")
    test_assert "Version sync creates missing xcp block" "[[ '$version' == '3.1.0' ]]" || true

    # Missing config is a no-op, not an error
    rm -f "$CONFIG"
    test_assert "Version sync skips missing config" \
        "xcp_call \"sync_config_version 3.1.0 '$CONFIG'\"" || true

    rm -rf "$TEST_DIR"
}

# --- Main ---

show_results() {
    echo -e "\n${BOLD}=== Test Results ===${NC}"
    echo -e "Total:  ${CYAN}$TESTS_RUN${NC}"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}${BOLD}✓ All tests passed!${NC}\n"
        return 0
    else
        echo -e "\n${RED}${BOLD}✗ Some tests failed${NC}\n"
        return 1
    fi
}

main() {
    echo -e "${BOLD}${CYAN}"
    echo "================================"
    echo "  Xray Chain Proxy Test Suite"
    echo "================================"
    echo -e "${NC}"

    command -v jq &>/dev/null || { echo -e "${RED}Error: jq is required${NC}"; exit 1; }

    test_json_operations
    test_rule_management
    test_rule_insertion
    test_user_management
    test_ssh_link
    test_link_hardening
    test_reality
    test_ip_echo
    test_dns_service
    test_dns_access
    test_firewall
    test_port_preflight
    test_pipefail_paths
    test_config_write
    test_version_sync

    show_results
}

main "$@"
