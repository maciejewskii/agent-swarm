#!/usr/bin/env bash
set -euo pipefail
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

SWARM_HOME="${SWARM_HOME:-${HOME}/.agent-swarm}"

usage() {
  cat <<EOF
Usage: spawn-agent.sh --project <name> <task-id> <agent-type> <prompt> [--fix]

Arguments:
  --project <name>   Project config name (projects/<name>.json)
  <task-id>          Task identifier (e.g. auth-refactor)
  <agent-type>       codex | claude | auto
  <prompt>           Task prompt text

Options:
  --fix              Use fix/<task-id> branch prefix (default: feat/)
  --help, -h         Show help
EOF
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

PROJECT=""
TASK_ID=""
AGENT_TYPE=""
PROMPT=""
FIX=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --fix) FIX=true; shift ;;
    --help|-h) usage 0 ;;
    *)
      if [[ -z "$TASK_ID" ]]; then TASK_ID="$1"
      elif [[ -z "$AGENT_TYPE" ]]; then AGENT_TYPE="$1"
      elif [[ -z "$PROMPT" ]]; then PROMPT="$1"
      else die "Unexpected argument: $1"
      fi
      shift ;;
  esac
done

[[ -n "$PROJECT" ]] || usage 1
[[ -n "$TASK_ID" ]] || usage 1
[[ -n "$AGENT_TYPE" ]] || usage 1
[[ -n "$PROMPT" ]] || usage 1

[[ "$AGENT_TYPE" == "codex" || "$AGENT_TYPE" == "claude" || "$AGENT_TYPE" == "auto" ]] || die "agent-type must be codex|claude|auto"

# Agent routing (Elvis-style specialization)
if [[ "$AGENT_TYPE" == "auto" ]]; then
  route_text="${TASK_ID} ${PROMPT}"
  route_lc=$(printf '%s' "$route_text" | tr '[:upper:]' '[:lower:]')
  if echo "$route_lc" | grep -Eq 'frontend|ui|react|tsx|css|tailwind|html|dashboard|component|layout|button|modal|form|page'; then
    AGENT_TYPE="claude"
  else
    AGENT_TYPE="codex"
  fi
  echo "[spawn-agent] auto-routed agent: $AGENT_TYPE"
fi

need jq
need git
need tmux

CONFIG_FILE="$SWARM_HOME/projects/${PROJECT}.json"
[[ -f "$CONFIG_FILE" ]] || die "Project config not found: $CONFIG_FILE"

NAME=$(jq -r '.name' "$CONFIG_FILE")
REPO=$(jq -r '.repo' "$CONFIG_FILE")
BASE_BRANCH=$(jq -r '.baseBranch' "$CONFIG_FILE")
WORKTREE_BASE=$(jq -r '.worktreeBase' "$CONFIG_FILE")
TASKS_FILE=$(jq -r '.tasksFile' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.logDir' "$CONFIG_FILE")
MAX_ATTEMPTS=$(jq -r '.maxAttempts // 3' "$CONFIG_FILE")

[[ -d "$REPO" ]] || die "Repo path does not exist: $REPO"
[[ -n "$BASE_BRANCH" && "$BASE_BRANCH" != "null" ]] || die "Invalid baseBranch in config"

mkdir -p "$WORKTREE_BASE" "$LOG_DIR" "$(dirname "$TASKS_FILE")" "$SWARM_HOME/.prompts/$PROJECT"
[[ -f "$TASKS_FILE" ]] || echo '[]' > "$TASKS_FILE"

PREFIX="feat"
$FIX && PREFIX="fix"
BRANCH="${PREFIX}/${TASK_ID}"
WORKTREE_DIR="$WORKTREE_BASE/$TASK_ID"
SESSION_NAME="agent-${PROJECT}-${TASK_ID}"
PROMPT_FILE="$SWARM_HOME/.prompts/${PROJECT}/${TASK_ID}.txt"
LOG_FILE="$LOG_DIR/${TASK_ID}.log"

if jq -e --arg id "$TASK_ID" '.[] | select(.id==$id and (.status=="running" or .status=="pr_open" or .status=="ci_failed"))' "$TASKS_FILE" >/dev/null 2>&1; then
  die "Task already active: $TASK_ID"
fi

cd "$REPO"
git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true

if [[ -d "$WORKTREE_DIR" ]]; then
  die "Worktree already exists: $WORKTREE_DIR"
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$WORKTREE_DIR" "$BRANCH" >/dev/null
else
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "origin/$BASE_BRANCH" >/dev/null
fi

cd "$WORKTREE_DIR"
if [[ -f pnpm-lock.yaml ]]; then
  pnpm install >/dev/null 2>&1 || true
elif [[ -f package-lock.json ]]; then
  npm ci >/dev/null 2>&1 || true
elif [[ -f package.json ]]; then
  npm install >/dev/null 2>&1 || true
fi

cat > "$PROMPT_FILE" <<EOF
$PROMPT
EOF

MODEL="gpt-5.3-codex"
REASONING="high"
if [[ "$AGENT_TYPE" == "claude" ]]; then
  MODEL="claude-sonnet-4-6"
  REASONING="medium"
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENTRY=$(jq -n \
  --arg id "$TASK_ID" \
  --arg project "$NAME" \
  --arg agent "$AGENT_TYPE" \
  --arg model "$MODEL" \
  --arg tmux "$SESSION_NAME" \
  --arg branch "$BRANCH" \
  --arg wt "$WORKTREE_DIR" \
  --arg pf "$PROMPT_FILE" \
  --arg status "running" \
  --arg started "$NOW" \
  --argjson max "$MAX_ATTEMPTS" \
  '{
    id:$id,
    project:$project,
    agent:$agent,
    model:$model,
    tmuxSession:$tmux,
    branch:$branch,
    worktree:$wt,
    promptFile:$pf,
    status:$status,
    pr:null,
    startedAt:$started,
    completedAt:null,
    attempts:1,
    maxAttempts:$max,
    notifyOnComplete:true,
    lastError:null,
    checks:{
      prCreated:false,
      branchSynced:false,
      ciPassed:false,
      codexReviewPassed:false,
      claudeReviewPassed:false,
      geminiReviewPassed:false,
      screenshotsPassed:false
    }
  }')

jq --arg id "$TASK_ID" --argjson entry "$ENTRY" 'map(select(.id != $id)) + [$entry]' "$TASKS_FILE" > "${TASKS_FILE}.tmp"
mv "${TASKS_FILE}.tmp" "$TASKS_FILE"

# Start tmux agent via run-agent wrapper
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
fi

tmux new-session -d -s "$SESSION_NAME" \
  "bash '$SWARM_HOME/scripts/run-agent.sh' --project '$PROJECT' '$TASK_ID' '$MODEL' '$REASONING' >> '$LOG_FILE' 2>&1"

echo "Spawned $SESSION_NAME"
echo "Branch: $BRANCH"
echo "Worktree: $WORKTREE_DIR"
echo "Log: $LOG_FILE"
