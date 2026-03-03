#!/usr/bin/env bash
set -euo pipefail
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

SWARM_HOME="${SWARM_HOME:-${HOME}/.vibe-swarm}"

usage() {
  cat <<EOF
Usage: respawn-agent.sh --project <name> [--preserve-attempts] <task-id> [new-prompt]

Arguments:
  --project <name>   Project config name
  <task-id>          Task identifier
  [new-prompt]       Optional replacement prompt for retry

Options:
  --preserve-attempts  Do not increment attempts counter (for rate-limit retries)
EOF
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

PROJECT=""
TASK_ID=""
NEW_PROMPT=""
PRESERVE_ATTEMPTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --preserve-attempts) PRESERVE_ATTEMPTS=true; shift ;;
    --help|-h) usage 0 ;;
    *)
      if [[ -z "$TASK_ID" ]]; then TASK_ID="$1"
      elif [[ -z "$NEW_PROMPT" ]]; then NEW_PROMPT="$1"
      else die "Unexpected argument: $1"
      fi
      shift ;;
  esac
done

[[ -n "$PROJECT" && -n "$TASK_ID" ]] || usage 1
need jq
need git
need tmux

CONFIG_FILE="$SWARM_HOME/projects/${PROJECT}.json"
[[ -f "$CONFIG_FILE" ]] || die "Project config not found: $CONFIG_FILE"

REPO=$(jq -r '.repo' "$CONFIG_FILE")
BASE_BRANCH=$(jq -r '.baseBranch' "$CONFIG_FILE")
WORKTREE_BASE=$(jq -r '.worktreeBase' "$CONFIG_FILE")
TASKS_FILE=$(jq -r '.tasksFile' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.logDir' "$CONFIG_FILE")

[[ -f "$TASKS_FILE" ]] || die "Tasks file not found: $TASKS_FILE"

TASK_JSON=$(jq -c --arg id "$TASK_ID" '.[] | select(.id==$id)' "$TASKS_FILE")
[[ -n "$TASK_JSON" ]] || die "Task not found: $TASK_ID"

SESSION=$(echo "$TASK_JSON" | jq -r '.tmuxSession')
BRANCH=$(echo "$TASK_JSON" | jq -r '.branch')
AGENT=$(echo "$TASK_JSON" | jq -r '.agent')
ATTEMPTS=$(echo "$TASK_JSON" | jq -r '.attempts // 1')
MAX_ATTEMPTS=$(echo "$TASK_JSON" | jq -r '.maxAttempts // 3')

if [[ "$PRESERVE_ATTEMPTS" == "true" ]]; then
  NEXT_ATTEMPT=$ATTEMPTS
else
  NEXT_ATTEMPT=$((ATTEMPTS + 1))
  [[ $NEXT_ATTEMPT -le $MAX_ATTEMPTS ]] || die "Max attempts reached ($MAX_ATTEMPTS)"
fi

WORKTREE_DIR="$WORKTREE_BASE/$TASK_ID"
PROMPT_FILE="$SWARM_HOME/.prompts/$PROJECT/$TASK_ID.txt"
LOG_FILE="$LOG_DIR/$TASK_ID.log"

mkdir -p "$LOG_DIR" "$(dirname "$PROMPT_FILE")"

if [[ -n "$NEW_PROMPT" ]]; then
  cat > "$PROMPT_FILE" <<EOF
$NEW_PROMPT
EOF
fi

# kill old session if exists
if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
fi

# reset worktree state
[[ -d "$WORKTREE_DIR" ]] || die "Worktree missing: $WORKTREE_DIR"
cd "$WORKTREE_DIR"
git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
git checkout "$BRANCH" >/dev/null 2>&1 || true
git reset --hard "origin/$BRANCH" >/dev/null 2>&1 || git reset --hard >/dev/null 2>&1 || true
git clean -fd >/dev/null 2>&1 || true

MODEL="gpt-5.3-codex"
REASONING="high"
if [[ "$AGENT" == "claude" ]]; then
  MODEL="claude-sonnet-4-6"
  REASONING="high"
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg id "$TASK_ID" --arg now "$NOW" --argjson attempts "$NEXT_ATTEMPT" \
  'map(if .id==$id then .status="running" | .attempts=$attempts | .lastError=null | .startedAt=$now else . end)' \
  "$TASKS_FILE" > "${TASKS_FILE}.tmp"
mv "${TASKS_FILE}.tmp" "$TASKS_FILE"

# restart agent
tmux new-session -d -s "$SESSION" \
  "bash '$SWARM_HOME/scripts/run-agent.sh' --project '$PROJECT' '$TASK_ID' '$MODEL' '$REASONING' >> '$LOG_FILE' 2>&1"

if [[ "$PRESERVE_ATTEMPTS" == "true" ]]; then
  echo "Respawned $SESSION (rate-limit resume, attempts preserved: $NEXT_ATTEMPT/$MAX_ATTEMPTS)"
else
  echo "Respawned $SESSION (attempt $NEXT_ATTEMPT/$MAX_ATTEMPTS)"
fi
