# agent-swarm

One-person dev team powered by Codex and Claude. You describe a task, agents write the code and open PRs, reviews run automatically, you merge.

No dashboards. No cloud. Just bash, tmux, and GitHub.

## The workflow

```
You (Telegram / terminal)
  ↓
OpenClaw (AI orchestrator) — or you directly via CLI
  ↓ spawn-agent.sh
Codex / Claude (tmux + git worktree)
  ↓ writes code, opens PR
check-agents.sh (cron, every 10 min)
  ↓ CI passed → local-review.sh
  ↓ Codex review + Claude review + Gemini + screenshot gate
  → all green → notifications.pending → you get pinged
  → review failed → respawn with failure context injected
```

Each task gets its own git worktree and tmux session. Multiple agents can run in parallel.

## Requirements

- bash 5+
- tmux
- jq
- gh (GitHub CLI, authenticated)
- codex CLI — `npm install -g @openai/codex`
- claude CLI — `npm install -g @anthropic-ai/claude-code`

## Setup

```bash
git clone https://github.com/YOUR_USER/agent-swarm ~/.agent-swarm
```

Add to `~/.zshrc` or `~/.bashrc`:

```bash
export SWARM_HOME=~/.agent-swarm
```

Copy and edit the example project config:

```bash
cp ~/.agent-swarm/projects/example.json ~/.agent-swarm/projects/myproject.json
```

Add a cron:

```
*/10 * * * * SWARM_HOME=~/.agent-swarm bash ~/.agent-swarm/scripts/monitor-loop.sh >> ~/.agent-swarm/monitor.log 2>&1
```

## Project config

```json
{
  "name": "myproject",
  "repo": "/path/to/local/repo",
  "remote": "github-user/repo-name",
  "baseBranch": "main",
  "worktreeBase": "/path/to/worktrees",
  "tasksFile": "/path/to/worktrees/active-tasks.json",
  "logDir": "/path/to/worktrees/logs",
  "maxAttempts": 3,
  "reviewMode": "local",
  "requireGemini": false,
  "reviewContexts": {
    "codex": "local/codex-review",
    "claude": "local/claude-review",
    "gemini": "local/gemini-review",
    "screenshot": "local/screenshot-gate"
  }
}
```

## Spawning a task

```bash
bash ~/.agent-swarm/scripts/spawn-agent.sh \
  --project myproject \
  fix-login-bug \
  codex \
  "Fix the login bug where users get logged out on page refresh. Check auth/session.ts."
```

Agent type: `codex` | `claude` | `auto`

`auto` routes frontend/UI tasks (React, CSS, Tailwind, components) to Claude and everything else to Codex.

Use `--fix` for `fix/task-id` branches instead of `feat/task-id`.

## Giving agents context

Agents start fresh each run. Without context they make generic decisions. The more you give them upfront, the fewer corrections you need mid-run.

### AGENTS.md in the repo root

Put `AGENTS.md` in your repo root. Every agent reads it before starting. Cover stack, directory layout, naming conventions, how to run tests, and things agents commonly get wrong.

```markdown
# AGENTS.md

## Stack
- NestJS 10, TypeScript 5, PostgreSQL 15
- Frontend: Next.js 14, Tailwind CSS

## Structure
- src/services/ — business logic
- src/dto/ — request/response types

## Before committing
- Run: npm run type-check && npm test
- No console.log in production code
- All async functions must have try/catch
```

### Business context in the prompt

The task prompt is the main channel for business context. Be explicit about constraints, edge cases, which files to touch, and what to avoid:

```bash
bash ~/.agent-swarm/scripts/spawn-agent.sh \
  --project myproject \
  add-invoice-pdf \
  codex \
  "Add PDF export for invoices.

  Context: customers use this for accounting software.
  - Use existing InvoiceService, don't create a new one
  - Prices always EUR with 2 decimal places
  - PDF layout must match the on-screen view
  Start in: src/services/invoice.service.ts"
```

### Shared product context file

For larger projects, maintain a context file and prepend it to every prompt:

```bash
CONTEXT=$(cat ~/projects/myproject/product-context.md)
bash ~/.agent-swarm/scripts/spawn-agent.sh \
  --project myproject task-id codex \
  "$CONTEXT

  Task: Fix ProductRepository.findAll() missing tenantId filter."
```

## Reviews

After CI passes, `local-review.sh` runs automatically and sets four GitHub commit statuses.

### local/codex-review

Codex reads the PR diff and outputs `VERDICT: PASS` or `VERDICT: FAIL` with bugs, security issues, or regressions. Style nitpicks are ignored. Result posted as PR comment.

### local/claude-review

Claude runs in critical-only mode — only flags things that will crash in production, cause data loss, create a security vulnerability, or break existing functionality. If nothing critical, it passes. Also posted as PR comment.

### local/screenshot-gate

If the PR touches UI files (`.tsx`, `.jsx`, `.css`, `.scss`, `.vue`, `.svelte`), checks whether the PR description contains a screenshot. No screenshot → fails. Non-UI PRs pass automatically.

### local/gemini-review

Checks whether [Gemini Code Assist](https://github.com/apps/gemini-code-assist) (GitHub App, free) has reviewed or commented. With `requireGemini: true`, this gate must pass before the task is marked `review_ready`. Gemini is independent from Codex and Claude and tends to catch different things.

### GitHub token permissions

The `gh` CLI needs permission to set commit statuses. Make sure your token has the `repo` scope (or `statuses:write` for fine-grained tokens).

## Auto-retry

When CI or a review fails, the swarm respawns the agent with a new prompt containing the review comments, failed check names, the original task, and hints from `patterns.log`. Up to `maxAttempts` retries.

After all attempts are exhausted, you get an `AGENT EXHAUSTED` notification.

Manual respawn:

```bash
bash ~/.agent-swarm/scripts/respawn-agent.sh \
  --project myproject \
  fix-login-bug \
  "Previous attempt broke the tests. Fix only session handling, don't touch the router."
```

## patterns.log

When an agent succeeds after a retry, a hint is written to `patterns.log`. On future retries for similar tasks, these hints are injected into the prompt automatically. You can also edit the file manually to add project-specific guidance.

## Mid-task steering

If an agent is going in the wrong direction:

```bash
tmux send-keys -t fix-login-bug "Don't touch session.ts, the bug is in middleware/auth.ts" Enter
```

The inner tmux session name matches the task ID.

## Notifications

Events are appended to `$SWARM_HOME/notifications.pending`:

```
[2026-03-03T10:00:00Z] NOTIFY: [myproject] Task fix-login-bug PR #12 ready for review
[2026-03-03T10:05:00Z] NOTIFY: [myproject] Task fix-login-bug PR #12 Claude review FAILED
[2026-03-03T10:10:00Z] NOTIFY: [myproject] AGENT EXHAUSTED fix-login-bug — all 3 attempts used
```

Read and clear it however you want.

### Instant notifications with OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) can act as the orchestrator and notification layer. It reads `notifications.pending` on a heartbeat and forwards events to Telegram (or Slack, Signal, Discord). It can also spawn tasks, steer agents mid-run, and decide when to intervene vs. let the swarm retry.

`notify-instant.sh` uses a filesystem watcher (macOS `launchd` WatchPaths or Linux `inotifywait`) to trigger the moment something is written — no waiting for the next cron tick.

launchd plist example:

```xml
<key>WatchPaths</key>
<array>
    <string>/path/to/.agent-swarm/notifications.pending</string>
</array>
<key>ProgramArguments</key>
<array>
    <string>bash</string>
    <string>/path/to/.agent-swarm/scripts/notify-instant.sh</string>
</array>
```

Set `NOTIFY_CHANNEL`, `NOTIFY_TARGET`, and `OPENCLAW_CONFIG` environment variables.

## Checking status

```bash
bash ~/.agent-swarm/scripts/check-agents.sh --project myproject
bash ~/.agent-swarm/scripts/check-agents.sh --all
```

## Directory structure

```
~/.agent-swarm/
  scripts/
    spawn-agent.sh       # create worktree + start agent
    run-agent.sh         # run codex/claude in tmux, handle exit
    check-agents.sh      # poll PR/CI status, trigger reviews, auto-retry
    local-review.sh      # codex + claude + gemini + screenshot review
    respawn-agent.sh     # retry a failed task with a new prompt
    monitor-loop.sh      # cron entrypoint
    notify-instant.sh    # instant notifications via filesystem watcher
    cleanup-agents.sh    # remove stale worktrees and sessions
  projects/
    example.json
  .prompts/
    myproject/
      fix-login-bug.txt  # auto-created by spawn-agent.sh
  notifications.pending
  monitor.log
  patterns.log
```

## Tips

- Keep tasks small. "Refactor the entire auth system" will fail. "Extract token refresh into a separate service" will work.
- Gemini Code Assist is free and independent — catches different things than Codex and Claude.
- `auto` agent routing works well as a default once you have a clear frontend/backend split.
- The whole thing runs on a laptop or a cheap VPS. No cloud infra needed.
