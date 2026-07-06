#!/usr/bin/env bash
# Plain-bash test harness for resolve-model.sh. Zero external deps.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$HERE/resolve-model.sh"
PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run resolver against a scratch project dir ($1=cwd, $2=command)
run() { ( cd "$1" && bash "$RESOLVE" "$2" ); }

assert_eq() { # $1=desc $2=expected $3=actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok  - $1";
  else FAIL=$((FAIL+1)); echo "NOT OK - $1 (expected '$2', got '$3')"; fi
}

# --- Fixture: role defaults only ---
proj="$TMP/p1"; mkdir -p "$proj/conductor"
cat > "$proj/conductor/config.json" <<'JSON'
{ "models": { "planning": "opus", "execution": "sonnet" } }
JSON

assert_eq "planning cmd -> planning role default" "opus"   "$(run "$proj" writing-plans)"
assert_eq "execution cmd -> execution role default" "sonnet" "$(run "$proj" loop-executor)"
assert_eq "unknown command -> inherit" "inherit" "$(run "$proj" totally-unknown-cmd)"

# --- Fixture: legacy flat keys (back-compat) ---
projL="$TMP/pL"; mkdir -p "$projL/conductor"
cat > "$projL/conductor/config.json" <<'JSON'
{ "planning_model": "opus", "execution_model": "sonnet" }
JSON
assert_eq "legacy planning_model back-compat" "opus"   "$(run "$projL" writing-plans)"
assert_eq "legacy execution_model back-compat" "sonnet" "$(run "$projL" loop-executor)"

# --- Fixture: no config at all -> inherit ---
projN="$TMP/pN"; mkdir -p "$projN/conductor"
assert_eq "no config -> inherit" "inherit" "$(run "$projN" writing-plans)"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
