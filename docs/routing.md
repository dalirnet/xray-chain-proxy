# Routing Rules

Routing rules allow you to control how traffic flows through your proxy chain. You can specify which destinations should be routed directly, through the proxy, or blocked entirely.

## Available Outbounds

### Gateway Server

| Outbound  | Description                    | Use Case                     |
|-----------|--------------------------------|------------------------------|
| `direct`  | Direct connection to internet  | Normal traffic               |
| `blocked` | Block traffic completely       | Ads, malware, tracking       |

### Edge Server

| Outbound  | Description                    | Use Case                     |
|-----------|--------------------------------|------------------------------|
| `proxy`   | Route through gateway proxy    | Censored content, privacy    |
| `direct`  | Bypass proxy, connect directly | Streaming, local sites       |
| `blocked` | Block traffic at entry point   | Ads, malware before gateway  |

## Rule Types

### Domain Rules

Match traffic by domain name or domain patterns.

**Formats:**
- Simple domain: `google.com`, `facebook.com`
- Domain prefix: `domain:netflix.com` (matches subdomains)
- GeoSite: `geosite:cn`, `geosite:google`, `geosite:category-ads`

**Example:**
```bash
./xcp.sh rule add
# Outbound: direct
# Type: 1 (domain)
# Domains: netflix.com,youtube.com,hulu.com
```

### IP Rules

Match traffic by IP address or CIDR range.

**Formats:**
- Individual IP: `8.8.8.8`, `1.1.1.1`
- CIDR range: `192.168.0.0/16`, `10.0.0.0/8`
- GeoIP: `geoip:us`, `geoip:cn`, `geoip:private`, `geoip:ir`

**Example:**
```bash
./xcp.sh rule add
# Outbound: proxy
# Type: 2 (IP)
# IPs: geoip:cn,geoip:ru
```

## Commands

### List Rules

View all custom routing rules.

```bash
./xcp.sh rule ls
```

**Output:**
```
Routing Rules (edge):

1) → proxy
   Domain: twitter.com, facebook.com

2) → direct
   Domain: netflix.com, youtube.com

3) → blocked
   Domain: geosite:category-ads
```

### Add Rule

Add a new routing rule interactively.

```bash
./xcp.sh rule add
```

**Prompts:**
1. Outbound tag (direct/proxy/blocked)
2. Rule type (1=domain, 2=IP)
3. Values (comma-separated)

![Rule Add](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/rule-add.gif)

### Remove Rule

Remove a routing rule by number.

```bash
./xcp.sh rule rm
```

Shows current rules, prompts for rule number to remove.

## Common Use Cases

### Block Advertisements (Gateway)

Block ad and tracking domains at the gateway exit point.

```bash
./xcp.sh rule add
# Outbound: blocked
# Type: domain
# Value: geosite:category-ads,geosite:category-ads-all
```

### Bypass Proxy for Streaming (Edge)

Route streaming services directly for better speed.

```bash
./xcp.sh rule add
# Outbound: direct
# Type: domain
# Value: netflix.com,hulu.com,youtube.com,disney.com
```

### Route Censored Content (Edge)

Ensure specific domains always go through the gateway proxy.

```bash
./xcp.sh rule add
# Outbound: proxy
# Type: domain
# Value: twitter.com,facebook.com,instagram.com
```

### Block Malware Domains (Edge)

Block known malicious domains at the entry point.

```bash
./xcp.sh rule add
# Outbound: blocked
# Type: domain
# Value: malware.example,phishing.bad,tracker.ads
```

### Route Country-Specific Traffic

Route traffic from specific countries through proxy.

```bash
./xcp.sh rule add
# Outbound: proxy
# Type: IP
# Value: geoip:cn,geoip:ir
```

### Local Network Direct Access (Edge)

Bypass proxy for local network traffic.

```bash
./xcp.sh rule add
# Outbound: direct
# Type: IP
# Value: geoip:private,192.168.0.0/16,10.0.0.0/8
```

## Rule Priority

Rules are evaluated in order. First matching rule wins.

### Gateway

1. **Built-in API rule** - Routes Xray API traffic (127.0.0.1:10085)
2. **Built-in private IP block** - Blocks private IPs (`geoip:private`)
3. **Custom rules** - Your added rules (evaluated top to bottom)
4. **Default** - Remaining traffic routes to `direct` (first outbound)

### Edge

1. **Built-in API rule** - Routes Xray API traffic (127.0.0.1:10085)
2. **Custom rules** - Your added rules (evaluated top to bottom)
3. **Built-in client rule** - Routes all client traffic to `proxy`

**Important:** Custom rules on Edge are evaluated BEFORE the client catch-all rule, allowing you to override the default proxy behavior for specific domains/IPs.

## GeoIP & GeoSite Data

For GeoIP and GeoSite rules to work, download geo data files during Xray installation:

```bash
# During setup, answer 'Y' when prompted:
Download geo data (geoip.dat, geosite.dat)? [Y/n]: Y
```

**Common GeoSite categories:**
- `geosite:category-ads` - Ad domains
- `geosite:category-ads-all` - All ad-related domains
- `geosite:google` - Google services
- `geosite:netflix` - Netflix domains
- `geosite:cn` - Chinese domains

**Common GeoIP codes:**
- `geoip:private` - Private IP ranges
- `geoip:cn` - China
- `geoip:us` - United States
- `geoip:ir` - Iran
- `geoip:ru` - Russia

## Tips

- **Test carefully** - Rules apply immediately after adding
- **Order matters** - More specific rules should come before general ones
- **Use comma separation** - Add multiple values in one rule for efficiency
- **Check logs** - Use `./xcp.sh logs -f` to see routing in action
- **GeoSite for ads** - Use `geosite:category-ads-all` for comprehensive ad blocking
- **Multiple IPs** - Combine GeoIP with specific IPs/ranges in one rule

## Examples Workflow

### Complete Edge Setup for Censorship Bypass

```bash
# 1. Block ads at entry
./xcp.sh rule add
# blocked, domain, geosite:category-ads-all

# 2. Route streaming direct (faster)
./xcp.sh rule add
# direct, domain, netflix.com,youtube.com,spotify.com

# 3. Route censored sites through proxy
./xcp.sh rule add
# proxy, domain, twitter.com,facebook.com,instagram.com

# 4. View configuration
./xcp.sh rule ls

# 5. Test
./xcp.sh test
./xcp.sh logs -f
```

### Gateway Ad Blocking

```bash
# Block ads and tracking at exit
./xcp.sh rule add
# blocked, domain, geosite:category-ads-all

# Block known malware IPs
./xcp.sh rule add
# blocked, IP, 123.45.67.89,98.76.54.32
```
