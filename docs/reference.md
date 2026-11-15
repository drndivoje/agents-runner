# Reference

Details behind the [README](../README.md): how a run works, writing an agent, configuration,
images, caches, logs, statistics and troubleshooting.

## How a run works

```
bin/agent <repo> <agent>                  (host)
 ├─ reads secrets/.env (Claude token) + optional agents/<repo>/<agent>/.env (agent secrets)
 ├─ flock: skips if the same agent is already running
 ├─ builds the image if missing or docker/ changed (IMAGE= in repo.env = base image)
 └─ docker run agent-img[:<base>]         (container)
     ├─ entrypoint: default-deny firewall (docker/allowlist.txt + optional agents/<repo>/allowlist.txt),
     │              then drop to user `agent`
     └─ runner/run-agent.sh <repo> <agent>
         ├─ load agents/<repo>/repo.env + agents/<repo>/<agent>/agent.env
         ├─ pre.sh   → prepares the empty workdir, prints the prompt (exit 78 = nothing to do)
         ├─ claude -p --agent <agent>     (agent definition from the target repo; tools limited by ALLOWED_TOOLS)
         ├─ check.sh → optional, WITHOUT secrets: runs model-written code (tests)
         └─ post.sh  → validates the model's answer and acts on it
```

The runner (`bin/agent`, `runner/`) knows only Docker and Claude Code. Everything about the
target (where the code comes from, where results go, GitHub or anything else) lives in the
agent's hooks, so the runner needs no other tool or token.

### Secrets never reach the model

`CLAUDE_CODE_OAUTH_TOKEN` (`secrets/.env`) goes to `claude` only. An agent's own secrets
(`agents/<repo>/<agent>/.env`) go to that agent's `pre.sh` and `post.sh` only. How that holds,
also against code the model writes (e.g. tests it adds):

| Path to a secret | Closed by |
|---|---|
| model reads `.env` from the mounted `agents/` | only `agents/<repo>/` is mounted, every `.env` in it is masked with `/dev/null` |
| model reads another process's environment (`/proc/*/environ`) | secrets enter the container on stdin, never as env; the runner keeps them in shell variables and exports them only into the hook that needs them |
| model-written code runs while a secret is around | it runs only in the claude step (no agent secrets) and in `check.sh` (no secrets at all); `post.sh` must not execute anything from the working tree |
| a process the model started (e.g. a build daemon) waits for `post.sh` | every leftover process is killed before `check.sh` and before `post.sh` |
| model-written code plants a fake `git`/`bash` for `post.sh` | hooks run with a system-only `PATH` (root-owned dirs). A hook that uses git on the model's working tree should give git a fresh config and rewrite `.git/config` first (no hooks, fsmonitor or helpers from the model) |

Hook output lands in the logs, so hooks must never print a secret.
What remains: during its own step `claude` necessarily holds the Claude token, so code the
model runs can read that one token (it can only use it against `api.anthropic.com`).

## Writing an agent

An agent is a folder `agents/<repo>/<agent>/` and an agent definition
`.claude/agents/<agent>.md`, pushed to the target repo. The folder name is the agent name
(`claude --agent <agent>`); set `CLAUDE_AGENT=` in `agent.env` to use another name.
Start from the scaffold:

```
agents/example/                 copy to agents/<repo>/
├── repo.env                    shared config for all agents of this repo (REPO_URL, IMAGE)
├── allowlist.txt               extra firewall domains for this repo's agents
└── my-agent/
    ├── agent.env               ALLOWED_TOOLS, limits, your own settings
    ├── .env.example            optional secrets for pre.sh/post.sh (copy to .env, chmod 600)
    ├── pre.sh                  clones the repo, saves state, prints the prompt
    ├── task.md                 output format, appended to the prompt by pre.sh
    ├── check.sh                optional: runs TEST_COMMAND without secrets
    └── post.sh                 parses the JSON answer, validates it, writes a report
examples/claude-agents/my-agent.md   the matching agent definition for the target repo
```

`agent.env` says *what* runs and *with which limits*; the hooks say what happens before and
after the model. Each repo/agent pair has its own lock, logs and cache volumes.

### Hook contract

All hooks are optional and run in `$WORKDIR` (the directory the model works in), with every
variable from `repo.env` / `agent.env` and:

| Variable | Meaning |
|---|---|
| `WORKDIR` | working directory; empty when `pre.sh` starts |
| `STATE_DIR` | scratch space to pass data from `pre.sh` to `post.sh` (untrusted in post.sh: the model's code could write there) |
| `RUN_DIR` | this run's log folder; files you write there are kept |
| `RESULT_JSON` | the model's final result (post.sh) |
| `AGENT_DIR` | this agent's folder, for its own files (`$AGENT_DIR/task.md`) |
| `RUNNER_DIR` | `source "$RUNNER_DIR/lib.sh"` for `log`, `die`, `agent_disclaimer`, `usage_footer` |
| `AGENT_NAME`, `CLAUDE_AGENT` | `<repo>/<agent>` and the agent definition's name |
| `CHECK_EXIT`, `CHECK_LOG` | check.sh's exit code (empty if none) and output file (post.sh) |

| Hook | Secrets | When | Contract |
|---|---|---|---|
| `pre.sh` | agent secrets | first | stdout = the prompt (saved as `input.md`); log to stderr; exit 78 = nothing to do (status `nothing-to-do`); other non-zero = `pre-failed` |
| `check.sh` | none | only if claude succeeded | runs model-written code (tests, builds); output → `check.log`; non-zero = `check-failed` |
| `post.sh` | agent secrets | only if claude succeeded, also when check.sh failed | must not execute anything from `$WORKDIR`; non-zero = `post-failed`; write a URL to `$STATE_DIR/output_url` to record it in `stats.csv` |

Hooks run with a system-only `PATH` (check.sh gets the image's PATH, for the toolchain) and
never get the Claude token.

### Passing data to the model

Everything `pre.sh` prints to stdout is the prompt. The agent definition in the target repo
says *what* to do in general; the prompt adds the facts of this run (which issue, which
commit, which files) and the **output format** your post.sh parses. Keep the output format
in this repo (`task.md`), next to its parser, so the two can't drift apart.

### Consuming the result

`$RESULT_JSON` is the final `result` event of the Claude session:

```bash
jq -r '.result' "$RESULT_JSON"       # the text of the model's final message
jq '.usage, .num_turns' "$RESULT_JSON"
```

Ask for one JSON object and parse it defensively: accept a bare object, fall back to the last
```` ```json ```` block, reject anything else, and validate every field (lengths, counts,
paths, numbers) before acting. Support an explicit "nothing to do" answer such as
`{"skip": "reason"}` so the model is never pushed into a weak result. The scaffold's
`post.sh` does all of this.

For agents that edit code, the changes are in `$WORKDIR`: check them with plain tools
(`git status --porcelain`, allowed paths) and act only if `CHECK_EXIT` is 0.

## Configuration

| File | What |
|---|---|
| `secrets/.env` | `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` (the only global secret) |
| `agents/<repo>/repo.env` | optional, shared by all agents of the repo; any variables your hooks read, `IMAGE=`, `CACHE_DIRS=` |
| `agents/<repo>/allowlist.txt` | optional extra firewall domains, see [Network access per repo](#network-access-per-repo) |
| `agents/<repo>/<agent>/agent.env` | required; settings below plus any variables your hooks read |
| `agents/<repo>/<agent>/.env` | optional agent secrets (`KEY=VALUE`), for pre.sh/post.sh only |

`agent.env` settings (`repo.env` first, `agent.env` wins):

| Variable | Default | Meaning |
|---|---|---|
| `ALLOWED_TOOLS` | required | `claude --allowedTools`; the security boundary. The agent definition's `tools:` can narrow it, never widen it. Commands need their exact form, e.g. `Bash(npm test:*)` |
| `MAX_TURNS` | 30 | model turns before the run stops |
| `TIMEOUT_MINUTES` | 60 | hard limit for the claude step |
| `MODEL` | agent definition's `model:` | e.g. `sonnet` |
| `CLAUDE_AGENT` | folder name | name of the agent definition |
| `IMAGE` | JDK 25 | base image with the toolchain, see [Runtime image per stack](#runtime-image-per-stack) |
| `CACHE_DIRS` | none | dependency caches kept between runs, see [Caches between runs](#caches-between-runs) |

Agent secrets: `.env` files are gitignored (only `*.example` are committed); `bin/agent`
refuses to run if an agent's `.env` isn't chmod 600, is tracked or isn't ignored by git, or if
`repo.env` or another file in an agent folder contains something that looks like a token. Use
one token per agent with the least privilege it needs (e.g. a fine-grained GitHub token for
one repository). Never set `ANTHROPIC_API_KEY`: it would switch billing to the API.

### Build and verify the image

`bin/agent` builds the image on the first run (and again whenever a file in `docker/` changes),
so this step is optional. Building it once by hand lets you verify it before the first run:

```bash
docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
  -t agent-img docker/                     # default: JDK 25 (see "Runtime image per stack")
docker/verify.sh                           # or: docker/verify.sh agent-img myrepo
```

`verify.sh [image] [repo]` checks: runs as non-root, firewall can't be changed, `example.com`
and plain HTTP blocked, every allowlisted domain reachable (the base list, plus
`agents/<repo>/allowlist.txt` if you pass a repo), `git clone` from GitHub if github.com is
allowed, `claude` and `gh` work, `java 25` if the image has Java, and it prints the
Node/Python versions it finds.
`bin/agent` rebuilds automatically after a change in `docker/` (including the base
`allowlist.txt`; the per-repo `agents/<repo>/allowlist.txt` needs no rebuild). It labels each
image it builds with a hash of the build files and the base image; an image without that label
(e.g. built by hand) is rebuilt once on the next run.
To update Claude Code or the base image: `AGENT_REBUILD=1 bin/agent <repo> <agent>`
(`--no-cache --pull`).
The automatic build uses your UID/GID (part of the hash, so a different user gets a rebuild).
Building by hand, pass them yourself as above; without them the user is 1000 and `logs/` may not be writable.

### Runtime image per stack

The image provides your project's toolchain (the agent and check.sh run the tests in it).
`IMAGE=` in `repo.env` (or an `agent.env`) names the **base image** with that toolchain;
`bin/agent` builds `docker/Dockerfile` on top of it (`BASE_IMAGE` build-arg) as
`agent-img:<base>` when that image is missing or `docker/` changed. The firewall, git, curl,
jq, `gh`, Claude Code and the non-root user are the same in every variant. Any
Debian/Ubuntu-based image works. For tests the base must contain the build toolchain (a JDK,
not a JRE, for Gradle/Maven). Need another tool in your hooks? Use a base image that has it,
or add it to `docker/Dockerfile`.

| Stack | `IMAGE=` in `repo.env` | Image that runs |
|---|---|---|
| JVM (default) | nothing (Dockerfile default `eclipse-temurin:25-jdk-noble`) | `agent-img` |
| Node | `IMAGE=node:22-bookworm` | `agent-img:node-22-bookworm` |
| Python | `IMAGE=python:3.13-bookworm` | `agent-img:python-3.13-bookworm` |

Add the stack's package registry to `agents/<repo>/allowlist.txt` (e.g. `registry.npmjs.org`;
for Python `pypi.org` and `files.pythonhosted.org`) and check with
`docker/verify.sh agent-img:node-22-bookworm myrepo` (after the first run built it). The build
output goes to the agent's `agent.log`. `AGENT_IMAGE=…` in the environment runs a ready-built
image as-is (no build) for one manual run.

## Running an agent

```bash
bin/agent <repo> <agent>
bin/agent [repo]                   # lists repos and their agents
```

```bash
bin/agent myrepo my-agent
#   → agents/myrepo/repo.env + my-agent/agent.env
#   → my-agent/pre.sh, claude --agent my-agent, my-agent/check.sh, my-agent/post.sh
#   → logs in logs/myrepo/my-agent/
```

Output streams to the terminal and is saved to the logs (below). Exit codes:

| Exit | Meaning |
|---|---|
| 0 | success, nothing to do, or skipped because the agent was already running |
| 1 | failure — see `status` and `run.log` of the run |

Optional overrides (environment): `AGENT_MEMORY` (default `6g`), `AGENT_CPUS` (`2`),
`AGENT_IMAGE` (a ready-built image to run as-is instead of building from `IMAGE=`),
`AGENT_REBUILD=1` (rebuild the image with `--no-cache --pull`), `LOGS_DIR`, `SECRETS_FILE` (Claude token file), `AGENTS_DIR`,
`AGENT_LOCK_DIR` (`.locks/` in this repo).

### Caches between runs

Every run starts in a fresh container, so dependencies are downloaded again each time unless
you keep the tool's cache. This is **optional**: list the cache directories in `CACHE_DIRS`
(in `agent.env`, or `repo.env` for all agents of the repo), separated by spaces:

```
# agents/myrepo/my-agent/agent.env
CACHE_DIRS="/home/agent/.gradle/caches /home/agent/.gradle/wrapper"
```

Each directory becomes a Docker volume named `agent-cache-<repo>.<agent>-<path>`, kept between
runs of that agent only. No `CACHE_DIRS` = no volumes. Only an agent that builds or tests needs
one.

| Stack | `CACHE_DIRS` |
|---|---|
| Gradle | `/home/agent/.gradle/caches /home/agent/.gradle/wrapper` |
| Maven | `/home/agent/.m2/repository` |
| npm | `/home/agent/.npm` |
| pip | `/home/agent/.cache/pip` |

These directories exist in every image, owned by `agent`. Paths must be under `/home/agent`.
For any other directory, add it to the `install -d` list in `docker/Dockerfile` and rebuild,
otherwise the fresh volume is owned by root and the tool can't write to it.

```bash
docker volume ls | grep agent-cache-                              # what exists
docker volume rm agent-cache-myrepo.my-agent-.gradle-caches       # reset one cache
```

## Scheduling details

Field order is `minute hour day-of-month month day-of-week`. Examples:
`0 2 * * 1-5` = weekdays at 02:00, `30 */6 * * *` = every 6 hours at :30.
Check it is installed with `crontab -l`.

- **Logs:** each run is recorded in `logs/<repo>/<agent>/agent.log` and its run directory
  as usual. `logs/cron.log` additionally catches anything that fails *before* a run starts
  (missing secrets, bad config, Docker not reachable) — check it first when a
  scheduled run seems to have done nothing.
- **No overlaps:** if the previous run of the same agent is still going (scheduled or
  manual), the new one is skipped with `already running` (exit 0). Manual and cron runs
  share the same lock in `.locks/`.
- **Ordering:** if one agent consumes what another produces, schedule it later than the
  first agent's `TIMEOUT_MINUTES`.
- **Missed runs are not caught up:** cron only fires if the machine is on and awake at
  that minute. On a laptop pick a time it is usually on, or run the agent by hand.
- **Quota:** scheduled runs share your Claude limits with your interactive use;
  night-time runs avoid competing with your own sessions.

**Test it like cron does** (minimal environment, different working directory):

```bash
cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin \
  /home/you/agents-runner/bin/agent <repo> <agent>; echo "exit=$?"
```

**Pause / remove:** `crontab -e` and comment out (`#`) or delete the line. Nothing else
needs cleaning up; a running agent finishes on its own.

## Logs

Everything is persisted under `logs/` (gitignored), written live, so partial runs keep
their logs too:

```
logs/<repo>/<agent>/              e.g. logs/myrepo/my-agent/
├── agent.log                  # every run appended: start/end + exit code, firewall setup,
│                              #   runner output, "already running" skips
├── latest -> 20261108T181151Z # newest run
└── 20261108T181151Z/          # one directory per run (UTC)
    ├── run.log                # runner + pre.sh/post.sh output
    ├── status                 # success | nothing-to-do | pre-failed | claude-failed |
    │                          #   claude-timeout | check-failed | post-failed | error
    ├── input.md               # the prompt pre.sh sent to the model
    ├── transcript.jsonl       # full Claude session (stream-json, one event per line)
    ├── result.json            # final result: text, usage, num_turns, errors
    ├── check.log              # output of check.sh
    └── …                      # anything your hooks write to $RUN_DIR (the scaffold: answer.json, report.md)

logs/stats.csv                 # one row of statistics per run, all agents (see below)
```

Handy commands:

```bash
L=logs/myrepo/my-agent
tail -n 50 $L/agent.log                                      # recent history
cat $L/latest/status
jq -r '.result' $L/latest/result.json                        # model's final answer
jq '{turns: .num_turns, usage: .usage}' $L/latest/result.json
# tool calls the model made:
jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")
       | "\(.name) \(.input | tostring | .[0:120])"' $L/latest/transcript.jsonl
```

### Statistics: `logs/stats.csv`

Every run appends **one row** to `logs/stats.csv` — also failed runs and "nothing to do"
(only problems caught by `bin/agent` before the container starts, like missing secrets,
have no row). Parallel runs are safe (file lock). The columns are defined in
`runner/stats.jq`; if they ever change, the old file is kept as `stats-<timestamp>.csv`.

| Group | Columns |
|---|---|
| Run | `run_id` `started_at` `finished_at` `repo_name` `repo` `agent` `claude_agent` `status` `exit_code` `output_url` (from `$STATE_DIR/output_url`) |
| Wall time (s) | `wall_seconds` `pre_seconds` `claude_seconds` `post_seconds` |
| Settings | `claude_exit_code` `model_setting` `max_turns` `timeout_minutes` |
| Session | `model` `models_used` `claude_code_version` `api_key_source` `permission_mode` `session_id` |
| Outcome | `subtype` `is_error` `terminal_reason` `stop_reason` `api_error_status` `safety_stops` |
| Claude time | `duration_ms` (whole CLI run) `duration_api_ms` (time waiting for the model) `num_turns` `api_retries` |
| Tokens | `input_tokens` `output_tokens` `thinking_tokens` `cache_creation_input_tokens` `cache_creation_5m_tokens` `cache_creation_1h_tokens` `cache_read_input_tokens` `total_tokens` |
| Cost | `total_cost_usd` — API-equivalent price; **not billed** on Pro, but good for comparing runs |
| Tools | `tool_calls` `tool_errors` `tools_used` (e.g. `Edit:2;Read:9`) `permission_denials` `web_search_requests` `web_fetch_requests` `subagents_spawned` `subagents_failed` |
| Service | `service_tier` `speed` `inference_geo` `result_chars` |

Quick looks:

```bash
column -s, -t < logs/stats.csv | less -S                       # browse
# tokens and model time per agent
python3 - <<'EOF'
import csv, collections
t = collections.defaultdict(lambda: [0, 0, 0.0])
for r in csv.DictReader(open("logs/stats.csv")):
    a = t[r["agent"]]; a[0] += 1; a[1] += int(r["total_tokens"]); a[2] += int(r["duration_api_ms"]) / 60000
for agent, (runs, tokens, minutes) in t.items():
    print(f"{agent:24} runs={runs:3} tokens={tokens:>10,} model_minutes={minutes:6.1f}")
EOF
```

`agent.log` grows forever; prune old run directories and rotate it occasionally
(e.g. `find logs -mindepth 3 -maxdepth 3 -type d -mtime +30 -exec rm -rf {} +`).

## Reviewing what the agents produce

`stats.csv` tells you what a run cost; it does not tell you whether the result was useful.
That is the number that matters, so look at the results regularly. When a result is bad,
feed the reason back into the agent definition (`.claude/agents/<agent>.md` in the target
repo) or into the checks in `post.sh`. Add new agents only once the existing ones produce
work you would use.

## Network access per repo

The container can only reach the domains in `docker/allowlist.txt` (the Claude API only),
baked into the image. A repo that needs more, e.g. where pre.sh clones from or a package
registry, gets an **optional** `agents/<repo>/allowlist.txt`, used by all agents of that repo:

```
# agents/myrepo/allowlist.txt: one domain per line, HTTPS only
# listing github.com also adds GitHub's published IP ranges
github.com
# package registry
registry.npmjs.org
```

The firewall adds these domains at container start, so no image rebuild is needed. The run's
`agent.log` shows `[firewall] allowlist: …/agents/myrepo/allowlist.txt`. An invalid or
unresolvable domain stops the run before the agent starts. The file lives in this repo, never
in the target repo, so neither the target repo nor the model can widen network access. Keep it
minimal: every domain is somewhere the agent could send code to.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `secrets/... must be chmod 600` | `chmod 600` that file |
| `... contains what looks like a token` | move the token from `repo.env` or the agent's config into `agents/<repo>/<agent>/.env` |
| `no agent 'X' for <repo>` | create `agents/<repo>/X/agent.env`, or run `bin/agent <repo>` to list agents |
| `X is empty in secrets/...` | fill in that variable |
| `401 Invalid bearer token` in run.log | regenerate with `claude setup-token` |
| `--agent 'X' not found. Available agents: …` | push `.claude/agents/X.md` to the target repo, or rename the agent folder / set `CLAUDE_AGENT` |
| `the model's answer is not a JSON object` (scaffold post.sh) | read `.result` in `result.json`; make the output format in `task.md` stricter |
| `invalid CACHE_DIRS entry` | use absolute paths under `/home/agent`, separated by spaces |
| `Permission denied` writing to a cache dir | the dir isn't pre-created in the image: add it to `docker/Dockerfile`, rebuild, remove the volume |
| `image build failed` | see the build output in `agent.log`; check `IMAGE=` names an existing Debian/Ubuntu-based image and that the host can pull it |
| `AGENT_IMAGE X not found` | build that image by hand or unset `AGENT_IMAGE` |
| `[firewall] ERROR: invalid domain` / `cannot resolve` | fix that line in `agents/<repo>/allowlist.txt` |
| `[firewall] ERROR ...` / exit 4 at start | container needs the capabilities `bin/agent` adds; check DNS on the host |
| request to some host hangs/refused | host not in `docker/allowlist.txt` or `agents/<repo>/allowlist.txt` |
| works by hand, nothing happens from cron | check `logs/cron.log`; `docker ps` must work without sudo; PATH line in crontab |

## Layout

```
bin/agent        host wrapper (secrets, lock, docker run, agent.log)
docker/          Dockerfile, entrypoint, firewall, allowlist, verify.sh
runner/          run-agent.sh (inside container), lib.sh (generic helpers for hooks); Claude only
agents/<repo>/   everything for one target repo: repo.env, optional allowlist.txt, one folder per agent
  <agent>/       agent.env, .env (secrets, gitignored, 600), pre.sh, check.sh, post.sh (+ files they use);
                 instructions: target repo .claude/agents/<agent>.md
agents/example/  scaffold for a new repo with one commented agent, my-agent (copy to agents/<repo>/)
examples/        claude-agents/my-agent.md: the matching agent definition for the target repo
secrets/         .env (Claude token; gitignored, 600), .env.example
logs/            logs/<repo>/<agent>/ run logs (gitignored); logs/cron.log for scheduled runs
.locks/          per-agent flock files (gitignored)
```
