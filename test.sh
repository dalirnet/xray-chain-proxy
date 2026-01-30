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

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# --- Test Utilities ---

test_assert() {
    local description="$1"
    local condition="$2"

    ((TESTS_RUN++))

    if eval "$condition"; then
        echo -e "  ${GREEN}✓${NC} $description"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "  ${RED}✗${NC} $description"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_section() {
    echo -e "\n${BOLD}${CYAN}>>> $1${NC}"
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
          {"email": "user1", "password": "pass1", "method": "aes-256-gcm"}
        ]
      }
    },
    {
      "tag": "http-in",
      "settings": {
        "accounts": [
          {"user": "user1", "pass": "pass1"}
        ]
      }
    }
  ]
}
EOF

    local user_count=$(jq '.inbounds[] | select(.tag == "ss-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "List users" "[[ '$user_count' -eq 1 ]]" || true

    # Add user
    local client='{"email":"user2","password":"pass2","method":"aes-256-gcm"}'
    local account='{"user":"user2","pass":"pass2"}'

    jq --argjson c "$client" --argjson a "$account" '
      .inbounds |= map(
        if .tag == "ss-in" then .settings.clients += [$c]
        elif .tag == "http-in" then .settings.accounts += [$a]
        else . end
      )' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    user_count=$(jq '.inbounds[] | select(.tag == "ss-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "Add user" "[[ '$user_count' -eq 2 ]]" || true

    # Remove user
    jq '.inbounds |= map(
      if .tag == "ss-in" then .settings.clients |= map(select(.email != "user2"))
      elif .tag == "http-in" then .settings.accounts |= map(select(.user != "user2"))
      else . end
    )' "$TEST_CONFIG" > "$TEST_CONFIG.tmp" && mv "$TEST_CONFIG.tmp" "$TEST_CONFIG"

    user_count=$(jq '.inbounds[] | select(.tag == "ss-in") | .settings.clients | length' "$TEST_CONFIG")
    test_assert "Remove user" "[[ '$user_count' -eq 1 ]]" || true

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
    test_user_management

    show_results
}

main "$@"
