# agents-runner

Scheduled Claude Code agents for GitHub repos: `claude -p` runs headless in a fresh, firewalled
Docker container on the owner's machine, on a Claude Pro/Max subscription
(`CLAUDE_CODE_OAUTH_TOKEN`; never set `ANTHROPIC_API_KEY`).

## Scope
A personal tool in bash: one owner, one machine, a few repos. cron + flock + log files +
`stats.csv` are the whole platform; no rewrite planned. Do not add a daemon, database, API, UI,
workflow language, multi-user features or plugins. If a need outgrows bash + cron, use an
existing tool (e.g. `anthropics/claude-code-action`) instead.

Effort goes into what the agents produce and into the security rules below.
Keep README.md accurate when behaviour or requirements change; details go in docs/reference.md.

## Layout
```
bin/agent        host wrapper: bin/agent <repo> <agent> → docker run … runner/run-agent.sh
runner/          generic, runs inside the container; knows only Claude Code (no git/GitHub)
docker/          image, firewall, base allowlist (Claude API only), verify.sh
agents/<repo>/   one target repo: repo.env, optional allowlist.txt and helpers, one folder per agent
  <agent>/       agent.env, optional .env (secrets) and pre.sh / check.sh / post.sh hooks
agents/example/  scaffold: one commented agent (my-agent) showing the hook contract;
                 the only committed agents/ folder. Keep it generic and tool-neutral (no gh)
examples/        claude-agents/my-agent.md: the scaffold's agent definition for a target repo
secrets/         .env with the Claude token (gitignored)
logs/, .locks/   run logs, stats.csv, flock files (gitignored)
```

## Conventions
- Adding an agent = adding a folder `agents/<repo>/<agent>/`; no runner or image changes.
  Its instructions live in the target repo (`.claude/agents/<agent>.md`), not here.
- Config: `repo.env`, then `agent.env` (later wins). `ALLOWED_TOOLS` is set here on purpose:
  the repo agent can narrow it, never widen it. Full reference: header of `runner/run-agent.sh`.
- Hooks: `pre.sh` prepares the workdir and prints the task (exit 78 = nothing to do);
  `check.sh` runs model-written code (tests) without secrets; `post.sh` verifies and publishes.
  Hooks share helpers only within their own repo folder.
- `runner/` and `bin/agent` use only Docker and Claude Code. Anything target-specific (git,
  GitHub) belongs in an agent's hooks.
- Committed: everything except secrets, logs and real `agents/<repo>/` folders. Nothing
  owner-specific (repo names, paths, tokens) in committed files.

## Security rules (do not weaken)
- Non-root container user. Never mount ~/.ssh, ~/.aws or the Docker socket.
- Default-deny outbound firewall. Base allowlist = Claude API only; extra domains only via
  `agents/<repo>/allowlist.txt` in this repo (never the target repo or the model). Keep it minimal.
- Agent secrets: one token per agent, least privilege (e.g. a fine-grained GitHub token for one repo).
- Prefer `--allowedTools` over `--dangerously-skip-permissions`.
- The model only reads and edits code. Clone, branch, commit, push, issues, PRs and labels are
  done by hooks.
- No secret reaches the model or code it wrote: the Claude token goes only to claude, agent
  secrets only to pre.sh/post.sh, always via stdin. post.sh never executes anything from the
  working tree (details: docs/reference.md "Secrets never reach the model").
- PRs are always drafts; the target repo's default branch is protected.

## Working style
- Smallest change that works; no new abstractions until a second agent needs them.
- Shell: `set -euo pipefail`, shellcheck-clean (CI checks it), small functions.
- Never commit secrets; keep the `.env.example` files in sync with required variables.
- Progress: `TODO.md`.
