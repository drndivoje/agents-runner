#!/usr/bin/env bash
# post.sh: runs AFTER the model (and after check.sh), only if the model finished. Optional.
#
# Its job: read the model's result, validate it, and do something with it: create an issue,
# open a pull request, send a message, write a report. The model never does this itself.
#
# Inputs:
#   $RESULT_JSON  the model's final result; `.result` is the text of its final message
#                 (also: .usage tokens, .num_turns, .is_error)
#   $STATE_DIR    files pre.sh saved for this step (untrusted: validate them)
#   $WORKDIR      the working directory, possibly changed by the model (current directory)
#   CHECK_EXIT    exit code of check.sh (empty if there is no check.sh), CHECK_LOG its output
#   this agent's secrets from .env, every variable from repo.env / agent.env
#
# Rules: never execute anything from $WORKDIR here (no tests, no scripts, no build tools);
# that is check.sh's job. Never print a secret: all output ends up in the logs.
# Write the URL of what you created to $STATE_DIR/output_url to have it in logs/stats.csv.
set -euo pipefail
# shellcheck source=runner/lib.sh
source "$RUNNER_DIR/lib.sh"   # log, die, agent_disclaimer, usage_footer

readonly ANSWER="$RUN_DIR/answer.json"   # kept in the run's log folder for debugging

# 1. Read the model's final message and parse it as the JSON object task.md asked for.
#    Accept a bare JSON object or, as a fallback, the last ```json block in the message.
text=$(jq -r '.result // empty' "$RESULT_JSON")
if ! jq -e 'type == "object"' <<<"$text" >/dev/null 2>&1; then
  text=$(awk '/^```json[[:space:]]*$/ { buf = ""; inside = 1; next }
              /^```[[:space:]]*$/ && inside { last = buf; inside = 0; next }
              inside { buf = buf $0 "\n" }
              END { printf "%s", last }' <<<"$text")
fi
jq -e 'type == "object"' <<<"$text" >/dev/null 2>&1 \
  || die "the model's answer is not a JSON object (see result.json)"
jq . <<<"$text" > "$ANSWER"

# 2. "Nothing to report" is a normal outcome, not an error.
if jq -e 'has("skip")' "$ANSWER" >/dev/null; then
  log "nothing to report: $(jq -r '.skip' "$ANSWER")"
  exit 0
fi

# 3. Validate before acting: never trust the shape or size of model output.
summary=$(jq -r '.summary // empty' "$ANSWER")
count=$(jq '.findings | if type == "array" then length else -1 end' "$ANSWER")
[[ -n "$summary" ]] || die "answer has no summary"
(( count >= 1 && count <= 3 )) || die "expected 1-3 findings, got $count"

# If check.sh ran (an agent that edits code), act only when it passed.
if [[ -n "${CHECK_EXIT:-}" && "$CHECK_EXIT" != 0 ]]; then
  die "check.sh failed (exit $CHECK_EXIT), see check.log; nothing published"
fi

# Data from pre.sh, validated because the model's code could have changed it.
commit=$(cat "$STATE_DIR/commit.txt")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid commit in state"

# 4. Act. This scaffold only writes a Markdown report into the run's log folder.
#    Replace it with your own action, using a secret from .env, for example:
#      curl -fsS -K <(printf 'header = "Authorization: Bearer %s"\n' "$MY_SERVICE_TOKEN") \
#           --json @report.json https://api.example.com/reports
#    (-K reads the header from a file descriptor, so the token is not on the command line.)
report="$RUN_DIR/report.md"
{
  agent_disclaimer
  echo
  echo "**$summary** (commit \`${commit:0:7}\`)"
  echo
  jq -r '.findings[] | "- `\(.file):\(.line)` \(.problem)"' "$ANSWER"
  echo
  echo "---"
  echo "$(usage_footer "$RESULT_JSON") · run \`${RUN_DIR##*/}\`"
} > "$report"
log "wrote $report"

# 5. Record what was produced (a URL if you published something).
printf '%s\n' "file://$report" > "$STATE_DIR/output_url"
