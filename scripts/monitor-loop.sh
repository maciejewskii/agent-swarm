#!/usr/bin/env bash
# Cron-safe monitor loop.
# - Runs check-agents
# - Prints ONLY NOTIFY lines to stdout
# - Logs full output to monitor.log
# - Always exits 0

set -euo pipefail

SWARM_HOME="${SWARM_HOME:-${HOME}/.agent-swarm}"

usage() {
  cat <<EOF
Usage: monitor-loop.sh [--project <name>]

Without --project, runs across all projects.
EOF
  exit 0
}

PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --help|-h) usage ;;
    *) shift ;;
  esac
done

LOG_FILE="$SWARM_HOME/monitor.log"
mkdir -p "$(dirname "$LOG_FILE")"

if [[ -n "$PROJECT" ]]; then
  OUT=$("$SWARM_HOME/scripts/check-agents.sh" --project "$PROJECT" --quiet 2>&1 || true)
else
  OUT=$("$SWARM_HOME/scripts/check-agents.sh" --all --quiet 2>&1 || true)
fi

{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] monitor-loop run"
  echo "$OUT"
} >> "$LOG_FILE"

# emit only notifications for OpenClaw routing
while IFS= read -r line; do
  [[ "$line" == NOTIFY:* ]] && echo "$line"
done <<< "$OUT"

exit 0
