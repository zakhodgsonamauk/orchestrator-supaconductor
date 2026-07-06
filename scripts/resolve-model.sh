#!/usr/bin/env bash
# Resolve the model for a SupaConductor command. jq-free (sed-based).
# Usage: resolve-model.sh <command-name>
# Prints a model id (opus|sonnet|haiku|fable|claude-*) or "inherit".
# Reads ./conductor/config.json and ./conductor/.session-models.json relative to cwd.
set -u

CMD="${1:-}"
CONFIG="conductor/config.json"
OVERLAY="conductor/.session-models.json"

# --- Command -> role map ---
role_for() {
  case "$1" in
    writing-plans|write-plan|brainstorming|brainstorm|loop-planner|loop-plan-evaluator|\
    evaluate-plan|new-track|conductor-new-track|plan-sprint|board-meeting|board-review|\
    ceo|cto|cto-advisor|cmo|ux-designer|phase-review|setup|conductor-setup)
      echo planning ;;
    executing-plans|execute-plan|loop-executor|loop-execution-evaluator|evaluate-execution|\
    loop-fixer|systematic-debugging|task-worker|parallel-dispatcher|ui-audit|close-track|\
    finishing-a-development-branch|using-git-worktrees|conductor-implement|implement|go|\
    conductor-status|status)
      echo execution ;;
    *) echo "" ;;
  esac
}

# json_val <file> <key> — first "key": "value" match on a single line. jq-free.
# Key is regex-escaped for the '.' and '-' that appear in command names.
json_val() {
  [ -f "$1" ] || return 0
  local key; key="$(printf '%s' "$2" | sed 's/[.[\*^$/]/\\&/g')"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

emit() { echo "$1"; exit 0; }

ROLE="$(role_for "$CMD")"
[ -z "$ROLE" ] && emit inherit   # unknown command

# 3. role default: config.models.<role>, then legacy <role>_model
rd="$(json_val "$CONFIG" "$ROLE")"
[ -z "$rd" ] && rd="$(json_val "$CONFIG" "${ROLE}_model")"
[ -n "$rd" ] && emit "$rd"

emit inherit
