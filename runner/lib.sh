#!/usr/bin/env bash
# Generic helpers for run-agent.sh and agents' pre.sh / post.sh (no GitHub, no git:
# target-specific helpers live in agents/<repo>/, next to repo.env).
# Usage in a hook: source "$RUNNER_DIR/lib.sh"

# log <message>: timestamped line to stderr (ends up in run.log).
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
# die <message>: log "ERROR: <message>" and exit 1.
die() { log "ERROR: $*"; exit 1; }

# agent_disclaimer → one Markdown line marking content as AI-generated.
# Put it at the top of every issue / PR body an agent creates.
agent_disclaimer() {
  # shellcheck disable=SC2016  # backticks are Markdown, not command substitution
  printf '> 🤖 **Created by an AI agent** (`%s`, Claude Code via agents-runner) — not written or reviewed by a human.\n' \
    "${CLAUDE_AGENT:-${AGENT_NAME:-unknown}}"
}

# usage_footer <result.json>  →  "🤖 N tokens, M turns" (input + output tokens)
usage_footer() {
  jq -r '"🤖 \((.usage.input_tokens // 0) + (.usage.output_tokens // 0)) tokens, \(.num_turns // 0) turns"' "$1"
}
