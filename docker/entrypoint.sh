#!/usr/bin/env bash
# Container entrypoint: lock down the network as root, then drop to the
# unprivileged `agent` user with no capabilities and no_new_privs, so the
# agent can neither alter the firewall nor regain root.
set -euo pipefail

/usr/local/sbin/init-firewall.sh

# cwd is already /home/agent (Dockerfile WORKDIR); root can't enter it without
# CAP_DAC_OVERRIDE, which bin/agent drops.
export HOME=/home/agent USER=agent LOGNAME=agent

exec setpriv \
  --reuid=agent --regid=agent --init-groups \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all \
  --no-new-privs \
  -- "$@"
