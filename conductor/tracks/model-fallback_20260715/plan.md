# Model-Availability Fallback + Config Commands Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use orchestrator-supaconductor:executing-plans to implement this plan task-by-task.

**Goal:** Keep opus/sonnet as configurable defaults but fall back to the running session model (`inherit`) when the configured Claude model can't be selected (e.g. Ollama backend); change defaults to planning=inherit/execution=sonnet; add persistent config subcommands to `/use-models` plus a `/use-models-help` card.

**Architecture:** Extend `scripts/resolve-model.sh` with (a) a `force_session_model` short-circuit and (b) an `available()` probe that runs `claude --print --model M "ok"` once per model per run, cached in `$CONDUCTOR_PROBE_CACHE`, and returns `inherit` when the model can't be selected. A hermetic test hook (`$CONDUCTOR_PROBE_RESULT`) avoids real `claude` calls in tests. `/use-models` gains persistent subcommands; a new `/use-models-help` prints a reference card.

**Tech Stack:** Bash (Git Bash on Windows), jq-free `sed`/`grep` parsing, Markdown command definitions. Hermetic plain-bash test harness.

**Design reference:** `conductor/designs/2026-07-15-model-fallback-design.md`

---

## Current resolver shape (for reference)
```
role_for(); json_val(); valid_token(); emit()
ROLE=role_for(CMD); [ -z ROLE ] && emit inherit
pin=json_val(CONFIG,CMD);        [ -n pin ] && emit pin
ov=json_val(OVERLAY,ROLE);       [ -n ov ]  && emit ov
rd=json_val(CONFIG,ROLE) || json_val(CONFIG,ROLE_model); [ -n rd ] && emit rd
emit inherit
```
The probe is added INSIDE `emit` (so every resolved non-inherit candidate is checked); the force flag is added right after the `ROLE` line.

---

## Phase 1: Resolver — probe + force flag (TDD)

### Task 1: Make existing tests hermetic + add `force_session_model`

**Status:** [ ]

**Files:** Modify `scripts/resolve-model.sh`, `scripts/test-resolve-model.sh`

**Step 1: Update test harness for hermeticity + add failing force test.**
At the TOP of `scripts/test-resolve-model.sh` (after `set -u`), add so no test hits real `claude`:
```bash
export CONDUCTOR_PROBE_RESULT=available   # hermetic default; individual tests override
```
Append a new fixture:
```bash
# --- Fixture: force_session_model short-circuits everything ---
projF="$TMP/pF"; mkdir -p "$projF/conductor"
cat > "$projF/conductor/config.json" <<'JSON'
{ "models": { "planning": "opus", "execution": "sonnet", "force_session_model": true } }
JSON
assert_eq "force flag -> inherit (planning)" "inherit" "$(run "$projF" writing-plans)"
assert_eq "force flag -> inherit (execution)" "inherit" "$(run "$projF" loop-executor)"
```

**Step 2: Run** `bash scripts/test-resolve-model.sh` → FAIL (force ignored → opus/sonnet).

**Step 3: Implement.** Add a bool reader after `json_val`:
```bash
# json_bool <file> <key> — exit 0 if "key": true (unquoted JSON boolean)
json_bool() {
  [ -f "$1" ] || return 1
  grep -Eq "\"$2\"[[:space:]]*:[[:space:]]*true([[:space:],}]|$)" "$1"
}
```
Insert the short-circuit right after `[ -z "$ROLE" ] && emit inherit`:
```bash
# 1. force_session_model escape hatch (known non-Anthropic backends)
json_bool "$CONFIG" force_session_model && emit inherit
```

**Step 4: Run** → PASS (all prior tests still green + 2 new).

**Step 5: Commit**
```bash
git add scripts/resolve-model.sh scripts/test-resolve-model.sh
git commit -m "feat(models): force_session_model flag + hermetic test default"
```

---

### Task 2: `available()` probe + per-run cache

**Status:** [ ]

**Files:** Modify `scripts/resolve-model.sh`, `scripts/test-resolve-model.sh`

**Step 1: Add failing tests.**
```bash
# --- Fixture: probe says unavailable -> inherit ---
projU="$TMP/pU"; mkdir -p "$projU/conductor"
cat > "$projU/conductor/config.json" <<'JSON'
{ "models": { "planning": "inherit", "execution": "sonnet" } }
JSON
# FIX-1: isolate cache per call so results don't leak between probe tests
assert_eq "probe unavailable -> inherit" "inherit" \
  "$( cd "$projU" && CONDUCTOR_PROBE_CACHE="$(mktemp -u)" CONDUCTOR_PROBE_RESULT=unavailable bash "$RESOLVE" loop-executor )"
assert_eq "probe available -> sonnet" "sonnet" \
  "$( cd "$projU" && CONDUCTOR_PROBE_CACHE="$(mktemp -u)" CONDUCTOR_PROBE_RESULT=available bash "$RESOLVE" loop-executor )"
assert_eq "inherit role skips probe" "inherit" \
  "$( cd "$projU" && CONDUCTOR_PROBE_CACHE="$(mktemp -u)" CONDUCTOR_PROBE_RESULT=unavailable bash "$RESOLVE" writing-plans )"

# --- Fixture: seeded per-run cache wins over probe hook ---
seed="$TMP/probe-cache.txt"; printf 'sonnet=0\n' > "$seed"
assert_eq "seeded cache unavailable -> inherit (no probe)" "inherit" \
  "$( cd "$projU" && CONDUCTOR_PROBE_CACHE="$seed" CONDUCTOR_PROBE_RESULT=available bash "$RESOLVE" loop-executor )"
```

**Step 2: Run** → FAIL (no probe yet; `emit sonnet` returns sonnet even when unavailable).

**Step 3: Implement.** Add `available()` before `emit`:
```bash
# available <model> — can this model actually be selected? Probe once, cache per run.
available() {
  local m="$1"
  local cache="${CONDUCTOR_PROBE_CACHE:-conductor/.model-availability.json}"
  if [ -f "$cache" ]; then
    case "$(sed -n "s/^${m}=//p" "$cache" | head -1)" in
      1) return 0 ;;
      0) return 1 ;;
    esac
  fi
  local ok=1
  if [ -n "${CONDUCTOR_PROBE_RESULT:-}" ]; then
    [ "$CONDUCTOR_PROBE_RESULT" = "available" ] && ok=0 || ok=1
  elif command -v claude >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 20 claude --print --model "$m" "ok" >/dev/null 2>&1 && ok=0 || ok=1
    else
      claude --print --model "$m" "ok" >/dev/null 2>&1 && ok=0 || ok=1
    fi
  else
    ok=1   # no claude in PATH -> cannot force a model -> inherit
  fi
  mkdir -p "$(dirname "$cache")" 2>/dev/null
  printf '%s=%s\n' "$m" "$([ "$ok" -eq 0 ] && echo 1 || echo 0)" >> "$cache" 2>/dev/null || true
  return "$ok"
}
```
Replace `emit()` so it probes any non-inherit candidate:
```bash
emit() {
  local m="$1"
  if ! valid_token "$m"; then
    echo "resolve-model: invalid model token '$m', using inherit" >&2; echo inherit; exit 0
  fi
  [ "$m" = "inherit" ] && { echo inherit; exit 0; }
  if available "$m"; then echo "$m"; exit 0
  else echo "resolve-model: model '$m' unavailable, using inherit" >&2; echo inherit; exit 0; fi
}
```

**Step 4: Run** → PASS (new tests + all prior; prior tests hermetic via `CONDUCTOR_PROBE_RESULT=available`).

**Step 5: Commit**
```bash
git add scripts/resolve-model.sh scripts/test-resolve-model.sh
git commit -m "feat(models): availability probe with per-run cache; unavailable -> inherit"
```

---

## Phase 2: New defaults

### Task 3: planning=inherit, execution=sonnet, force flag in all setup paths

**Status:** [ ]

**Files:** `scripts/setup.sh`, `commands/setup.md`, `commands/conductor-setup.md`, live `conductor/config.json`

**Step 1 (test):** define acceptance — fresh scaffold yields the new defaults:
```bash
d=$(mktemp -d); bash scripts/setup.sh "$d"
grep -q '"planning": "inherit"' "$d/conductor/config.json" && \
grep -q '"execution": "sonnet"' "$d/conductor/config.json" && \
grep -q '"force_session_model": false' "$d/conductor/config.json" && echo OK; rm -rf "$d"
```

**Step 2:** Confirm currently FAILS (old default is planning=opus, no force flag).

**Step 3:** Set the canonical block everywhere:
```json
{
  "mode": "agentic",
  "max_fix_cycles": 5,
  "models": {
    "planning": "inherit",
    "execution": "sonnet",
    "overrides": {},
    "force_session_model": false
  }
}
```
Apply to `scripts/setup.sh` heredoc, both command templates, and this project's `conductor/config.json`. Update the "Model config" note in the templates to mention `force_session_model`.

**Step 4:** Run the Step-1 check → OK. Also `bash scripts/resolve-model.sh writing-plans` (live config) → `inherit`; `... loop-executor` → probes sonnet (real claude here → sonnet on this machine).

**Step 5: Commit**
```bash
git add scripts/setup.sh commands/setup.md commands/conductor-setup.md
git commit -m "feat(models): default planning=inherit, execution=sonnet, add force flag"
```
(live `conductor/config.json` is gitignored — not committed.)

---

## Phase 3: `/use-models` persistent subcommands + help + richer show

### Task 4: Extend `commands/use-models.md`

**Status:** [ ]

**Files:** Modify `commands/use-models.md`

**Step 1:** Add to the command's "Your task" the persistent subcommands (each validates tokens against the vocabulary; reject invalid, no write; keep one override per line):
- `set-default <a>+<b>` → write `models.planning=<a>`, `models.execution=<b>` in `conductor/config.json`.
- `set-default <x>` → both roles = `<x>`.
- `pin <command>=<model>` → set `models.overrides["<command>"] = "<model>"` (create `overrides` if absent; one entry per line).
- `unpin <command>` → remove that key from `models.overrides`.
- `force on` | `force off` → set `models.force_session_model` true/false.
- `help` → print the same reference card as `/use-models-help`.

Update `show` to print: config defaults (planning/execution), overrides, `force_session_model`, session overlay contents, and the resolved model per command (via `bash scripts/resolve-model.sh <cmd>`).
Update the intro to mention the availability fallback and `force_session_model`.

**Step 2 (verify — manual, since it's an agent-instruction file):** the file must document all subcommands and state that persistent edits go to `config.json` while bare `<plan>+<exec>` stays session-only. Grep gate:
```bash
grep -q "set-default" commands/use-models.md && grep -q "force_session_model" commands/use-models.md && grep -q "unpin" commands/use-models.md && echo OK
```

**Step 3–4:** (content authoring — no code build step)

**Step 5: Commit**
```bash
git add commands/use-models.md
git commit -m "feat(models): /use-models persistent config subcommands + help + richer show"
```

---

## Phase 4: Help command

### Task 5: Create `commands/use-models-help.md`

**Status:** [ ]

**Files:** Create `commands/use-models-help.md`

**Step 1:** Frontmatter `name: use-models-help`, `model: inherit`, `user_invocable: true`, `description` = "Reference card explaining /use-models and model configuration". Body = one-shot reference:
- Session vs persistent command tables (mirror the design).
- Token vocabulary.
- Precedence: force-flag → command-pin → session-overlay → role-default → inherit, then availability-probe.
- Ollama/fallback behavior + `force_session_model`.
- Interactive-vs-orchestrated note.
Instruction: "Print this reference. One-shot; do not enter any mode."

**Step 2 (verify):**
```bash
grep -q "Precedence" commands/use-models-help.md && grep -q "force_session_model" commands/use-models-help.md && echo OK
```

**Step 5: Commit**
```bash
git add commands/use-models-help.md
git commit -m "feat(models): add /use-models-help reference command"
```

---

## Phase 5: Orchestrator per-run probe cache

### Task 6: Export `CONDUCTOR_PROBE_CACHE` at loop start

**Status:** [ ]

**Files:** Modify `agents/conductor-orchestrator.md`

**Step 1 (test = grep gate):** after edit, the orchestrator sets a fresh cache path once:
```bash
grep -q 'CONDUCTOR_PROBE_CACHE' agents/conductor-orchestrator.md && echo OK
```

**Step 2:** Confirm currently absent.

**Step 3:** In the orchestrator's initialization/entry section (near where it reads `config.json`/`mode`, before the dispatch loop), add guidance + snippet:
```bash
# Fresh per-run model-availability cache so probes re-run each orchestration.
export CONDUCTOR_PROBE_CACHE="$(mktemp -u 2>/dev/null || echo "${TMPDIR:-/tmp}/conductor-probe-$$.cache")"
```
Note in prose: dispatched children inherit this env, so each model is probed at most once per run; the file is a throwaway temp path.

**Step 4: Verify** grep gate OK.

**Step 5: Commit**
```bash
git add agents/conductor-orchestrator.md
git commit -m "feat(models): orchestrator sets per-run CONDUCTOR_PROBE_CACHE"
```

---

## Phase 6: Docs

### Task 7: README + CHANGELOG

**Status:** [ ]

**Files:** Modify `README.md`, `CHANGELOG.md`

**Step 1:** In the README "Model Selection" section, add:
- New defaults (planning=inherit, execution=sonnet) and what they mean.
- **Fallback** subsection: configured model is probed; if it can't be selected (e.g. Ollama), commands run on the session model instead of erroring. One probe per model per run.
- `force_session_model` flag.
- The persistent `/use-models` subcommands (`set-default`, `pin`, `unpin`, `force`) and `/use-models-help`.

**Step 2:** CHANGELOG Unreleased entry:
```
- **Model-availability fallback** — the resolver now probes a configured Claude model once per run and falls back to the running session model (`inherit`) when it can't be selected (e.g. an Ollama backend), instead of erroring. New `models.force_session_model` flag forces this off explicitly. Defaults changed to planning=inherit / execution=sonnet. `/use-models` gains persistent config subcommands (`set-default`, `pin`, `unpin`, `force`) and a `/use-models-help` reference card.
```

**Step 3 (verify):**
```bash
grep -q "force_session_model" README.md && grep -q "Model-availability fallback" CHANGELOG.md && echo OK
```

**Step 5: Commit**
```bash
git add README.md CHANGELOG.md
git commit -m "docs(models): fallback, force flag, new defaults, config commands, help"
```

---

## Phase 7: Regression

### Task 8: Full regression run

**Status:** [ ]

**Step 1:** `bash scripts/test-resolve-model.sh` → `FAIL=0` (all prior + new, hermetic — no real `claude` calls).

**Step 2:** Fresh-install sim: `bash scripts/setup.sh <tmp>` → config has planning=inherit / execution=sonnet / force_session_model=false.

**Step 3:** Live spot checks:
```bash
bash scripts/resolve-model.sh writing-plans        # inherit (planning default)
CONDUCTOR_PROBE_RESULT=unavailable bash scripts/resolve-model.sh loop-executor   # inherit (fallback)
CONDUCTOR_PROBE_RESULT=available   bash scripts/resolve-model.sh loop-executor   # sonnet
```

**Step 4:** Grep gates: `/use-models` subcommands present; `/use-models-help` present; orchestrator sets `CONDUCTOR_PROBE_CACHE`.

**Step 5: Commit** (if fixups) `git commit -am "test(models): fallback regression green" || true`

---

## DAG (parallel execution)

```
Task 1 ─▶ Task 2 ─┐                    (resolver, sequential: force then probe)
                  ├─▶ Task 4 (/use-models — reflects resolver semantics)
                  ├─▶ Task 5 (/use-models-help)
                  └─▶ Task 6 (orchestrator probe cache)
Task 3 (defaults) ── after Task 2 (so live config exercises the probe path)
Task 7 (docs) ── after Tasks 3,4,5,6
Task 8 (regression) ── last
```

**Parallel groups:**
- After Task 2: Task 4, Task 5, Task 6 (independent files)
- Task 3 after Task 2
- Sequential tail: Task 7 → Task 8

## Acceptance Criteria (track-level)
- `bash scripts/test-resolve-model.sh` → FAIL=0, no real `claude` calls.
- `force_session_model: true` → inherit everywhere.
- Configured model unavailable (probe) → inherit; available → the model.
- New defaults scaffolded by setup.sh and set in live config.
- `/use-models set-default|pin|unpin|force` mutate config.json correctly; `/use-models-help` + `/use-models help` print the card.
- Orchestrator exports a per-run `CONDUCTOR_PROBE_CACHE`.
- README + CHANGELOG document everything.
