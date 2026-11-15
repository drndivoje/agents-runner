#!/usr/bin/env bash
# Default-deny outbound firewall for the agent container.
# Based on Anthropic's reference devcontainer init-firewall.sh, tightened:
#   - DNS only to the resolvers in /etc/resolv.conf (not to any host)
#   - no access to the Docker host network
#   - only TCP 443 to allowlisted IPs
#   - IPv6 dropped entirely
# Must run as root with NET_ADMIN + NET_RAW. Exits non-zero on any failure,
# so the entrypoint never starts the agent with an open network.
set -euo pipefail
IFS=$'\n\t'

readonly ALLOWLIST="${ALLOWLIST:-/etc/agent-firewall/allowlist.txt}"
# Optional per-repo list (agents/<repo>/allowlist.txt, mounted read-only); set by bin/agent.
readonly EXTRA_ALLOWLIST="${EXTRA_ALLOWLIST:-}"
readonly IPSET=allowed-domains

# log <message>: "[firewall] <message>" to stderr.
log() { printf '[firewall] %s\n' "$*" >&2; }
# die <message>: log the error and exit 1, so the entrypoint never starts the agent with an open
# network.
die() { log "ERROR: $*"; exit 1; }

# is_ipv4 <s>: true if s looks like an IPv4 address.
is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
# is_domain <s>: true if s is a valid hostname (labels of letters, digits, hyphens; no wildcards).
is_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; }
# is_ipv4_cidr <s>: true if s looks like an IPv4 range (a.b.c.d/n).
is_ipv4_cidr() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; }

# reset_rules: open all policies and flush every iptables table and the ipset, to start from a clean
# state.
reset_rules() {
  iptables -P INPUT ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  ipset destroy "$IPSET" 2>/dev/null || true
}

# nameservers: the resolver IPs from /etc/resolv.conf, one per line.
nameservers() {
  awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf
}

# allow_loopback_and_dns: allow loopback traffic and DNS (port 53) to the configured resolvers only;
# dies if there is no IPv4 resolver.
allow_loopback_and_dns() {
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT

  local ns found=0
  for ns in $(nameservers); do
    is_ipv4 "$ns" || continue
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    found=1
  done
  [[ $found -eq 1 ]] || die "no IPv4 nameserver in /etc/resolv.conf"
}

# allowlists_contain <domain>: true if the base or per-repo allowlist lists <domain>.
allowlists_contain() {
  local file
  for file in "$ALLOWLIST" ${EXTRA_ALLOWLIST:+"$EXTRA_ALLOWLIST"}; do
    sed 's/#.*//; s/[[:space:]]//g' "$file" | grep -qxF "$1" && return 0
  done
  return 1
}

# add_github_ranges: only if an allowlist has github.com (DNS alone misses GitHub's many IPs).
add_github_ranges() {
  # Done before the default-deny policy is set, so api.github.com is reachable.
  local meta cidr
  allowlists_contain github.com || return 0
  log "fetching GitHub IP ranges"
  meta=$(curl -fsS --max-time 15 https://api.github.com/meta) || die "cannot fetch api.github.com/meta"
  jq -e '.web and .api and .git' <<<"$meta" >/dev/null || die "unexpected api.github.com/meta response"
  while read -r cidr; do
    is_ipv4_cidr "$cidr" || continue   # skip IPv6
    ipset add "$IPSET" "$cidr" -exist
  done < <(jq -r '(.web + .api + .git)[]' <<<"$meta")
}

# add_allowlisted_domains <file>: one domain per line, # comments allowed.
add_allowlisted_domains() {
  local file=$1 domain ip ips
  [[ -r "$file" ]] || die "allowlist not readable: $file"
  log "allowlist: $file"
  while read -r domain || [[ -n "$domain" ]]; do
    domain="${domain%%#*}"
    domain="${domain//[[:space:]]/}"
    [[ -n "$domain" ]] || continue
    is_domain "$domain" || die "invalid domain in $file: $domain"
    ips=$(dig +short +time=5 +tries=2 A "$domain" | grep -E '^[0-9.]+$' || true)
    [[ -n "$ips" ]] || die "cannot resolve $domain"
    for ip in $ips; do
      is_ipv4 "$ip" || die "bad address for $domain: $ip"
      ipset add "$IPSET" "$ip" -exist
    done
    log "allowed $domain"
  done < "$file"
}

# apply_default_deny: allow replies and HTTPS (443) to IPs in the allow ipset; reject all other
# outbound traffic, drop all inbound.
apply_default_deny() {
  iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 443 -m set --match-set "$IPSET" dst -j ACCEPT
  # Reject (not drop) so blocked calls fail fast instead of hanging.
  iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP
}

# drop_ipv6: block all IPv6 except loopback (if ip6tables works in this container).
drop_ipv6() {
  if command -v ip6tables >/dev/null && ip6tables -L >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
  fi
}

# verify: fail closed unless example.com is blocked and api.anthropic.com is reachable.
verify() {
  if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
    die "verification failed: example.com is reachable"
  fi
  # Any HTTP answer counts (the root path returns 404); we test the network path.
  curl -sS --max-time 10 -o /dev/null https://api.anthropic.com \
    || die "verification failed: api.anthropic.com is not reachable"
  log "verified: example.com blocked, api.anthropic.com reachable"
}

# main: reset, allow DNS, add allowlisted domains (plus GitHub ranges if listed), default deny,
# block IPv6, verify. Must run as root.
main() {
  [[ $EUID -eq 0 ]] || die "must run as root"
  reset_rules
  allow_loopback_and_dns
  ipset create "$IPSET" hash:net
  add_github_ranges
  add_allowlisted_domains "$ALLOWLIST"
  if [[ -n "$EXTRA_ALLOWLIST" ]]; then add_allowlisted_domains "$EXTRA_ALLOWLIST"; fi
  apply_default_deny
  drop_ipv6
  verify
}

main "$@"
