#!/usr/bin/env bash
set -euo pipefail
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

SWARM_HOME="${SWARM_HOME:-${HOME}/.agent-swarm}"

PENDING_FILE="$SWARM_HOME/notifications.pending"

notify_pending() {
  mkdir -p "$SWARM_HOME"
  touch "$PENDING_FILE"
  printf "[%s] NOTIFY: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$PENDING_FILE"
}

usage() {
  cat <<EOF
Usage: run-agent.sh --project <name> <task-id> <model> <reasoning>

Arguments:
  --project <name>   Project config name
  <task-id>          Task identifier
  <model>            e.g. gpt-5.3-codex | claude-sonnet-4-6 | claude-opus-4-6
  <reasoning>        low | medium | high
EOF
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

PROJECT=""
TASK_ID=""
MODEL=""
REASONING=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --help|-h) usage 0 ;;
    *)
      if [[ -z "$TASK_ID" ]]; then TASK_ID="$1"
      elif [[ -z "$MODEL" ]]; then MODEL="$1"
      elif [[ -z "$REASONING" ]]; then REASONING="$1"
      else die "Unexpected argument: $1"
      fi
      shift ;;
  esac
done

[[ -n "$PROJECT" && -n "$TASK_ID" && -n "$MODEL" && -n "$REASONING" ]] || usage 1

need jq
CONFIG_FILE="$SWARM_HOME/projects/${PROJECT}.json"
[[ -f "$CONFIG_FILE" ]] || die "Project config not found: $CONFIG_FILE"

REPO=$(jq -r '.repo' "$CONFIG_FILE")
BASE_BRANCH=$(jq -r '.baseBranch' "$CONFIG_FILE")
WORKTREE_BASE=$(jq -r '.worktreeBase' "$CONFIG_FILE")
TASKS_FILE=$(jq -r '.tasksFile' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.logDir' "$CONFIG_FILE")
LOG_FILE="$LOG_DIR/$TASK_ID.log"

WORKTREE_DIR="$WORKTREE_BASE/$TASK_ID"
PROMPT_FILE="$SWARM_HOME/.prompts/$PROJECT/$TASK_ID.txt"

[[ -d "$WORKTREE_DIR" ]] || die "Worktree not found: $WORKTREE_DIR"
[[ -f "$PROMPT_FILE" ]] || die "Prompt file not found: $PROMPT_FILE"

cd "$WORKTREE_DIR"
PROMPT=$(cat "$PROMPT_FILE")

PR_INSTRUCTIONS=$(printf '\nStart by reading AGENTS.md in the repo root for project architecture and conventions.\n\nDEFINITION OF DONE — your PR is NOT done until ALL of these:\n- Code compiles without errors (run type checks if available)\n- All existing tests pass\n- New code has basic error handling\n- No merge conflicts with %s\n- PR description explains WHAT changed and WHY\n- If UI changes: include a screenshot in PR description\n\nWhen implementation is done:\n1) Run lint/type checks if configured\n2) git add -A\n3) git commit -m "feat(%s): implement task"\n4) git push -u origin HEAD\n5) gh pr create --base %s --fill --body "## Changes\n<describe what changed>\n\n## Testing\n<how was it tested>"\n\nIf PR already exists, update branch and continue.\n' "$BASE_BRANCH" "$TASK_ID" "$BASE_BRANCH")

FULL_PROMPT="${PROMPT}
${PR_INSTRUCTIONS}"

update_task_field() {
  local jq_expr="$1"
  [[ -f "$TASKS_FILE" ]] || return 0
  jq --arg id "$TASK_ID" "$jq_expr" "$TASKS_FILE" > "${TASKS_FILE}.tmp" && mv "${TASKS_FILE}.tmp" "$TASKS_FILE"
}

is_rate_limit_failure() {
  [[ -f "$LOG_FILE" ]] || return 1
  tail -n 200 "$LOG_FILE" | tr "[:upper:]" "[:lower:]" | grep -qE "rate[ -]?limit|usage[ -]?limit|too many requests|\b429\b|quota|capacity|exceeded.*limit|throttl|hit your usage limit|max_tokens_per|try again in|credit balance|billing"
}

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    if is_rate_limit_failure; then
      update_task_field 'map(if .id==$id then .status="rate_limited" | .lastError="rate limit detected" else . end)'
      notify_pending "[$PROJECT] Task $TASK_ID rate-limited (attempt may need resume)"
      echo "[run-agent] rate-limited: task=$TASK_ID rc=$rc"
    else
      update_task_field 'map(if .id==$id then .status="failed" | .lastError="agent process exited non-zero" else . end)'
      notify_pending "[$PROJECT] Task $TASK_ID FAILED (agent exited non-zero, rc=$rc)"
      echo "[run-agent] failed: task=$TASK_ID rc=$rc"
    fi
  else
    # Detect PR created by agent
    local pr_num current_branch
    current_branch=$(cd "$WORKTREE_DIR" && git branch --show-current 2>/dev/null || echo "")
    if [[ -n "$current_branch" ]]; then
      pr_num=$(cd "$WORKTREE_DIR" && gh pr list --head "$current_branch" --json number --jq '.[0].number' 2>/dev/null || echo "")
    else
      pr_num=""
    fi
    if [[ -n "$pr_num" && "$pr_num" != "null" && "$pr_num" != "" ]]; then
      update_task_field 'map(if .id==$id then .pr='"$pr_num"' | .status="pr_open" | .lastError=null else . end)'
      echo "[run-agent] exited cleanly: task=$TASK_ID pr=#$pr_num"
      # Trigger immediate review — do not wait for launchd monitor tick
      if [[ -x "$SWARM_HOME/scripts/check-agents.sh" ]]; then
        local review_session="review-${PROJECT}-${TASK_ID}"
        tmux kill-session -t "$review_session" 2>/dev/null || true
        tmux new-session -d -s "$review_session"           "bash '$SWARM_HOME/scripts/check-agents.sh' --project '$PROJECT' --task '$TASK_ID' >> '$LOG_DIR/${TASK_ID}-check.log' 2>&1" 2>/dev/null || true
        echo "[run-agent] triggered immediate review: $review_session"
      fi
    else
      update_task_field 'map(if .id==$id then .status="failed" | .lastError="agent exited without creating PR" else . end)'
      notify_pending "[$PROJECT] Task $TASK_ID FAILED (agent exited without PR)"
      echo "[run-agent] exited cleanly: task=$TASK_ID (no PR detected)"
    fi
  fi
}
trap cleanup EXIT

# Write prompt to file for reference/logging
TMP_PROMPT=$(mktemp)
printf '%s\n' "$FULL_PROMPT" > "$TMP_PROMPT"
cp "$TMP_PROMPT" "$LOG_DIR/${TASK_ID}.prompt.txt"

# Run agent in nested tmux session for proper TTY (Elvis-style)
# Mid-task redirection: tmux send-keys -t "$TASK_ID" "correction" Enter
INNER_SESSION="${TASK_ID}"
DONE_MARKER="$LOG_DIR/${TASK_ID}.done"
rm -f "$DONE_MARKER"

# Write wrapper script to avoid prompt quoting issues
WRAPPER="$LOG_DIR/${TASK_ID}.wrapper.sh"
{
  echo '#!/usr/bin/env bash'
  echo "export PATH=\"${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\""
  if [[ "$MODEL" == *"codex"* ]]; then
    need codex
    printf 'codex --model %q -c %q --dangerously-bypass-approvals-and-sandbox "$(cat %q)"\n' \
      "$MODEL" "model_reasoning_effort=${REASONING}" "$TMP_PROMPT"
  elif [[ "$MODEL" == *"claude"* ]]; then
    need claude
    printf 'claude --model %q --dangerously-skip-permissions "$(cat %q)"\n' \
      "$MODEL" "$TMP_PROMPT"
  else
    die "Unsupported model: $MODEL"
  fi
  printf 'echo $? > %q\n' "$DONE_MARKER"
} > "$WRAPPER"
chmod +x "$WRAPPER"

tmux kill-session -t "$INNER_SESSION" 2>/dev/null || true
tmux new-session -d -s "$INNER_SESSION" -x 220 -y 50
tmux send-keys -t "$INNER_SESSION" "bash $(printf '%q' "$WRAPPER")" Enter
echo "[run-agent] agent running in tmux: $INNER_SESSION"
echo "[run-agent] steer: tmux send-keys -t $INNER_SESSION "correction" Enter"

# Wait for agent to finish
while [[ ! -f "$DONE_MARKER" ]]; do
  sleep 10
done
AGENT_RC=$(cat "$DONE_MARKER" | tr -d '[:space:]' 2>/dev/null || echo 1)
rm -f "$DONE_MARKER" "$WRAPPER"

# Capture pane output to supplement log
tmux capture-pane -t "$INNER_SESSION" -p -S -32768 >> "$LOG_DIR/${TASK_ID}.agent.log" 2>/dev/null || true
tmux kill-session -t "$INNER_SESSION" 2>/dev/null || true
rm -f "$TMP_PROMPT"
exit "${AGENT_RC:-0}"
