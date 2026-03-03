# agent-swarm

One-person dev team running on Codex and Claude. You write a task, the swarm spawns an agent in a tmux session, it opens a PR, reviews run automatically, you merge.

No dashboards. No cloud. Just bash, tmux, and GitHub.

## How it works

```
spawn-agent.sh  →  tmux session with Codex/Claude
                →  agent writes code, opens PR
check-agents.sh →  CI passes? run local-review.sh
                →  Codex + Claude review via commit statuses
                →  all green → notify "ready for review"
                →  CI failed → respawn with review comments
```

The monitor runs on a cron every 10 minutes and calls `check-agents.sh --all`. When a PR is ready, it writes to `notifications.pending` — hook that into anything (Telegram, Slack, webhook, whatever).

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
export SWARM_HOME=~/.agent-swarm  # add this to ~/.zshrc or ~/.bashrc
```

Copy the example project config:

```bash
cp ~/.agent-swarm/projects/example.json ~/.agent-swarm/projects/myproject.json
# edit it
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

`requireGemini: true` blocks merge until Gemini Code Assist posts a passing review. The GitHub App is free to install.

## Spawning a task

```bash
bash ~/.agent-swarm/scripts/spawn-agent.sh \
  --project myproject \
  fix-login-bug \
  codex \
  "Fix the login bug where users get logged out on page refresh. Check auth/session.ts."
```

Agent type: `codex` | `claude` | `auto`

`auto` routes frontend/UI tasks to Claude, everything else to Codex.

Use `--fix` for `fix/task-id` branches instead of `feat/task-id`.

## Mid-task steering

If the agent is going in the wrong direction:

```bash
tmux send-keys -t fix-login-bug "Don't touch session.ts, the bug is in middleware/auth.ts" Enter
```

## Checking status

```bash
bash ~/.agent-swarm/scripts/check-agents.sh --project myproject
# or
bash ~/.agent-swarm/scripts/check-agents.sh --all
```

## Notifications

When something happens, a line is appended to `$SWARM_HOME/notifications.pending`:

```
[2026-03-03T10:00:00Z] NOTIFY: [myproject] Task fix-login-bug PR #12 ready for review
```

Read and clear it however you want.

## Auto-retry

When CI or review fails, the swarm respawns the agent with the review comments as context. Up to `maxAttempts` tries. After that, you get an `AGENT EXHAUSTED` notification.

Manual respawn:

```bash
bash ~/.agent-swarm/scripts/respawn-agent.sh \
  --project myproject \
  fix-login-bug \
  "Previous attempt broke the tests. Fix only session handling, don't touch the router."
```

## Directory structure

```
~/.agent-swarm/
  scripts/
    spawn-agent.sh       # create worktree + start agent
    run-agent.sh         # run codex/claude in tmux, handle exit
    check-agents.sh      # poll PR status, trigger reviews
    local-review.sh      # run reviews, set commit statuses
    respawn-agent.sh     # retry failed task with new prompt
    monitor-loop.sh      # cron entrypoint
    cleanup-agents.sh    # remove stale worktrees and sessions
  projects/
    myproject.json
  .prompts/
    myproject/
      fix-login-bug.txt  # auto-created by spawn-agent.sh
  notifications.pending
  monitor.log
  patterns.log
```

## AGENTS.md

Put an `AGENTS.md` in your repo root. The swarm reads it at the start of every task. The agent will make fewer mistakes.

```markdown
# AGENTS.md

## Stack
- Backend: NestJS, TypeScript, PostgreSQL
- Frontend: Next.js, Tailwind

## Conventions
- Services in src/services/
- Always add error handling to async functions
- Run `npm run type-check` before committing
```

## Tips

- Keep tasks small. "Refactor the entire auth system" will fail. "Extract token refresh into a separate service" will work.
- Gemini Code Assist (GitHub App, free) catches stuff Codex and Claude miss. Worth installing.
- `patterns.log` accumulates hints from successful runs — the respawn logic uses it when retrying.
