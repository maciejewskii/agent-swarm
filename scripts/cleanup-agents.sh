#!/usr/bin/env bash
set -euo pipefail

SWARM_HOME="${SWARM_HOME:-${HOME}/.vibe-swarm}"

usage() {
  cat <<EOT
Usage: cleanup-agents.sh [--project <name> | --all] [--dry-run]

Options:
  --project <name>   Clean one project
  --all              Clean all projects
  --dry-run          Print actions only
  --help, -h         Show help

Daily cleanup (Elvis-style):
- remove merged tasks (worktree + branch + task entry)
- prune orphaned worktrees not present in registry
EOT
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

PROJECT=""
ALL=false
DRY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --all) ALL=true; shift ;;
    --dry-run) DRY=true; shift ;;
    --help|-h) usage 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

need jq
need git
need tmux
[[ "$ALL" == "true" || -n "$PROJECT" ]] || usage 1

cleanup_project() {
  local project="$1"
  local cfg="$SWARM_HOME/projects/${project}.json"
  [[ -f "$cfg" ]] || return 0

  local name repo worktree_base tasks_file
  name=$(jq -r '.name' "$cfg")
  repo=$(jq -r '.repo' "$cfg")
  worktree_base=$(jq -r '.worktreeBase' "$cfg")
  tasks_file=$(jq -r '.tasksFile' "$cfg")

  [[ -f "$tasks_file" ]] || return 0
  cd "$repo"

  merged_ids=$(jq -r '.[] | select(.status=="merged") | .id' "$tasks_file")
  for id in $merged_ids; do
    [ -n "$id" ] || continue
    branch=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .branch' "$tasks_file")
    wt="$worktree_base/$id"
    sess="agent-${project}-${id}"

    echo "[$name] cleanup merged task: $id"
    if [[ "$DRY" == "false" ]]; then
      tmux kill-session -t "$sess" >/dev/null 2>&1 || true
      if [[ -d "$wt" ]]; then
        git worktree remove "$wt" --force >/dev/null 2>&1 || rm -rf "$wt"
      fi
      git branch -D "$branch" >/dev/null 2>&1 || true
      git push origin --delete "$branch" >/dev/null 2>&1 || true
      rm -f "$SWARM_HOME/.prompts/$project/$id.txt"
      jq --arg id "$id" 'map(select(.id != $id))' "$tasks_file" > "${tasks_file}.tmp"
      mv "${tasks_file}.tmp" "$tasks_file"
    fi
  done

  tracked_dirs=$(jq -r '.[].worktree // empty' "$tasks_file")
  shopt -s nullglob
  for d in "$worktree_base"/*; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" == "logs" ]] && continue
    [[ "$(basename "$d")" == .* ]] && continue

    tracked=false
    for t in $tracked_dirs; do
      [[ "$d" == "$t" ]] && tracked=true && break
    done

    if [[ "$tracked" == "false" ]]; then
      echo "[$name] orphan worktree: $d"
      if [[ "$DRY" == "false" ]]; then
        git worktree remove "$d" --force >/dev/null 2>&1 || rm -rf "$d"
      fi
    fi
  done
  shopt -u nullglob

  [[ "$DRY" == "false" ]] && git worktree prune >/dev/null 2>&1 || true
}

if [[ "$ALL" == "true" ]]; then
  for cfg in "$SWARM_HOME"/projects/*.json; do
    [[ -f "$cfg" ]] || continue
    cleanup_project "$(basename "$cfg" .json)"
  done
else
  cleanup_project "$PROJECT"
fi

echo "cleanup done"
