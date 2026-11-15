#!/usr/bin/env bash
# Generic agent runner, executed inside the container as `agent`.
# Usage: run-agent.sh <repo> <agent>  < secrets (KEY=VALUE lines, see "Secrets")
#
# Knows only Claude Code. Everything about the target (cloning, GitHub, branches,
# issues, PRs) happens in the agent's hooks.
#
# agents/<repo>/              one folder per target repository
#   repo.env                  optional, shared by all agents of this repo (e.g. REPO=owner/name)
#   *.sh                      optional helpers shared by this repo's hooks
#   <agent>/                  one folder per repo agent; <agent> = name of the agent in the
#                             target repo's .claude/agents/ (claude --agent <agent>)
#     agent.env               the agent's config (required)
#     .env                    optional agent secrets; masked in the container, bin/agent sends them
#     pre.sh, check.sh, post.sh  optional hooks, plus any files they need (read via $AGENT_DIR)
#
# Config (repo.env, then <agent>/agent.env; sourced, later wins; every variable is
# exported to the hooks, so hooks can define their own, e.g. REPO=):
#   CLAUDE_AGENT       repo agent to run; default = <agent> (the folder name)
#   ALLOWED_TOOLS      value for claude --allowedTools — the security boundary, enforced
#                      here regardless of what the repo agent's `tools:` says (required)
#   MAX_TURNS          default 30
#   MODEL              optional override; unset = the repo agent's `model:`
#   TIMEOUT_MINUTES    hard limit for the claude step, default 60
#
# Secrets: bin/agent sends KEY=VALUE lines on stdin: CLAUDE_CODE_OAUTH_TOKEN (from secrets/.env)
# and the agent's own secrets (agents/<repo>/<agent>/.env). Nothing secret is in this
# process's environment (/proc/*/environ) or on any argv. Each goes only where it is needed:
#   claude    CLAUDE_CODE_OAUTH_TOKEN only
#   pre.sh    agent secrets (runs before any model-written code exists)
#   check.sh  nothing — it runs model-written code (tests, builds)
#   post.sh   agent secrets; must not execute anything from $WORKDIR
# Before check.sh and post.sh, every leftover process (e.g. a build daemon the model started)
# is killed, and hooks run with a system-only PATH, so model-written code can't wait for or
# impersonate a secret-holding step.
#
# Logs: /logs/<repo>/<agent>/<timestamp>/
# Stats: one CSV row per run appended to /logs/stats.csv (columns: runner/stats.jq),
#        written on every exit once the run directory exists. A hook can write the URL
#        it produced (issue, PR) to $STATE_DIR/output_url to have it recorded.
#
# Hooks run in $WORKDIR (empty at the start; claude runs there too) with the config
# variables, the agent secrets (pre.sh/post.sh only) and these variables:
#   AGENT_NAME (<repo>/<agent>) CLAUDE_AGENT AGENT_DIR RUNNER_DIR
#   WORKDIR RUN_DIR STATE_DIR RESULT_JSON
#   pre.sh:  prepares $WORKDIR (e.g. clones the repo); stdout becomes the task message
#            sent to the agent; exit 78 = nothing to do.
#   check.sh: runs only if claude succeeded, WITHOUT secrets; for anything that executes
#            code from $WORKDIR (tests). Output goes to $RUN_DIR/check.log.
#   post.sh: runs only if claude succeeded (also if check.sh failed); can read $RESULT_JSON,
#            files in $STATE_DIR (treat as untrusted: the model's code could write there),
#            CHECK_EXIT (check.sh exit code, empty if none) and CHECK_LOG.
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNNER_DIR
readonly AGENTS_DIR="${AGENTS_DIR:-$RUNNER_DIR/../agents}"
readonly LOGS_DIR="${LOGS_DIR:-/logs}"
readonly EXIT_NOTHING_TO_DO=78
readonly NAME_RE='^[a-z0-9][a-z0-9-]*$'
readonly STATS_CSV="$LOGS_DIR/stats.csv"
readonly SECRET_RE='^[A-Za-z_][A-Za-z0-9_]*='
# The runner, pre.sh and post.sh resolve tools from system dirs only (root-owned, so code the
# model wrote can't shadow git, gh, jq, bash …). claude and check.sh (no secrets) keep the
# image's PATH, so toolchains outside the system dirs (e.g. /opt/java/openjdk/bin) work.
readonly SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
readonly IMAGE_PATH=$PATH
CLAUDE_BIN=$(command -v claude || true)
readonly CLAUDE_BIN
export PATH=$SAFE_PATH

# shellcheck source=runner/lib.sh
source "$RUNNER_DIR/lib.sh"

REPO_NAME="" CONFIG_NAME="" AGENT_NAME="" REPO_DIR="" AGENT_DIR=""
RUN_DIR="" WORKDIR="" STATE_DIR="" RESULT_JSON="" TRANSCRIPT="" CHECK_LOG=""
INPUT=""
CLAUDE_ARGS=()
HOOK_SECRETS=()   # KEY=VALUE from agents/<repo>/<agent>/.env; exported only inside run_hook
CLAUDE_TOKEN=""   # exported only into claude's environment
TEE_PID=""
CHECK_EXIT="" POST_RC=0
# Run statistics (see record_stats).
STARTED_AT="" START_TIME="" PRE_SECONDS="" CLAUDE_SECONDS="" CHECK_SECONDS="" POST_SECONDS="" CLAUDE_RC=""

# seconds_since <$EPOCHREALTIME value> → elapsed seconds, one decimal.
seconds_since() { awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }'; }

# usage: print the usage line and exit 2.
usage() { echo "usage: $(basename "$0") <repo> <agent>" >&2; exit 2; }

# parse_args <repo> <agent>: validate both names; set REPO_NAME, CONFIG_NAME, AGENT_NAME.
parse_args() {
  [[ $# -eq 2 ]] || usage
  REPO_NAME=$1 CONFIG_NAME=$2
  [[ "$REPO_NAME" =~ $NAME_RE ]] || die "invalid repo name: $REPO_NAME"
  [[ "$CONFIG_NAME" =~ $NAME_RE ]] || die "invalid agent name: $CONFIG_NAME"
  AGENT_NAME="$REPO_NAME/$CONFIG_NAME"
}

# read_secrets: all of stdin (so nothing stays buffered in the pipe), KEY=VALUE lines:
# CLAUDE_CODE_OAUTH_TOKEN → CLAUDE_TOKEN, everything else → HOOK_SECRETS. Never logged.
read_secrets() {
  local line
  [[ -t 0 ]] && die "secrets expected on stdin (run via bin/agent)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $SECRET_RE ]] || die "malformed secret line (expected KEY=VALUE)"
    case $line in
      CLAUDE_CODE_OAUTH_TOKEN=*) CLAUDE_TOKEN=${line#*=} ;;
      *) HOOK_SECRETS+=("$line") ;;
    esac
  done
  exec 0</dev/null
  [[ -n "$CLAUDE_TOKEN" ]] || die "CLAUDE_CODE_OAUTH_TOKEN missing on stdin"
  # Never inherit one from the environment (it would sit in /proc/<pid>/environ).
  [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || die "CLAUDE_CODE_OAUTH_TOKEN must come on stdin, not the environment"
}

# write_status <status>: record the run's outcome in $RUN_DIR/status (read by record_stats) and log
# it.
write_status() {
  printf '%s\n' "$1" > "$RUN_DIR/status"
  log "status: $1"
}

# load_config: source repo.env, then agent.env (later wins; everything exported for the hooks),
# check required settings and apply defaults. Refuses ANTHROPIC_API_KEY (API billing).
load_config() {
  REPO_DIR="$(cd "$AGENTS_DIR/$REPO_NAME" 2>/dev/null && pwd)" || die "unknown repo: $REPO_NAME"
  AGENT_DIR="$(cd "$REPO_DIR/$CONFIG_NAME" 2>/dev/null && pwd)" || die "unknown agent: $AGENT_NAME"
  local env_file="$AGENT_DIR/agent.env"
  [[ -f "$env_file" ]] || die "missing $env_file"

  # set -a: every config variable is exported, so hooks see their own settings (e.g. REPO).
  set -a
  # shellcheck source=/dev/null
  if [[ -f "$REPO_DIR/repo.env" ]]; then source "$REPO_DIR/repo.env"; fi
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  : "${ALLOWED_TOOLS:?ALLOWED_TOOLS not set in $CONFIG_NAME/agent.env}"

  CLAUDE_AGENT="${CLAUDE_AGENT:-$CONFIG_NAME}"
  [[ "$CLAUDE_AGENT" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "invalid CLAUDE_AGENT: $CLAUDE_AGENT"
  MAX_TURNS="${MAX_TURNS:-30}"
  MODEL="${MODEL:-}"
  TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-60}"
  [[ -n "$CLAUDE_BIN" ]] || die "claude not found"
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY must not be set (subscription auth only)"
}

# setup_run_dir: create this run's log dir and the latest symlink, send all output to run.log too,
# and install the EXIT trap that records stats.
setup_run_dir() {
  local agent_logs="$LOGS_DIR/$REPO_NAME/$CONFIG_NAME"
  RUN_DIR="$agent_logs/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$RUN_DIR"
  RESULT_JSON="$RUN_DIR/result.json"
  TRANSCRIPT="$RUN_DIR/transcript.jsonl"
  CHECK_LOG="$RUN_DIR/check.log"
  STATE_DIR="$HOME/state"
  WORKDIR="$HOME/work"
  mkdir -p "$STATE_DIR" "$WORKDIR"
  ln -sfn "${RUN_DIR##*/}" "$agent_logs/latest"
  exec > >(tee -a "$RUN_DIR/run.log") 2>&1
  TEE_PID=$!
  STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START_TIME=$EPOCHREALTIME
  trap on_exit EXIT
  log "agent=$AGENT_NAME claude_agent=$CLAUDE_AGENT model=${MODEL:-agent default} max_turns=$MAX_TURNS run_dir=$RUN_DIR"
}

# export_hook_env: export the run variables every hook relies on (AGENT_DIR, WORKDIR, RUN_DIR,
# STATE_DIR, ...).
export_hook_env() {
  export AGENT_NAME CLAUDE_AGENT AGENT_DIR RUNNER_DIR WORKDIR RUN_DIR STATE_DIR RESULT_JSON
}

# run_hook <script> [secrets]: in $WORKDIR, never with the Claude token. With "secrets":
# the agent secrets (exported only inside this subshell, so not on any argv or in `ps`)
# and the system-only PATH. Without: no secrets and the image's PATH (check.sh).
run_hook() {
  (
    local kv
    if [[ "${2:-}" == secrets ]]; then
      for kv in "${HOOK_SECRETS[@]}"; do export "${kv?}"; done
    else
      # shellcheck disable=SC2030  # PATH change is meant to stay in this subshell
      export PATH=$IMAGE_PATH
    fi
    cd "$WORKDIR" && exec bash "$1" </dev/null
  )
}

# kill_leftovers: kill every process of this user except the runner and its log tee,
# e.g. a build daemon started by the model, so nothing model-written outlives its phase
# and watches a later, secret-holding one. Repeats until none are left.
kill_leftovers() {
  local pid found killed=0
  for _ in 1 2 3 4 5; do
    found=0
    for pid in $(pgrep -u "$(id -u)" || true); do
      [[ "$pid" == "$$" || "$pid" == "$TEE_PID" || "$pid" == "$BASHPID" ]] && continue
      if kill -KILL "$pid" 2>/dev/null; then found=1; killed=$((killed + 1)); fi
    done
    if (( ! found )); then
      (( killed == 0 )) || log "killed $killed leftover process(es)"
      return 0
    fi
    sleep 0.2
  done
  die "processes keep respawning; refusing to continue"
}

# hook_path <pre|check|post>: path of the agent's hook script, empty if none.
hook_path() {
  if [[ -f "$AGENT_DIR/$1.sh" ]]; then printf '%s' "$AGENT_DIR/$1.sh"; fi
}

# run_pre: run pre.sh with the agent secrets; its stdout becomes INPUT, the task message (saved as
# input.md). Exit 78 ends the run as nothing-to-do, any other failure as pre-failed.
run_pre() {
  local hook rc=0
  hook=$(hook_path pre)
  [[ -n "$hook" ]] || return 0
  log "running $CONFIG_NAME/pre.sh"
  local t=$EPOCHREALTIME
  INPUT=$(run_hook "$hook" secrets) || rc=$?
  PRE_SECONDS=$(seconds_since "$t")
  case $rc in
    0) ;;
    "$EXIT_NOTHING_TO_DO") write_status nothing-to-do; exit 0 ;;
    *) write_status pre-failed; die "pre.sh exited $rc" ;;
  esac
  printf '%s\n' "$INPUT" > "$RUN_DIR/input.md"
}

# claude_args: build CLAUDE_ARGS for a headless run: agent, allowed tools, max turns, optional
# model, stream-json output.
claude_args() {
  CLAUDE_ARGS=(-p --agent "$CLAUDE_AGENT" --allowedTools "$ALLOWED_TOOLS" --max-turns "$MAX_TURNS"
               --output-format stream-json --verbose)
  if [[ -n "$MODEL" ]]; then CLAUDE_ARGS+=(--model "$MODEL"); fi
}

# run_claude: pipe INPUT to claude in $WORKDIR, with only the Claude token and under a timeout.
# Saves the stream as transcript.jsonl and its final result event as result.json. Returns 1 (status
# claude-failed or claude-timeout) on error.
run_claude() {
  local rc=0
  claude_args

  log "running claude --agent $CLAUDE_AGENT (timeout ${TIMEOUT_MINUTES}m)"
  local t=$EPOCHREALTIME
  # Task message: pre.sh output; the instructions come from the repo agent itself.
  # shellcheck disable=SC2031  # the subshell sets its own PATH on purpose
  printf '%s\n' "${INPUT:-Perform your task.}" \
    | (cd "$WORKDIR" && export PATH=$IMAGE_PATH CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_TOKEN \
       && exec timeout "${TIMEOUT_MINUTES}m" "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}") \
    > "$TRANSCRIPT" || rc=$?
  CLAUDE_SECONDS=$(seconds_since "$t")
  CLAUDE_RC=$rc

  # Final "result" event of the stream = what --output-format json would print.
  jq -R 'fromjson? | select(.type == "result")' "$TRANSCRIPT" | jq -s 'last // empty' > "$RESULT_JSON"

  if (( rc == 124 )); then write_status claude-timeout; return 1; fi
  if (( rc != 0 )) || ! jq -e '.is_error == false' "$RESULT_JSON" >/dev/null 2>&1; then
    write_status claude-failed
    log "claude exited $rc: $(jq -r '[.terminal_reason, .subtype, .result] | map(select(. != null)) | join(" | ")' "$RESULT_JSON" 2>/dev/null)"
    return 1
  fi
  log "claude done: $(usage_footer "$RESULT_JSON")"
}

# run_check: check.sh without any secrets; sets CHECK_EXIT (empty if there is no check.sh).
run_check() {
  local hook rc=0
  hook=$(hook_path check)
  [[ -n "$hook" ]] || return 0
  log "running $CONFIG_NAME/check.sh without secrets (log: check.log)"
  local t=$EPOCHREALTIME
  run_hook "$hook" > "$CHECK_LOG" 2>&1 || rc=$?
  CHECK_SECONDS=$(seconds_since "$t")
  CHECK_EXIT=$rc
  log "check.sh exited $rc"
}

# run_post: post.sh with the agent secrets; sets POST_RC.
run_post() {
  local hook
  hook=$(hook_path post)
  [[ -n "$hook" ]] || return 0
  log "running $CONFIG_NAME/post.sh"
  local t=$EPOCHREALTIME
  CHECK_EXIT=$CHECK_EXIT CHECK_LOG=$CHECK_LOG run_hook "$hook" secrets || POST_RC=$?
  POST_SECONDS=$(seconds_since "$t")
  (( POST_RC == 0 )) || log "post.sh exited $POST_RC"
}

# record_stats <exit code>: append one row to $STATS_CSV (header on first use; if the
# columns changed, the old file is archived as stats-<timestamp>.csv first).
record_stats() {
  local rc=$1 status run tmp header row
  status=$(cat "$RUN_DIR/status" 2>/dev/null || true)
  if [[ -z "$status" ]]; then status=error; write_status error; fi
  run=$(jq -n \
    --arg run_id "${RUN_DIR##*/}" --arg started_at "$STARTED_AT" \
    --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repo_name "$REPO_NAME" --arg repo "${REPO:-}" --arg agent "$CONFIG_NAME" \
    --arg claude_agent "$CLAUDE_AGENT" \
    --arg status "$status" --arg exit_code "$rc" \
    --arg output_url "$(cat "$STATE_DIR/output_url" 2>/dev/null || true)" \
    --arg wall_seconds "$(seconds_since "$START_TIME")" --arg pre_seconds "$PRE_SECONDS" \
    --arg claude_seconds "$CLAUDE_SECONDS" --arg check_seconds "$CHECK_SECONDS" \
    --arg check_exit_code "$CHECK_EXIT" --arg post_seconds "$POST_SECONDS" \
    --arg claude_exit_code "$CLAUDE_RC" --arg model_setting "${MODEL:-}" \
    --arg max_turns "$MAX_TURNS" --arg timeout_minutes "$TIMEOUT_MINUTES" \
    '$ARGS.named')

  tmp=$(mktemp -d)
  if [[ -s "$RESULT_JSON" ]]; then cp "$RESULT_JSON" "$tmp/result.json"; else : > "$tmp/result.json"; fi
  if [[ -f "$TRANSCRIPT" ]]; then jq -cR 'fromjson?' "$TRANSCRIPT" > "$tmp/events.json"; else : > "$tmp/events.json"; fi
  # stats_csv <true|false>: the CSV header (true) or this run's row (false), built by stats.jq.
  stats_csv() {
    jq -nr --argjson run "$run" --slurpfile result "$tmp/result.json" \
      --slurpfile events "$tmp/events.json" --arg header "$1" -f "$RUNNER_DIR/stats.jq"
  }
  header=$(stats_csv true)
  row=$(stats_csv false)
  rm -rf "$tmp"

  (
    flock 8
    if [[ -s "$STATS_CSV" && "$(head -n 1 "$STATS_CSV")" != "$header" ]]; then
      mv "$STATS_CSV" "${STATS_CSV%.csv}-$(date -u +%Y%m%dT%H%M%SZ).csv"
      log "stats columns changed; archived the old stats file"
    fi
    if [[ ! -s "$STATS_CSV" ]]; then printf '%s\n' "$header" > "$STATS_CSV"; fi
    printf '%s\n' "$row" >> "$STATS_CSV"
  ) 8>"$LOGS_DIR/.stats.lock"
  log "stats: appended to ${STATS_CSV##*/}"
}

# on_exit: EXIT trap: record the stats row whatever happened, then exit with the original code.
on_exit() {
  local rc=$?
  trap - EXIT
  set +e
  record_stats "$rc" || log "WARNING: could not record stats"
  exit "$rc"
}

# main <repo> <agent>: one full run: secrets, config, pre.sh, claude, check.sh, post.sh, final
# status.
main() {
  parse_args "$@"
  read_secrets
  load_config
  setup_run_dir
  export_hook_env
  run_pre
  run_claude || exit 1
  kill_leftovers
  run_check
  kill_leftovers
  run_post
  if [[ -n "$CHECK_EXIT" && "$CHECK_EXIT" != 0 ]]; then write_status check-failed; exit 1; fi
  if (( POST_RC != 0 )); then write_status post-failed; exit 1; fi
  write_status success
}

main "$@"
