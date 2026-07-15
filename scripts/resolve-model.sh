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

# json_bool <file> <key> — exit 0 if "key": true (unquoted JSON boolean)
json_bool() {
  [ -f "$1" ] || return 1
  grep -Eq "\"$2\"[[:space:]]*:[[:space:]]*true([[:space:],}]|\$)" "$1"
}

valid_token() {
  case "$1" in
    inherit|opus|sonnet|haiku|fable) return 0 ;;
    claude-opus-4-8|claude-sonnet-5|claude-haiku-4-5-20251001|claude-fable-5) return 0 ;;
    *) return 1 ;;
  esac
}
emit() {
  if valid_token "$1"; then echo "$1"; exit 0
  else echo "resolve-model: invalid model token '$1', using inherit" >&2; echo inherit; exit 0; fi
}

ROLE="$(role_for "$CMD")"
[ -z "$ROLE" ] && emit inherit   # unknown command

# 0. force_session_model escape hatch (known non-Anthropic backends, e.g. Ollama)
json_bool "$CONFIG" force_session_model && emit inherit

# 1. per-command pin (config.models.overrides.<command>)
pin="$(json_val "$CONFIG" "$CMD")"
[ -n "$pin" ] && emit "$pin"

# 2. session overlay (conductor/.session-models.json)
ov="$(json_val "$OVERLAY" "$ROLE")"
[ -n "$ov" ] && emit "$ov"

# 3. role default: config.models.<role>, then legacy <role>_model
rd="$(json_val "$CONFIG" "$ROLE")"
[ -z "$rd" ] && rd="$(json_val "$CONFIG" "${ROLE}_model")"
[ -n "$rd" ] && emit "$rd"

emit inherit
