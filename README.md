# agents-runner

Run Claude Code agents on a schedule against your own repositories, on your
**Claude Pro/Max subscription**. Each run is one fresh, firewalled Docker container on your
machine: a script prepares the task, Claude Code works on the code headless (`claude -p`),
and a script takes the result and does something with it.

What an agent does is up to you. It relies on the Claude defined agents inside the repository. It's a small personal tool. Bash, Docker and cron. No server, no database, no UI.

## How it works

```
cron ─▶ bin/agent <repo> <agent>
         └─ fresh Docker container (non-root, outbound traffic blocked except an allowlist)
             ├─ pre.sh    get the code, build the task         ← your secrets
             ├─ claude    read (and edit) the code             ← Claude token only
             ├─ check.sh  run tests on the model's changes     ← no secrets
             └─ post.sh   validate the answer, act on it       ← your secrets
```

The model only works on code. Everything with side effects (cloning, pushing, creating
issues, sending messages) is done by your small bash scripts before and after it, so the
model never sees your tokens. All three scripts are optional.

## Writing an agent

An agent is one folder, `agents/<repo>/<agent>/`, plus an agent definition
`.claude/agents/<agent>.md` in the target repo (the instructions). The scaffold in
[`agents/example/my-agent/`](agents/example/my-agent/) shows every step with comments.
Data flows like this:

| Step | Gets | Gives |
|---|---|---|
| `pre.sh` | an empty working directory, config, your secrets | **stdout = the prompt** for the model; files in `$STATE_DIR` for post.sh; `exit 78` = nothing to do |
| `claude` | the prompt, the working directory, `ALLOWED_TOOLS` | its final message, saved as **`$RESULT_JSON`** (`.result` = the text) |
| `check.sh` | the working directory, no secrets | exit code as **`CHECK_EXIT`**, output as `CHECK_LOG` |
| `post.sh` | `$RESULT_JSON`, `$STATE_DIR`, `CHECK_EXIT`, your secrets | the action; optionally a URL in `$STATE_DIR/output_url` for the stats |

The pattern that works: pre.sh ends the prompt with an exact output format (the scaffold asks
for one JSON object), and post.sh parses `.result` from `$RESULT_JSON`, validates it and only
then acts. Treat everything the model produced as untrusted input.

```bash
# post.sh, the core of it
answer=$(jq -r '.result' "$RESULT_JSON")           # the model's final message
jq -e 'has("skip")' <<<"$answer" >/dev/null && exit 0   # "nothing to report" is fine
summary=$(jq -r '.summary // empty' <<<"$answer")   # validate, then act
```

Details: [docs/reference.md](docs/reference.md#writing-an-agent).

## What to expect

- Every result goes through your post.sh: nothing reaches anything or anywhere else unless your script sends it.
- Runs use your Claude subscription quota, so schedule them at night.
  `logs/stats.csv` shows tokens and time per run.
- Quality depends mostly on the target repo: a good `CLAUDE.md` and a good agent definition.
- PCurrently supports: Claude Code only, Linux only (not tested on MacOS nor Windows).

## Security

- Each run gets a fresh container. The firewall is set up first, then the run drops to a
  non-root user without privileges, so the agent can't change the firewall.
- Outbound traffic is denied except the Claude API plus the domains you allow per repo.
- Secrets enter the container on stdin, never as environment variables or mounted files.
  The Claude token reaches only Claude; each agent's own secrets (one token per agent,
  least privilege) reach only its pre.sh and post.sh.
- Model-written code runs only in the Claude step and in check.sh, which has no secrets.

Details: [Secrets never reach the model](docs/reference.md#secrets-never-reach-the-model).

## Prerequisites

**Your machine:** Linux (x86_64), Docker usable without `sudo`, `bash`, `git`, `flock`,
a Claude Pro or Max subscription, and the Claude Code CLI (once, to create a token).
About 6 GB RAM and 2 CPUs per running agent. No need to set `ANTHROPIC_API_KEY`: it uses Claude Code CLI in headless mode.
### Prerequisites: the target repository

Pushed to the default branch:

- `.claude/agents/<agent>.md` for each agent. Start from [`examples/claude-agents/my-agent.md`](examples/claude-agents/my-agent.md).
- `CLAUDE.md`: how to build and test, architecture, code style (the agent reads it first).
- No committed `.claude/settings.json` with `permissions.allow`.
- If an agent pushes code: tests that run headless without secrets, and branch protection
  on the default branch without admin bypass.

## Setup

**1. Claude token**

```bash
git clone <this repo> agents-runner && cd agents-runner
cp secrets/.env.example secrets/.env && chmod 600 secrets/.env
claude setup-token        # paste the token into secrets/.env as CLAUDE_CODE_OAUTH_TOKEN
```

**2. Agent definition in your repo**

```bash
mkdir -p ~/src/myrepo/.claude/agents
cp examples/claude-agents/my-agent.md ~/src/myrepo/.claude/agents/
# adapt it, then commit and push
```

**3. Config for your repo here**

```bash
cp -r agents/example agents/myrepo
```

| File | Set |
|---|---|
| `agents/myrepo/repo.env` | `REPO_URL=` your repo, `IMAGE=` a base image with your toolchain (default JDK 25) |
| `agents/myrepo/allowlist.txt` | the domains your hooks and tests need |
| `agents/myrepo/my-agent/agent.env` | `ALLOWED_TOOLS`, limits, your own settings |
| `agents/myrepo/my-agent/pre.sh`, `post.sh` | what happens before and after the model |
| `agents/myrepo/my-agent/.env` | only if the hooks need secrets: from `.env.example`, `chmod 600` |

**4. First run**: run it by hand and read the result before scheduling:

```bash
bin/agent myrepo my-agent
bin/agent                         # list repos and agents
cat logs/myrepo/my-agent/latest/run.log
```

The image is built automatically on the first run. `docker/verify.sh` checks the firewall
and tools.

## Scheduling

Add the agents to your crontab (`crontab -e`):

```cron
PATH=/usr/local/bin:/usr/bin:/bin
AGENTS_RUNNER=/home/you/agents-runner
0 2 * * *  $AGENTS_RUNNER/bin/agent myrepo my-agent >> $AGENTS_RUNNER/logs/cron.log 2>&1
```

Overlapping runs of the same agent are skipped. Missed runs (machine off) are not caught up.

## Logs

Each run gets its own folder, `logs/<repo>/<agent>/<timestamp>/`, with the run log,
status, the prompt (`input.md`), the full Claude transcript and `result.json`. `latest` points
to the newest run. `logs/stats.csv` has one row per run: status, duration, tokens, tool calls.

## More

- [docs/reference.md](docs/reference.md): writing hooks, configuration, images per stack,
  caches, network access, log and stats details, troubleshooting.
- `CLAUDE.md`: design decisions and security rules.

`agents/example/` is the only committed agent folder. Your own `agents/<repo>/` folders are
gitignored, so your configs stay local.

CI runs [shellcheck](https://www.shellcheck.net/) on every shell script.
Licensed under the [MIT License](LICENSE).
