#!/bin/bash
# =============================================================================
# portal_firewall.sh
# CQ Simple LLC — WireGuard Traffic Whitelist
#
# Restricts VPN users (wg0) to only reach IPs listed as Vultr instances
# in the portal database. All other HTTP is redirected to a warning page.
# All other HTTPS is rejected immediately.
#
# Called automatically by generate_instances.sh after page generation.
# Can also be run manually: sudo bash /usr/local/bin/portal_firewall.sh
#
# Install: cp portal_firewall.sh /usr/local/bin/ && chmod +x /usr/local/bin/portal_firewall.sh
# =============================================================================

set -euo pipefail

DB_HOST="localhost"
DB_USER="root"
DB_PASS="NewRootPass123!"
DB_NAME="portal"

WG_IFACE="wg0"
WG_IP="10.9.0.1"
WARN_PORT="8082"          # Warning page port (8080=Bridge_Phone, 8081=reserved)
CHAIN="PORTAL_WL"         # iptables chain name

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ── Fetch allowed IPs from Vultr API via cached file ─────────────────────────
# Read API key directly from generate script
VULTR_API_KEY=$(grep 'VULTR_API_KEY=' /usr/local/bin/generate_instances.sh | head -1 | cut -d'"' -f2)
[[ -z "$VULTR_API_KEY" ]] && die "Could not read VULTR_API_KEY from generate_instances.sh"

log "Fetching IP whitelist from Vultr API..."
VULTR_RESPONSE=$(curl -sf --max-time 30     -H "Authorization: Bearer $VULTR_API_KEY"     -H "Content-Type: application/json"     "https://api.vultr.com/v2/instances?per_page=500")     || die "Vultr API call failed. Check network and API key."

# Cache for reference
echo "$VULTR_RESPONSE" > /tmp/vultr_instances_cache.json

ALLOWED_IPS=$(echo "$VULTR_RESPONSE" | jq -r '.instances[].main_ip' 2>/dev/null | grep -v '^$' | grep -v '^0\.' | sort -u)

if [[ -z "$ALLOWED_IPS" ]]; then
    die "No IPs returned from Vultr API."
fi

COUNT=$(echo "$ALLOWED_IPS" | wc -l)
log "Found $COUNT whitelisted IPs from Vultr instances."

# ── Also allow any IPs from onprem_links URL field ───────────────────────────
log "Checking on-prem URL IPs from database..."
ONPREM_IPS=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -sN -e "SELECT url FROM onprem_links WHERE url REGEXP '^[0-9]+\\\.[0-9]+\\\.[0-9]+\\\.[0-9]+'" 2>/dev/null \
    | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u || true)

ALL_IPS=$(printf '%s\n%s\n' "$ALLOWED_IPS" "$ONPREM_IPS" | sort -u | grep -v '^$')
log "Total whitelisted IPs (Vultr + on-prem): $(echo "$ALL_IPS" | wc -l)"

# ── Ensure IP forwarding is enabled ──────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/ip_forward
grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# ── Flush and rebuild the whitelist chain ────────────────────────────────────
log "Rebuilding iptables whitelist chain..."

# Remove only our own chain — never flush WireGuard's masquerade rules
iptables -D FORWARD -i "$WG_IFACE" -j "$CHAIN" 2>/dev/null || true
iptables -F "$CHAIN" 2>/dev/null || true
iptables -X "$CHAIN" 2>/dev/null || true

# Ensure WireGuard masquerade rules are present (re-add if missing after flush)
iptables -t nat -C POSTROUTING -s 10.9.0.0/16 -o enp1s0 -j MASQUERADE 2>/dev/null ||     iptables -t nat -A POSTROUTING -s 10.9.0.0/16 -o enp1s0 -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/16 -o tun0 -j MASQUERADE 2>/dev/null ||     iptables -t nat -A POSTROUTING -s 10.9.0.0/16 -o tun0 -j MASQUERADE
iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null ||     iptables -A FORWARD -o wg0 -j ACCEPT
log "WireGuard masquerade rules verified." 

# Create fresh chain
iptables -N "$CHAIN"

# ── Always allow: DNS (UDP+TCP 53) and NTP (UDP 123) ─────────────────────────
iptables -A "$CHAIN" -p udp --dport 53  -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 53  -j ACCEPT
iptables -A "$CHAIN" -p udp --dport 123 -j ACCEPT

# ── Always allow: traffic back to the portal server itself ───────────────────
iptables -A "$CHAIN" -d "$WG_IP" -j ACCEPT

# ── Always allow: WireGuard and OpenVPN internal networks ────────────────────
# 10.9.0.0/16 = WireGuard users (includes Bridge_Phone dashboard at 10.9.0.1:8080)
# 10.8.0.0/16 = OpenVPN site appliances (Bridge_Phone dealer sites)
iptables -A "$CHAIN" -d 10.9.0.0/16 -j ACCEPT
iptables -A "$CHAIN" -d 10.8.0.0/16 -j ACCEPT
log "  Allowed: 10.9.0.0/16 (WireGuard network — includes Bridge_Phone dashboard)"
log "  Allowed: 10.8.0.0/16 (OpenVPN network — Bridge_Phone site appliances)" 

# ── Always allow: ICMP (ping) so users can verify connectivity ───────────────
iptables -A "$CHAIN" -p icmp -j ACCEPT

# ── Allow: established/related return traffic ─────────────────────────────────
iptables -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── Build ipset whitelist (correct approach — fires BEFORE iptables FORWARD) ──
# ipset allows the NAT PREROUTING redirect to check destination IP efficiently.
# Without ipset, the redirect fires on ALL port 80 traffic including whitelisted IPs.
log "Building ipset whitelist..."
if ! command -v ipset >/dev/null 2>&1; then
    apt-get install -y ipset >/dev/null 2>&1 || die "ipset install failed."
fi

# Whitelist set: individual Vultr/on-prem public IPs
ipset create portal_whitelist hash:ip  2>/dev/null || ipset flush portal_whitelist
# Internal set:  always-allowed network ranges (WireGuard + OpenVPN)
ipset create portal_internal  hash:net 2>/dev/null || ipset flush portal_internal
ipset add portal_internal 10.9.0.0/16 2>/dev/null || true
ipset add portal_internal 10.8.0.0/16 2>/dev/null || true

while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    ipset add portal_whitelist "$ip" 2>/dev/null || true
    log "  Whitelisted: $ip"
done <<< "$ALL_IPS"

# ── FORWARD chain: accept whitelisted and internal, block everything else ─────
iptables -A "$CHAIN" -m set --match-set portal_internal  dst -j ACCEPT
iptables -A "$CHAIN" -m set --match-set portal_whitelist dst -j ACCEPT
# HTTPS to non-whitelisted: instant TCP reset (browser shows connection refused)
iptables -A "$CHAIN" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
# Everything else: drop (HTTP is handled by NAT redirect below)
iptables -A "$CHAIN" -j DROP

# ── Attach chain to FORWARD for wg0 traffic ──────────────────────────────────
iptables -I FORWARD 1 -i "$WG_IFACE" -j "$CHAIN"


# ── NAT PREROUTING: redirect blocked HTTP to warning page ────────────────────
# ONLY fires when destination is NOT in portal_whitelist AND NOT in portal_internal.
#
# 10.8.0.0/16 (on-site HTTP servers) is in portal_internal.
# HTTP to those IPs is NEVER redirected — traffic reaches the on-site server directly.
#
# Critical syntax note:
#   CORRECT:   -m set ! --match-set SETNAME dst   (negation is on --match-set)
#   INCORRECT: ! -m set --match-set SETNAME dst   (unreliable across iptables versions)
# Both conditions must use the correct form or the rule could silently match everything.

# Remove any existing version of this rule to avoid duplicates on re-run
iptables -t nat -D PREROUTING -i "$WG_IFACE" -p tcp --dport 80 \
    -m set ! --match-set portal_whitelist dst \
    -m set ! --match-set portal_internal  dst \
    -j REDIRECT --to-port "$WARN_PORT" 2>/dev/null || true

# Add with correct syntax — both conditions use -m set ! --match-set
iptables -t nat -A PREROUTING -i "$WG_IFACE" -p tcp --dport 80 \
    -m set ! --match-set portal_whitelist dst \
    -m set ! --match-set portal_internal  dst \
    -j REDIRECT --to-port "$WARN_PORT"

# ── Post-apply verification ───────────────────────────────────────────────────
log "Verifying critical ipset membership..."
VERIFY_FAIL=0
for test_ip in "10.8.0.1" "10.8.0.100" "10.9.0.1"; do
    if ipset test portal_internal "$test_ip" 2>/dev/null; then
        log "  ✔ $test_ip — confirmed in portal_internal (HTTP will NOT be redirected)"
    else
        log "  ✘ FAIL: $test_ip not in portal_internal — on-site HTTP may be broken!"
        VERIFY_FAIL=1
    fi
done
if [[ $VERIFY_FAIL -eq 1 ]]; then
    log "  ✘ VERIFICATION FAILED — flushing NAT rule to prevent breaking on-site servers"
    iptables -t nat -D PREROUTING -i "$WG_IFACE" -p tcp --dport 80 \
        -m set ! --match-set portal_whitelist dst \
        -m set ! --match-set portal_internal  dst \
        -j REDIRECT --to-port "$WARN_PORT" 2>/dev/null || true
    die "Aborted firewall update — ipset verification failed. On-site servers are safe."
fi

log "Firewall rules applied:"
log "  $COUNT Vultr IPs whitelisted on $WG_IFACE"
log "  10.9.0.0/16 (WireGuard network)  — always allowed (portal + Bridge_Phone)"
log "  10.8.0.0/16 (on-site servers)    — always allowed (HTTP traffic unaffected)"
log "  HTTP  to non-whitelisted IPs     → warning page on :$WARN_PORT"
log "  HTTPS to non-whitelisted IPs     → TCP reset (connection refused)"
log "  HTTP/HTTPS to whitelisted IPs    → passes through normally"
# ── Persist rules across reboots ─────────────────────────────────────────────
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    log "iptables rules saved (netfilter-persistent)."
elif command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
    iptables-save > /etc/iptables.rules 2>/dev/null || true
    log "iptables rules saved."
fi

log "Done."