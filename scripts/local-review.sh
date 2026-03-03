#!/usr/bin/env bash
set -euo pipefail
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

SWARM_HOME="${SWARM_HOME:-${HOME}/.agent-swarm}"
PENDING_FILE="$SWARM_HOME/notifications.pending"

usage() {
  cat <<EOT
Usage: local-review.sh --project <name> --pr <number> [--task <id>] [--force]

Runs local Codex + Claude PR review and sets commit statuses:
- local/codex-review
- local/claude-review
- local/gemini-review
- local/screenshot-gate
EOT
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

PROJECT=""
PR=""
TASK_ID=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --task) TASK_ID="${2:-}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --help|-h) usage 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$PROJECT" && -n "$PR" ]] || usage 1

need jq
need gh
need codex

CONFIG_FILE="$SWARM_HOME/projects/${PROJECT}.json"
[[ -f "$CONFIG_FILE" ]] || die "Missing config: $CONFIG_FILE"

REMOTE=$(jq -r '.remote' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.logDir' "$CONFIG_FILE")
REQUIRE_GEMINI=$(jq -r '.requireGemini // false' "$CONFIG_FILE")
CODEX_CTX=$(jq -r '.reviewContexts.codex // "local/codex-review"' "$CONFIG_FILE")
CLAUDE_CTX=$(jq -r '.reviewContexts.claude // "local/claude-review"' "$CONFIG_FILE")
GEMINI_CTX=$(jq -r '.reviewContexts.gemini // "local/gemini-review"' "$CONFIG_FILE")
SHOT_CTX=$(jq -r '.reviewContexts.screenshot // "local/screenshot-gate"' "$CONFIG_FILE")

mkdir -p "$LOG_DIR/reviews"
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
PREFIX="$LOG_DIR/reviews/pr-${PR}-${STAMP}"

HEAD_SHA=$(gh pr view "$PR" --repo "$REMOTE" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
[[ -n "$HEAD_SHA" && "$HEAD_SHA" != "null" ]] || die "Cannot resolve PR head SHA for #$PR"

status_json="{}"
refresh_status() {
  status_json=$(gh api "repos/$REMOTE/commits/$HEAD_SHA/status" 2>/dev/null || echo '{}')
}

context_state() {
  local ctx="$1"
  echo "$status_json" | jq -r --arg c "$ctx" '[.statuses[]? | select(.context==$c)][0].state // "missing"'
}

set_status() {
  local ctx="$1"
  local state="$2"
  local desc="$3"
  gh api -X POST "repos/$REMOTE/statuses/$HEAD_SHA" \
    -f state="$state" \
    -f context="$ctx" \
    -f description="$desc" >/dev/null
}

post_comment() {
  local title="$1"
  local body_file="$2"
  local tmp
  tmp=$(mktemp)
  {
    echo "## ${title}"
    echo
    echo '```text'
    head -c 7000 "$body_file"
    echo
    echo '```'
  } > "$tmp"
  gh pr comment "$PR" --repo "$REMOTE" --body-file "$tmp" >/dev/null || true
  rm -f "$tmp"
}

run_reviewer() {
  local name="$1"
  local ctx="$2"
  local cmd="$3"
  local out_file="$4"
  local current

  refresh_status
  current=$(context_state "$ctx")
  if [[ "$FORCE" == "false" && "$current" != "missing" && "$current" != "pending" ]]; then
    return 0
  fi

  set_status "$ctx" pending "$name review in progress"

  # shellcheck disable=SC2086
  bash -lc "$cmd" >"$out_file" 2>&1 || true

  if grep -Eqi '^VERDICT:[[:space:]]*PASS' "$out_file"; then
    set_status "$ctx" success "$name review passed"
  else
    set_status "$ctx" failure "$name review failed"
    mkdir -p "$SWARM_HOME"; touch "$PENDING_FILE"
    printf '[%s] NOTIFY: [%s] PR #%s %s review FAILED (%s)
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROJECT" "$PR" "$name" "$ctx" >> "$PENDING_FILE"
  fi

  post_comment "$name Local Review" "$out_file"
}

PR_BODY=$(gh pr view "$PR" --repo "$REMOTE" --json body --jq '.body // ""' 2>/dev/null || echo "")
DIFF=$(gh pr diff "$PR" --repo "$REMOTE" 2>/dev/null | awk 'BEGIN{skip=0} /^diff --git.*((\.lock$)|lock\.json|lock\.yaml|Test\.java$|Spec\.java$|\.test\.[tj]sx?|\.spec\.[tj]sx?|__tests__)/{skip=1; next} /^diff --git/{skip=0} !skip{print}' | head -c 60000 || true)
FILES_CHANGED=$(gh pr view "$PR" --repo "$REMOTE" --json files --jq '[.files[].path] | join(", ")' 2>/dev/null || true)
DIFF_HEADER="Files changed: ${FILES_CHANGED}

"
DIFF="${DIFF_HEADER}${DIFF}"
printf '%s\n' "$DIFF" > "${PREFIX}.diff.txt"

# Screenshot gate
refresh_status
shot_state=$(context_state "$SHOT_CTX")
if [[ "$FORCE" == "true" || "$shot_state" == "missing" || "$shot_state" == "pending" ]]; then
  UI_CHANGED=false
  FILES=$(gh api "repos/$REMOTE/pulls/$PR/files" --paginate --jq '.[].filename' 2>/dev/null || true)
  for f in $FILES; do
    case "$f" in
      *.tsx|*.jsx|*.css|*.scss|*.sass|*.html|*.vue|*.svelte)
        UI_CHANGED=true
        break
        ;;
    esac
  done

  if [[ "$UI_CHANGED" == "false" ]]; then
    set_status "$SHOT_CTX" success "No UI changes"
  elif [[ -n "$TASK_ID" && "$TASK_ID" =~ (init|setup|config|deps|infra) ]]; then
    set_status "$SHOT_CTX" success "Infra/setup task — screenshot skipped"
  else
    if echo "$PR_BODY" | grep -qiE '!\[[^]]*\]\([^)]*\)|<img\s+[^>]*src=|https?://[^ ]+\.(png|jpg|jpeg|gif|webp)'; then
      set_status "$SHOT_CTX" success "Screenshot found in PR description"
    else
      set_status "$SHOT_CTX" failure "UI changes require screenshot in PR description"
      printf '%s\n' 'VERDICT: FAIL
UI files changed but no screenshot in PR body.' > "${PREFIX}.screenshot.txt"
      post_comment "Screenshot Gate" "${PREFIX}.screenshot.txt"
    fi
  fi
fi

CODEX_PROMPT=$(cat <<EOT
You are a strict PR reviewer.
Analyze the diff and output plain text with first line exactly:
VERDICT: PASS
or
VERDICT: FAIL
Then list only real bugs/security issues/regressions. No style nitpicks.

PR DIFF:
$DIFF
EOT
)

CODEX_PROMPT_FILE="${PREFIX}.codex.prompt.txt"
printf '%s\n' "$CODEX_PROMPT" > "$CODEX_PROMPT_FILE"

CODEX_CMD="codex exec --model gpt-5.3-codex -c \"model_reasoning_effort=medium\" --dangerously-bypass-approvals-and-sandbox - < '$CODEX_PROMPT_FILE'"

run_reviewer "Codex" "$CODEX_CTX" "$CODEX_CMD" "${PREFIX}.codex.txt"

# Claude review — CRITICAL-ONLY mode (reduced diff, strict prompt)
# Claude gets same diff as Codex (full)

CLAUDE_PROMPT=$(cat <<EOT
You are a security and correctness reviewer. ONLY report issues that will:
- Crash in production
- Cause data loss or corruption
- Create a security vulnerability
- Break existing functionality (regressions)

If you find ZERO critical issues, output:
VERDICT: PASS

If you find critical issues, output:
VERDICT: FAIL
Then list ONLY the critical issues. No suggestions, no style, no "consider adding".

PR DIFF:
$DIFF
EOT
)

CLAUDE_PROMPT_FILE="${PREFIX}.claude.prompt.txt"
printf '%s\n' "$CLAUDE_PROMPT" > "$CLAUDE_PROMPT_FILE"

CLAUDE_CMD="claude --model claude-sonnet-4-6 --dangerously-skip-permissions -p \"\$(cat '$CLAUDE_PROMPT_FILE')\""

run_reviewer "Claude" "$CLAUDE_CTX" "$CLAUDE_CMD" "${PREFIX}.claude.txt"

# Gemini Code Assist (GitHub App) — check if it reviewed the PR
refresh_status
gemini_current=$(context_state "$GEMINI_CTX")
if [[ "$FORCE" == "true" || "$gemini_current" == "missing" || "$gemini_current" == "pending" ]]; then
  # Check for Gemini Code Assist review on the PR
  # Bot login: gemini-code-assist[bot]
  GEMINI_REVIEW=$(gh api "repos/$REMOTE/pulls/$PR/reviews" 2>/dev/null | jq -r '
    [.[] | select(.user.login | test("gemini-code-assist"; "i"))] | last |
    if . == null then "none"
    elif .state == "APPROVED" then "approved"
    elif .state == "CHANGES_REQUESTED" then "changes_requested"
    elif .state == "COMMENTED" then "commented"
    else "none"
    end' 2>/dev/null || echo "none")

  # Also check PR comments (Gemini sometimes posts as comment, not formal review)
  if [[ "$GEMINI_REVIEW" == "none" ]]; then
    GEMINI_COMMENTED=$(gh api "repos/$REMOTE/issues/$PR/comments" 2>/dev/null | jq -r '
      [.[] | select(.user.login | test("gemini-code-assist"; "i"))] | length' 2>/dev/null || echo "0")
    if [[ "$GEMINI_COMMENTED" -gt 0 ]]; then
      GEMINI_REVIEW="commented"
    fi
  fi

  case "$GEMINI_REVIEW" in
    approved|commented)
      set_status "$GEMINI_CTX" success "Gemini Code Assist reviewed"
      ;;
    changes_requested)
      set_status "$GEMINI_CTX" failure "Gemini Code Assist requested changes"
      ;;
    none)
      set_status "$GEMINI_CTX" pending "Waiting for Gemini Code Assist review"
      ;;
  esac
fi

echo "Local review completed for PR #$PR"
