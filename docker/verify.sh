#!/usr/bin/env bash
# Smoke-test an agent image: firewall, non-root user, tooling. No secrets needed.
# Usage: docker/verify.sh [image] [repo]
#   image  default agent-img; e.g. agent-img:node-22-bookworm (what bin/agent builds for IMAGE=node:22-bookworm)
#   repo   also load agents/<repo>/allowlist.txt, as bin/agent does for that repo
# Every allowlisted domain (base + repo) must be reachable over HTTPS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly IMAGE="${1:-agent-img}" REPO_NAME="${2:-}"
EXTRA=()
if [[ -n "$REPO_NAME" ]]; then
  list="$ROOT/agents/$REPO_NAME/allowlist.txt"
  [[ -f "$list" ]] || { echo "no $list" >&2; exit 2; }
  EXTRA=(-v "$list:/etc/agent-firewall/repo-allowlist.txt:ro"
         -e EXTRA_ALLOWLIST=/etc/agent-firewall/repo-allowlist.txt)
fi

# Runs inside the container as `agent`, after the firewall is up.
read -r -d '' CHECKS <<'EOF' || true
set -uo pipefail
fail=0
# check <name> <command...>: PASS if the command succeeds, else FAIL (the script then exits 1).
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; fail=1; fi
}
# check_not <name> <command...>: PASS if the command fails (something that must be blocked), else
# FAIL.
check_not() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL  $name"; fail=1; else echo "PASS  $name"; fi
}
check     "runs as agent (non-root)"     test "$(id -un)" = agent -a "$(id -u)" -ne 0
check_not "cannot change firewall"       iptables -F
check_not "example.com blocked"          curl -fsS --max-time 5 https://example.com
check_not "plain HTTP blocked"           curl -sS --max-time 5 -o /dev/null http://api.anthropic.com
# Every allowlisted domain answers over HTTPS (any HTTP status counts; we test the network).
for list in /etc/agent-firewall/allowlist.txt ${EXTRA_ALLOWLIST:-}; do
  while read -r d || [ -n "$d" ]; do
    d="${d%%#*}"; d="${d//[[:space:]]/}"; [ -n "$d" ] || continue
    check "$d reachable" curl -sS --max-time 10 -o /dev/null "https://$d/"
  done < "$list"
done
# GitHub only if a list allows it (agents/<repo>/allowlist.txt, e.g. whereisivan).
if cat /etc/agent-firewall/allowlist.txt ${EXTRA_ALLOWLIST:-} | sed 's/#.*//; s/[[:space:]]//g' | grep -qx github.com; then
  check   "git clone over HTTPS works"   git ls-remote https://github.com/cli/cli HEAD
fi
check     "claude --version"             claude --version
# Toolchain: report what this variant has (the default agent-img must have JDK 25).
if command -v java >/dev/null; then
  check   "java 25"                      sh -c 'java -version 2>&1 | grep -q "version \"25"'
fi
for tool in node npm python3 pip3; do
  if command -v "$tool" >/dev/null; then echo "INFO  $tool $("$tool" --version 2>&1 | head -n 1)"; fi
done
check     "gh --version"                 gh --version
echo "claude: $(claude --version 2>&1)"
exit $fail
EOF

# Same privilege set as bin/agent.
docker run --rm --init \
  --cap-drop=ALL \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --cap-add=SETUID --cap-add=SETGID --cap-add=SETPCAP \
  --security-opt=no-new-privileges \
  "${EXTRA[@]}" \
  "$IMAGE" bash -c "$CHECKS"
