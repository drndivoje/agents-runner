#!/usr/bin/env bash
# pre.sh: runs BEFORE the model. Optional.
#
# Its job:
#   1. Put the code into the working directory. The runner starts this script in $WORKDIR,
#      which is empty; the model will run in the same directory afterwards.
#   2. Decide if there is anything to do. `exit 78` ends the run cleanly ("nothing-to-do").
#   3. Save data for post.sh in $STATE_DIR (post.sh runs later, in the same container).
#   4. Print the task message to stdout. EVERYTHING printed to stdout is sent to the model
#      as its prompt (saved as input.md in the run's log folder). Logs go to stderr (`log`).
#
# Available: every variable from repo.env / agent.env, this agent's secrets from .env,
# and WORKDIR, STATE_DIR, RUN_DIR, AGENT_DIR (this folder), RUNNER_DIR, CLAUDE_AGENT.
# Runs with a system-only PATH: use system tools (git, curl, jq, …), nothing from $WORKDIR.
set -euo pipefail
# shellcheck source=runner/lib.sh
source "$RUNNER_DIR/lib.sh"   # log, die, agent_disclaimer, usage_footer

: "${REPO_URL:?REPO_URL not set in repo.env}"

# 1. Get the code. A public repo needs no credentials. For a private one, give git a token
#    from .env (e.g. a credential helper reading $MY_SERVICE_TOKEN), never put it in the URL.
log "cloning $REPO_URL"
git clone --quiet --depth 1 "$REPO_URL" .

# 2. Nothing to do? Example: skip repos without source files.
if [[ -z "$(git ls-files)" ]]; then
  log "empty repository, nothing to do"
  exit 78
fi

# 3. Data for post.sh. post.sh must treat $STATE_DIR as untrusted (the model's code could
#    have changed it), so validate whatever it reads back.
git rev-parse HEAD > "$STATE_DIR/commit.txt"

# 4. The task message (stdout → the model). The agent's instructions come from
#    .claude/agents/<agent>.md in the target repo; this adds the facts of THIS run and the
#    output format that post.sh parses (task.md, kept next to its parser).
echo "## Context"
echo
echo "Repository: $REPO_URL"
echo "Commit: $(cat "$STATE_DIR/commit.txt")"
echo "Recent changes:"
git log -1 --format='- %h %s'
echo
cat "$AGENT_DIR/task.md"
