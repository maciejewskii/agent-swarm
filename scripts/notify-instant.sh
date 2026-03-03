#!/usr/bin/env bash
set -euo pipefail

SWARM_HOME="${SWARM_HOME:-${HOME}/.vibe-swarm}"
PENDING_FILE="$SWARM_HOME/notifications.pending"
LOCK_DIR="$SWARM_HOME/.notify-instant.lock"
LOG_FILE="$SWARM_HOME/notify-instant.log"
CFG_FILE="${OPENCLAW_CONFIG:-}"
CHANNEL="${NOTIFY_CHANNEL:-telegram}"
TARGET="${NOTIFY_TARGET:-}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-1800}"
SENT_CACHE="$SWARM_HOME/.notify-sent.cache"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$SWARM_HOME"
touch "$PENDING_FILE" "$LOG_FILE"
touch "$SENT_CACHE"

is_noise_line() {
  local s="$1"
  [[ -n "${s//[[:space:]]/}" ]] || return 0

  # markdown/code-review noise from multiline GitHub comments
  [[ "$s" == '```'* ]] && return 0
  [[ "$s" =~ ^[[:space:]]*[+-]{1,2}[[:space:]] ]] && return 0
  [[ "$s" =~ ^[[:space:]]*\!\[ ]] && return 0
  [[ "$s" =~ ^[[:space:]]*#{1,6}[[:space:]] ]] && return 0

  return 1
}



is_fresh_line() {
  local raw="$1"
  # expected prefix: [2026-03-02T23:40:39Z]
  if [[ "$raw" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z)\] ]]; then
    local ts="${BASH_REMATCH[1]}"
    local now epoch
    now=$(date -u +%s)
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || date -u -d "$ts" +%s 2>/dev/null || echo "$now")
    (( now - epoch <= MAX_AGE_SECONDS )) && return 0 || return 1
  fi
  return 0
}

normalize_msg() {
  local s="$1"
  # flatten multiline leftovers, keep it short for Telegram
  s=$(printf '%s' "$s" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')
  printf '%.700s' "$s"
}

# lock to avoid overlapping WatchPaths triggers
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
cleanup() { rmdir "$LOCK_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# nothing to do
if [[ ! -s "$PENDING_FILE" ]]; then
  exit 0
fi

# resolve gateway auth from config (no hardcoded secrets)
if [[ ! -f "$CFG_FILE" ]]; then
  printf '[%s] config missing: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CFG_FILE" >> "$LOG_FILE"
  exit 1
fi

URL=$(jq -r '.gateway.remote.url // empty' "$CFG_FILE")
TOKEN=$(jq -r '.gateway.remote.token // .gateway.auth.token // empty' "$CFG_FILE")
if [[ -z "$URL" || -z "$TOKEN" ]]; then
  printf '[%s] gateway url/token missing in config\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_FILE"
  exit 1
fi

TMP_FILE=$(mktemp)
cp "$PENDING_FILE" "$TMP_FILE"
: > "$PENDING_FILE"

idx=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw//$'\r'/}"
  [[ -n "${line//[[:space:]]/}" ]] || continue
  is_fresh_line "$line" || continue

  # Normalize monitor line: [ts] NOTIFY: message
  msg="$line"
  msg=$(printf '%s' "$msg" | sed -E 's/^\[[^]]+\][[:space:]]+NOTIFY:[[:space:]]*//')
  msg=$(printf '%s' "$msg" | sed -E 's/^NOTIFY:[[:space:]]*//')
  msg=$(normalize_msg "$msg")

  is_noise_line "$msg" && continue
  [[ -n "${msg//[[:space:]]/}" ]] || continue

  idx=$((idx+1))
  hash=$(printf '%s' "$msg" | shasum -a 256 | awk '{print $1}')
  if grep -Fqx "$hash" "$SENT_CACHE"; then
    continue
  fi
  key="swarm-${idx}-$(date +%s)-$hash"

  params=$(jq -cn --arg k "$key" --arg c "$CHANNEL" --arg t "$TARGET" --arg m "$msg" '{idempotencyKey:$k,channel:$c,to:$t,message:$m}')

  if openclaw gateway call send --url "$URL" --token "$TOKEN" --params "$params" --json >/dev/null 2>&1; then
    printf '[%s] sent: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$LOG_FILE"
    printf '%s\n' "$hash" >> "$SENT_CACHE"
  else
    printf '[%s] send failed, requeued: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$LOG_FILE"
    printf '%s\n' "$line" >> "$PENDING_FILE"
  fi
done < "$TMP_FILE"

rm -f "$TMP_FILE"
