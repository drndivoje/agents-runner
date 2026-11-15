#!/usr/bin/env bash
# check.sh: runs AFTER the model and BEFORE post.sh, only if the model finished. Optional:
# delete it if your agent only reads code.
#
# Use it for anything that executes code from the working directory (tests, builds),
# because that code may have been written by the model. That is why this step gets NO
# secrets at all. Its output goes to check.log; post.sh receives its exit code as
# CHECK_EXIT and the log path as CHECK_LOG. A non-zero exit marks the run "check-failed".
set -euo pipefail

if [[ -z "${TEST_COMMAND:-}" ]]; then
  echo "no TEST_COMMAND in agent.env, nothing to check"
  exit 0
fi
exec bash -c "$TEST_COMMAND"
