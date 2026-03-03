#!/usr/bin/env bash
set -euo pipefail

SWARM_HOME="${SWARM_HOME:-${HOME}/.vibe-swarm}"
PENDING_FILE="$SWARM_HOME/notifications.pending"
LOCK_DIR="$SWARM_HOME/.check-agents.lock"
RECOVERY_DIR="$SWARM_HOME/.exhausted-recoveries"
GH_TIMEOUT_SECS="${GH_TIMEOUT_SECS:-8}"
AUTO_EXHAUSTED_RECOVERY="${AUTO_EXHAUSTED_RECOVERY:-true}"

usage() {
  cat <<USAGE
Usage: check-agents.sh [--project <name> | --all] [--task <id>] [--quiet]

Options:
  --project <name>   Check one project
  --all              Check all projects
  --task <id>        Limit to one task (requires --project)
  --quiet            Suppress non-NOTIFY logs
  --help, -h         Show help
USAGE
  exit "${1:-0}"
}

log() { [[ "$QUIET" == "true" ]] || echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
notify() {
  local line="NOTIFY: $*"
  echo "$line"
  printf "[%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$PENDING_FILE"
}
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

run_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$pid" >/dev/null 2>&1 || true
  ) &
  local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$killer" >/dev/null 2>&1 || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}


gh_json() {
  local fallback="$1"; shift
  run_timeout "$GH_TIMEOUT_SECS" gh "$@" 2>/dev/null || echo "$fallback"
}

single_line() { tr "\n" " " | tr -s " " | sed -E 's/^ +| +$//g'; }

context_state_from_json() {
  local json="$1"
  local ctx="$2"
  echo "$json" | jq -r --arg c "$ctx" '[.statuses[]? | select(.context==$c)][0].state // "missing"'
}

PROJECT=""
ALL=false
TASK_FILTER=""
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --all) ALL=true; shift ;;
    --task) TASK_FILTER="${2:-}"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    --help|-h) usage 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need jq
need gh
need tmux

mkdir -p "$SWARM_HOME" "$RECOVERY_DIR"
touch "$PENDING_FILE"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "check-agents already running, skip"
  exit 0
fi
cleanup_lock() { rmdir "$LOCK_DIR" >/dev/null 2>&1 || true; }
trap cleanup_lock EXIT

[[ "$ALL" == "true" || -n "$PROJECT" ]] || usage 1
[[ -z "$TASK_FILTER" || -n "$PROJECT" ]] || die "--task requires --project"

process_project() {
  local project="$1"
  local cfg="$SWARM_HOME/projects/${project}.json"
  [[ -f "$cfg" ]] || { log "skip: missing config for $project"; return 0; }

  local name remote tasks_file max_attempts review_mode require_gemini
  local codex_ctx claude_ctx gemini_ctx shot_ctx
  name=$(jq -r '.name' "$cfg")
  remote=$(jq -r '.remote' "$cfg")
  tasks_file=$(jq -r '.tasksFile' "$cfg")
  max_attempts=$(jq -r '.maxAttempts // 3' "$cfg")
  review_mode=$(jq -r '.reviewMode // "local"' "$cfg")
  require_gemini=$(jq -r '.requireGemini // false' "$cfg")
  codex_ctx=$(jq -r '.reviewContexts.codex // "local/codex-review"' "$cfg")
  claude_ctx=$(jq -r '.reviewContexts.claude // "local/claude-review"' "$cfg")
  gemini_ctx=$(jq -r '.reviewContexts.gemini // "local/gemini-review"' "$cfg")
  shot_ctx=$(jq -r '.reviewContexts.screenshot // "local/screenshot-gate"' "$cfg")

  [[ -f "$tasks_file" ]] || return 0

  local ids id task old_status status pr branch session attempts agent maxA
  ids=$(jq -r '.[].id' "$tasks_file")
  for id in $ids; do
    [[ -n "$TASK_FILTER" && "$id" != "$TASK_FILTER" ]] && continue

    task=$(jq -c --arg id "$id" '.[] | select(.id==$id)' "$tasks_file")
    [[ -n "$task" ]] || continue

    old_status=$(echo "$task" | jq -r '.status // "running"')
    status="$old_status"
    pr=$(echo "$task" | jq -r '.pr // empty')
    branch=$(echo "$task" | jq -r '.branch')
    session=$(echo "$task" | jq -r '.tmuxSession // empty')
    [[ -n "$session" ]] || session="agent-${project}-${id}"
    attempts=$(echo "$task" | jq -r '.attempts // 1')
    agent=$(echo "$task" | jq -r '.agent // "auto"')
    maxA=$(echo "$task" | jq -r '.maxAttempts // empty')
    [[ -n "$maxA" && "$maxA" != "null" ]] || maxA="$max_attempts"

    local tmux_alive=false
    tmux has-session -t "$session" 2>/dev/null && tmux_alive=true

    [[ "$old_status" == "paused_manual" ]] && { log "[$name] $id manual hold"; continue; }
    if [[ "$old_status" == "rate_limited" || "$old_status" == "paused_rate_limit" ]]; then
      [[ "$tmux_alive" == "false" ]] && { log "[$name] $id rate-limit hold"; continue; }
    fi

    local pr_created=false branch_synced=false ci_passed=false ci_failed=false
    local codex_pass=false codex_fail=false claude_pass=false claude_fail=false gemini_pass=false gemini_fail=false screenshots_pass=false gemini_gate=true
    local checks_json='[]' pr_view='{}' pr_state='OPEN' merge_state='UNKNOWN' head_sha='' status_json='{}'

    if [[ -z "$pr" || "$pr" == "null" ]]; then
      pr=$(gh_json '' pr list --repo "$remote" --head "$branch" --json number --jq '.[0].number // empty')
    fi

    if [[ -n "$pr" ]]; then
      pr_created=true
      pr_view=$(gh_json '{}' pr view "$pr" --repo "$remote" --json state,mergeStateStatus,headRefOid)
      pr_state=$(echo "$pr_view" | jq -r '.state // "OPEN"')
      merge_state=$(echo "$pr_view" | jq -r '.mergeStateStatus // "UNKNOWN"')
      head_sha=$(echo "$pr_view" | jq -r '.headRefOid // empty')

      case "$merge_state" in CLEAN|HAS_HOOKS|UNSTABLE) branch_synced=true ;; *) branch_synced=false ;; esac

      checks_json=$(gh_json '[]' pr checks "$pr" --repo "$remote" --json name,state)
      local ci_checks
      if [[ "$review_mode" == "local" ]]; then
        ci_checks=$(echo "$checks_json" | jq '[ .[] | select((.name|ascii_downcase|test("local/codex-review|local/claude-review|local/gemini-review|local/screenshot-gate|codex review|claude review|gemini review|screenshot"))|not) ]')
      else
        ci_checks=$(echo "$checks_json" | jq '[ .[] | select((.name|ascii_downcase|test("codex review|claude review|gemini review|screenshot"))|not) ]')
      fi

      if [[ $(echo "$ci_checks" | jq 'length') -gt 0 ]]; then
        if echo "$ci_checks" | jq -e '[.[].state] | any(.[]; .=="FAILURE" or .=="ERROR" or .=="TIMED_OUT" or .=="CANCELLED" or .=="ACTION_REQUIRED")' >/dev/null; then
          ci_failed=true
        elif echo "$ci_checks" | jq -e '[.[].state] | all(.[]; .=="SUCCESS" or .=="SKIPPED" or .=="NEUTRAL")' >/dev/null; then
          ci_passed=true
        fi
      else
        ci_passed=true
      fi

      if [[ "$review_mode" == "local" && "$ci_passed" == "true" && "$pr_state" != "MERGED" && -x "$SWARM_HOME/scripts/local-review.sh" ]]; then
        "$SWARM_HOME/scripts/local-review.sh" --project "$project" --pr "$pr" --task "$id" >/dev/null 2>&1 || true
      fi

      if [[ "$review_mode" == "local" && -n "$head_sha" ]]; then
        status_json=$(gh_json '{}' api "repos/$remote/commits/$head_sha/status")
        local codex_state claude_state gemini_state shot_state
        codex_state=$(context_state_from_json "$status_json" "$codex_ctx")
        claude_state=$(context_state_from_json "$status_json" "$claude_ctx")
        gemini_state=$(context_state_from_json "$status_json" "$gemini_ctx")
        shot_state=$(context_state_from_json "$status_json" "$shot_ctx")

        [[ "$codex_state" == "success" ]] && codex_pass=true
        [[ "$claude_state" == "success" ]] && claude_pass=true
        [[ "$gemini_state" == "success" ]] && gemini_pass=true
        [[ "$shot_state" == "success" ]] && screenshots_pass=true
        [[ "$codex_state" =~ ^(failure|error)$ ]] && codex_fail=true
        [[ "$claude_state" =~ ^(failure|error)$ ]] && claude_fail=true
        [[ "$gemini_state" =~ ^(failure|error)$ ]] && gemini_fail=true
      fi

      [[ "$require_gemini" == "true" ]] && gemini_gate="$gemini_pass"

      if [[ "$pr_state" == "MERGED" ]]; then
        status="merged"
      elif [[ "$ci_failed" == "true" || "$codex_fail" == "true" || "$claude_fail" == "true" || "$gemini_fail" == "true" ]]; then
        status="ci_failed"
      elif [[ "$pr_created" == "true" && "$branch_synced" == "true" && "$ci_passed" == "true" && "$codex_pass" == "true" && "$claude_pass" == "true" && "$gemini_gate" == "true" && "$screenshots_pass" == "true" ]]; then
        status="review_ready"
      else
        status="pr_open"
      fi
    else
      if [[ "$tmux_alive" == "true" ]]; then
        local pane_content started_at stale=false started_epoch now_epoch elapsed
        pane_content=$(tmux capture-pane -t "$session" -p 2>/dev/null | tr -d '[:space:]')
        started_at=$(echo "$task" | jq -r '.startedAt // empty')
        if [[ -z "$pane_content" && -n "$started_at" ]]; then
          started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" "+%s" 2>/dev/null || date -d "$started_at" "+%s" 2>/dev/null || echo 0)
          now_epoch=$(date +%s)
          elapsed=$(( now_epoch - started_epoch ))
          [[ $elapsed -gt 1800 ]] && stale=true
        fi
        [[ "$stale" == "true" ]] && status="failed" || status="running"
      else
        status="failed"
      fi
    fi

    if [[ "$status" == "ci_failed" ]]; then
      local failed_check_names review_comments inline_comments original_task learned_hints respawn_prompt
      failed_check_names=$(echo "$checks_json" | jq -r '[.[] | select(.state=="FAILURE" or .state=="ERROR") | .name] | join(", ")')
      review_comments=$(gh_json '' pr view "$pr" --repo "$remote" --json comments --jq '[.comments[].body] | join("\n---\n")' | single_line || true)
      inline_comments=$(gh_json '' api "repos/$remote/pulls/$pr/comments" --jq '[.[].body] | join("\n---\n")' | single_line || true)
      review_comments="${review_comments:0:700}"
      inline_comments="${inline_comments:0:700}"

      local prompt_file="$SWARM_HOME/.prompts/$project/$id.txt"
      original_task=""
      [[ -f "$prompt_file" ]] && original_task=$(tr '\n' ' ' < "$prompt_file" | sed -E 's/ +/ /g' | cut -c1-700)

      learned_hints=""
      if [[ -f "$SWARM_HOME/patterns.log" ]]; then
        learned_hints=$( { grep -E "SUCCESS: .*agent=${agent}" "$SWARM_HOME/patterns.log" 2>/dev/null || true; grep -Ei "${id//-/|}" "$SWARM_HOME/patterns.log" 2>/dev/null || true; } | awk '!seen[$0]++' | tail -n 8 | single_line )
      fi

      if (( attempts < maxA )); then
        log "[$name] $id ci_failed -> respawn ($((attempts+1))/$maxA)"
        printf '[%s] AGENT FAIL: %s (attempt %s/%s) Branch: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$((attempts+1))" "$maxA" "$branch" >> "$PENDING_FILE"
        [[ -n "$pr" ]] && printf '[%s] PR: #%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" >> "$PENDING_FILE"
        [[ -n "$failed_check_names" ]] && printf '[%s] Failed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$failed_check_names" >> "$PENDING_FILE"

        respawn_prompt="Fix the following issues from PR #${pr}."
        [[ -n "$review_comments" ]] && respawn_prompt+="\n\nREVIEW COMMENTS:\n${review_comments}"
        [[ -n "$inline_comments" ]] && respawn_prompt+="\n\nINLINE COMMENTS:\n${inline_comments}"
        [[ -n "$failed_check_names" ]] && respawn_prompt+="\n\nFAILED CHECKS: ${failed_check_names}"
        [[ -n "$original_task" ]] && respawn_prompt+="\n\nORIGINAL TASK:\n${original_task}"
        [[ -n "$learned_hints" ]] && respawn_prompt+="\n\nLEARNED PATTERNS:\n${learned_hints}"
        respawn_prompt+="\n\nKeep changes scoped. Address only the listed issues."

        if "$SWARM_HOME/scripts/respawn-agent.sh" --project "$project" "$id" "$(printf '%b' "$respawn_prompt")" >/dev/null 2>&1; then
          status="running"
          attempts=$((attempts + 1))
        fi
      else
        local recovery_key recovery_file
        recovery_key="pr${pr}-$(printf '%s' "$failed_check_names" | shasum -a 256 | awk '{print substr($1,1,12)}')"
        recovery_file="$RECOVERY_DIR/${project}.${id}.stamp"

        if [[ "$AUTO_EXHAUSTED_RECOVERY" == "true" ]]; then
          local last_key=""
          [[ -f "$recovery_file" ]] && last_key=$(cat "$recovery_file" 2>/dev/null || true)
          if [[ "$last_key" != "$recovery_key" ]]; then
            printf '%s' "$recovery_key" > "$recovery_file"
            respawn_prompt="EXHAUSTED auto-recovery for PR #${pr}. Solve FAILED CHECKS: ${failed_check_names}. Keep scope minimal."
            if "$SWARM_HOME/scripts/respawn-agent.sh" --project "$project" --preserve-attempts "$id" "$(printf '%b' "$respawn_prompt")" >/dev/null 2>&1; then
              status="running"
              notify "[$name] AUTO-RECOVERY $id after EXHAUSTED (PR #$pr)"
            else
              status="failed"
              printf '[%s] AGENT EXHAUSTED: %s all %s attempts used. Manual intervention needed.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$maxA" >> "$PENDING_FILE"
            fi
          else
            status="failed"
            printf '[%s] AGENT EXHAUSTED: %s all %s attempts used. Manual intervention needed.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$maxA" >> "$PENDING_FILE"
          fi
        else
          status="failed"
          printf '[%s] AGENT EXHAUSTED: %s all %s attempts used. Manual intervention needed.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$maxA" >> "$PENDING_FILE"
        fi
      fi
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    task=$(echo "$task" | jq \
      --arg status "$status" \
      --argjson pr "${pr:-null}" \
      --arg now "$now" \
      --argjson attempts "$attempts" \
      --argjson prCreated "$pr_created" \
      --argjson branchSynced "$branch_synced" \
      --argjson ciPassed "$ci_passed" \
      --argjson codexReviewPassed "$codex_pass" \
      --argjson claudeReviewPassed "$claude_pass" \
      --argjson geminiReviewPassed "$gemini_pass" \
      --argjson screenshotsPassed "$screenshots_pass" \
      '.status=$status
       | .pr=$pr
       | .attempts=$attempts
       | .checks.prCreated=$prCreated
       | .checks.branchSynced=$branchSynced
       | .checks.ciPassed=$ciPassed
       | .checks.codexReviewPassed=$codexReviewPassed
       | .checks.claudeReviewPassed=$claudeReviewPassed
       | .checks.geminiReviewPassed=$geminiReviewPassed
       | .checks.screenshotsPassed=$screenshotsPassed
       | (if $status=="merged" then .completedAt=$now else . end)')

    jq --arg id "$id" --argjson task "$task" 'map(if .id==$id then $task else . end)' "$tasks_file" > "${tasks_file}.tmp"
    mv "${tasks_file}.tmp" "$tasks_file"

    if [[ "$old_status" != "$status" ]]; then
      case "$status" in
        review_ready) notify "[$name] Task $id PR #$pr ready for review" ;;
        failed) notify "[$name] Task $id needs attention (failed)" ;;
        merged) notify "[$name] Task $id PR #$pr merged" ;;
      esac
    fi

    log "[$name] $id status=$status tmux=$tmux_alive pr=${pr:-none}"
  done
}

if [[ "$ALL" == "true" ]]; then
  for cfg in "$SWARM_HOME"/projects/*.json; do
    [[ -f "$cfg" ]] || continue
    process_project "$(basename "$cfg" .json)"
  done
else
  process_project "$PROJECT"
fi
