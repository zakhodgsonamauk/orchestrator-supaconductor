# Configurable Model Selection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use orchestrator-supaconductor:executing-plans to implement this plan task-by-task.

**Goal:** Make the model for each SupaConductor command/agent configurable via `conductor/config.json`, per-command overrides, and a `/use-models` session overlay — resolved by one shared script — instead of hardcoded model forcing.

**Architecture:** A single bash resolver (`scripts/resolve-model.sh`) reads `conductor/config.json` + `conductor/.session-models.json`, maps each command to a planning/execution role, applies precedence (command-pin > session-overlay > role-default > inherit), and prints a model id or `inherit`. Static `model:` frontmatter across `agents/*.md` and `commands/*.md` becomes `inherit` (interactive path follows the session model). The orchestrator dispatch swaps hardcoded `--model` values for the resolver output. `/use-models` writes/clears the overlay.

**Tech Stack:** Bash (Git Bash on Windows), **jq-free** JSON parsing via `sed` (matches the plugin's existing convention in `hooks/session-start.sh` — no new dependency), Markdown (skill/agent/command definitions). Dependency-free plain-bash test harness.

**Design reference:** `conductor/designs/2026-07-06-configurable-models-design.md`

---

## Correction vs design doc

The design placed the resolver at `conductor/bin/resolve-model.sh`. `conductor/` is per-project **runtime** (gitignored, absent on a fresh plugin install), so plugin *source* must not live there. The resolver ships at **`scripts/resolve-model.sh`** (tracked) and reads config/overlay from the project's `conductor/` at runtime. Config (`config.json`) and overlay (`.session-models.json`) remain in `conductor/`.

---

## Phase 1: Resolver script (TDD, jq-free)

> **jq-free rationale:** `hooks/session-start.sh` already parses JSON with `sed` specifically to avoid a jq dependency. Fresh machines (esp. Windows Git Bash) often lack jq; a jq-based resolver would silently degrade to `inherit` and the feature would appear broken. So the resolver uses a small `sed`-based extractor. Config/overlay JSON must keep each `"key": "value"` pair on one line (our templates do).

### Task 1: Test harness + role map + config role-default resolution

**Status:** [ ]

**Files:**
- Create: `scripts/resolve-model.sh`
- Create: `scripts/test-resolve-model.sh`

**Step 1: Write the failing test**

`scripts/test-resolve-model.sh`:
```bash
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
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/test-resolve-model.sh`
Expected: FAIL — `resolve-model.sh` missing / prints nothing.

**Step 3: Write minimal implementation**

`scripts/resolve-model.sh`:
```bash
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
```

**Step 4: Run test to verify it passes**

Run: `bash scripts/test-resolve-model.sh`
Expected: PASS — `PASS=6 FAIL=0`.

**Step 5: Commit**
```bash
git add scripts/resolve-model.sh scripts/test-resolve-model.sh
git commit -m "feat(models): jq-free resolver, role defaults + legacy back-compat"
```

---

### Task 2: Session overlay layer

**Status:** [ ]

**Files:**
- Modify: `scripts/resolve-model.sh`
- Modify: `scripts/test-resolve-model.sh`

**Step 1: Add failing test** (append before the summary in test harness):
```bash
# --- Fixture: overlay overrides role default ---
proj2="$TMP/p2"; mkdir -p "$proj2/conductor"
cp "$proj/conductor/config.json" "$proj2/conductor/config.json"
cat > "$proj2/conductor/.session-models.json" <<'JSON'
{ "planning": "fable", "execution": "sonnet" }
JSON
assert_eq "overlay beats planning role default" "fable" "$(run "$proj2" writing-plans)"
assert_eq "overlay execution passthrough" "sonnet" "$(run "$proj2" loop-executor)"
```

**Step 2: Run** `bash scripts/test-resolve-model.sh` → FAIL (overlay ignored, returns opus).

**Step 3: Implement** — insert overlay layer in `resolve-model.sh` BEFORE the role-default block:
```bash
# 2. session overlay (conductor/.session-models.json)
ov="$(json_val "$OVERLAY" "$ROLE")"
[ -n "$ov" ] && emit "$ov"
```

**Step 4: Run** → PASS.

**Step 5: Commit**
```bash
git add scripts/resolve-model.sh scripts/test-resolve-model.sh
git commit -m "feat(models): session overlay layer in resolver"
```

---

### Task 3: Per-command pin layer (highest precedence)

**Status:** [ ]

**Files:** Modify `scripts/resolve-model.sh`, `scripts/test-resolve-model.sh`

**Step 1: Add failing test:**
```bash
# --- Fixture: command pin beats overlay ---
proj3="$TMP/p3"; mkdir -p "$proj3/conductor"
cat > "$proj3/conductor/config.json" <<'JSON'
{ "models": { "planning": "opus", "execution": "sonnet",
  "overrides": {
    "board-meeting": "opus",
    "new-track": "inherit"
  } } }
JSON
cat > "$proj3/conductor/.session-models.json" <<'JSON'
{ "planning": "fable", "execution": "sonnet" }
JSON
assert_eq "command pin beats overlay" "opus"   "$(run "$proj3" board-meeting)"
assert_eq "command pin can be inherit"  "inherit" "$(run "$proj3" new-track)"
assert_eq "unpinned still uses overlay" "fable"  "$(run "$proj3" writing-plans)"
```

> **Note:** the override entries are one-per-line so the `sed` extractor matches each key. Setup templates must emit `overrides` the same way (Task 6).

**Step 2: Run** → FAIL (board-meeting returns fable).

**Step 3: Implement** — insert command-pin layer BEFORE the overlay layer. The pin is the value whose key equals the command name; it only appears inside `overrides` in our schema:
```bash
# 1. per-command pin (config.models.overrides.<command>)
pin="$(json_val "$CONFIG" "$CMD")"
[ -n "$pin" ] && emit "$pin"
```

**Step 4: Run** → PASS.

**Step 5: Commit**
```bash
git add scripts/resolve-model.sh scripts/test-resolve-model.sh
git commit -m "feat(models): per-command pin layer (top precedence)"
```

---

### Task 4: Token validation (unknown token -> inherit)

**Status:** [ ]

**Files:** Modify `scripts/resolve-model.sh`, `scripts/test-resolve-model.sh`

**Step 1: Add failing test:**
```bash
# --- Fixture: invalid token -> inherit + warning ---
proj4="$TMP/p4"; mkdir -p "$proj4/conductor"
cat > "$proj4/conductor/config.json" <<'JSON'
{ "models": { "planning": "gpt-9000", "execution": "sonnet" } }
JSON
assert_eq "invalid token falls back to inherit" "inherit" "$(run "$proj4" writing-plans 2>/dev/null)"
assert_eq "valid exact id passes" "claude-opus-4-8" \
  "$( (cd "$proj4" && echo '{"models":{"planning":"claude-opus-4-8","execution":"sonnet"}}' > conductor/config.json && bash "$RESOLVE" writing-plans) )"
```

**Step 2: Run** → FAIL (gpt-9000 echoed).

**Step 3: Implement** — replace bare `emit()` with validating emit:
```bash
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
```

**Step 4: Run** → PASS.

**Step 5: Commit**
```bash
git add scripts/resolve-model.sh scripts/test-resolve-model.sh
git commit -m "feat(models): validate model tokens, fall back to inherit"
```

---

## Phase 2: `/use-models` command

### Task 5: Create the `/use-models` command definition

**Status:** [ ]

**Files:**
- Create: `commands/use-models.md`

**Step 1 (spec-as-test):** the command must document and implement four forms: `<plan>+<exec>`, `<single>`, `show`, `reset`. Verification is a manual dry-run in Step 4 plus grep assertions.

**Step 3: Write** `commands/use-models.md`:
````markdown
---
name: use-models
description: "Set the planning/execution models for this session (writes conductor/.session-models.json)"
model: inherit
arguments:
  - name: use-models
    description: "'<plan>+<exec>', a single model for both, 'show', or 'reset'"
    required: false
user_invocable: true
---

# /orchestrator-supaconductor:use-models — Session Model Override

Sets the models SupaConductor uses **for this session** by writing an overlay
`conductor/.session-models.json`. Per-command pins in `conductor/config.json`
(`models.overrides`) still win. Precedence: command-pin > session-overlay > role-default > inherit.

## Model tokens
Aliases `opus` `sonnet` `haiku` `fable`; exact ids `claude-opus-4-8`,
`claude-sonnet-5`, `claude-haiku-4-5-20251001`, `claude-fable-5`; or `inherit`.

## Usage
| Command | Effect |
|---------|--------|
| `/use-models fable+sonnet` | planning=fable, execution=sonnet |
| `/use-models opus` | both roles = opus |
| `/use-models show` | print resolved model for every command |
| `/use-models reset` | delete the overlay (back to config defaults) |

## Your task
Parse `$ARGUMENTS`:

- **`reset`** — delete `conductor/.session-models.json` if it exists. Confirm.
- **`show`** — for each command in the role map, run
  `bash scripts/resolve-model.sh <command>` and print a two-column table
  (command → resolved model). Also print current overlay contents.
- **`<a>+<b>`** — validate both tokens against the token list; write
  `{ "planning": "<a>", "execution": "<b>" }` to `conductor/.session-models.json`.
- **`<single>`** — validate; write `{ "planning": "<x>", "execution": "<x>" }`.
- **no args** — print current overlay + usage.

Reject invalid tokens with the token list; do not write a bad overlay.
After writing, print the new planning/execution models and remind the user
per-command pins in config still apply.
````

**Step 4: Dry-run verification**
```bash
# from repo root
echo '{ "models": { "planning":"opus","execution":"sonnet","overrides":{"board-meeting":"opus"} } }' > conductor/config.json
printf '{ "planning":"fable","execution":"sonnet" }' > conductor/.session-models.json
bash scripts/resolve-model.sh writing-plans   # expect: fable
bash scripts/resolve-model.sh board-meeting    # expect: opus
bash scripts/resolve-model.sh loop-executor    # expect: sonnet
rm conductor/.session-models.json
bash scripts/resolve-model.sh writing-plans    # expect: opus
```
Expected: fable / opus / sonnet / opus.

**Step 5: Commit**
```bash
git add commands/use-models.md
git commit -m "feat(models): add /use-models session override command"
```

---

## Phase 3: Config schema + gitignore

### Task 6: config schema in ALL setup paths + live config, ignore overlay

**Status:** [ ]

**Files:**
- Modify: `conductor/config.json` (this project)
- Modify: `commands/conductor-setup.md:46-54` (command template)
- Modify: `commands/setup.md` (model block, ~72-82)
- Modify: `scripts/setup.sh` (**currently creates NO config.json — the shell install path leaves fresh projects without a `models` block; this is the fresh-machine gap**)
- Modify: `.gitignore`

**Step 1:** Canonical `models` block replaces flat `planning_model`/`execution_model` everywhere:
```json
{
  "mode": "agentic",
  "max_fix_cycles": 5,
  "models": {
    "planning": "opus",
    "execution": "sonnet",
    "overrides": {}
  }
}
```
(Resolver still reads legacy flat keys for back-compat — Task 1.)

> **H-1 (from plan evaluation):** the resolver's `sed` parser reads one `"key": "value"` per
> line, so each entry in `overrides` MUST be on its own line (the template above keeps
> `overrides` empty `{}`; document one-per-line in the README config example — Task 10).

**Step 2:** Add a `config.json` creation block to `scripts/setup.sh` (mirror the existing `if [ ! -f ... ]` guards; do NOT overwrite an existing config). Insert after the `knowledge/patterns.md` block:
```bash
# Create config.json if it doesn't exist
if [ ! -f "$PROJECT_DIR/conductor/config.json" ]; then
  cat > "$PROJECT_DIR/conductor/config.json" << 'CONFIG_EOF'
{
  "mode": "agentic",
  "max_fix_cycles": 5,
  "models": {
    "planning": "opus",
    "execution": "sonnet",
    "overrides": {}
  }
}
CONFIG_EOF
  echo "  Created conductor/config.json"
fi
```

**Step 3:** Apply the canonical block to `commands/conductor-setup.md` + `commands/setup.md` templates, and to this project's `conductor/config.json`.

**Step 4:** Ensure `.gitignore` ignores the overlay (already covered by `conductor/`, but add an explicit commented line):
```
# Session model overlay (runtime, per-session)
conductor/.session-models.json
```

**Step 5: Verify** (jq-free — do not assume jq present)
```bash
bash scripts/resolve-model.sh writing-plans       # opus
git check-ignore conductor/.session-models.json   # ignored
# Fresh-install simulation: setup.sh must produce a config with a models block
d=$(mktemp -d); bash scripts/setup.sh "$d"; grep -q '"models"' "$d/conductor/config.json" && echo "setup.sh writes models OK"; rm -rf "$d"
```

**Step 6: Commit**
```bash
git add conductor/config.json commands/conductor-setup.md commands/setup.md scripts/setup.sh .gitignore
git commit -m "feat(models): config.models schema in all setup paths + ignore overlay"
```

---

## Phase 4: Strip static frontmatter forcing → inherit

### Task 7: Change all `model:` frontmatter to `inherit`

**Status:** [ ]

**Files (all `model: opus|sonnet` frontmatter → `model: inherit`):**
- Agents: `agents/ceo.md`, `cmo.md`, `board-meeting.md`, `cto.md`, `ux-designer.md`, `loop-plan-evaluator.md`, `loop-planner.md`, `loop-executor.md`, `conductor-orchestrator.md`, `loop-fixer.md`, `loop-execution-evaluator.md`, `name-picker.md`, `parallel-dispatcher.md`, `task-worker.md` (leave `code-reviewer.md` — already `inherit`)
- Commands: all 38 files from the inventory in the design/track notes (ceo, board-review, brainstorming, board-meeting, conductor-new-track, cmo, conductor-implement, conductor-status, cto, brainstorm, conductor-setup, close-track, cto-advisor, loop-execution-evaluator, executing-plans, go, evaluate-plan, finishing-a-development-branch, new-track, loop-fixer, implement, loop-planner, loop-executor, execute-plan, evaluate-execution, loop-plan-evaluator, systematic-debugging, writing-plans, plan-sprint, ui-audit, task-worker, setup, write-plan, ux-designer, phase-review, parallel-dispatcher, status, using-git-worktrees)

**Step 1 (test = grep assertion):** define the acceptance check first.
Run: `grep -rEl '^model:\s*(opus|sonnet|haiku|fable)\b' agents commands`
Expected AFTER edit: no output (exit 1).

**Step 2:** Confirm it currently FAILS (lists ~52 files).

**Step 3: Apply edit** — bulk replace the frontmatter line. Only touch lines that are exactly the frontmatter `model:` key (start of line), never `--model` inside code blocks:
```bash
grep -rEl '^model:[[:space:]]*(opus|sonnet|haiku|fable)\b' agents commands \
| while read -r f; do
    sed -i -E 's/^model:[[:space:]]*(opus|sonnet|haiku|fable)\b.*/model: inherit/' "$f"
  done
```

**Step 4: Verify**
```bash
grep -rE '^model:\s*(opus|sonnet|haiku|fable)\b' agents commands   # expect: no matches
grep -rc '^model: inherit' agents commands | grep -v ':0' | wc -l  # >= 53
```

**Step 5: Commit**
```bash
git add agents commands
git commit -m "refactor(models): frontmatter model -> inherit (interactive follows session)"
```

---

## Phase 5: Wire orchestrated dispatch to the resolver

### Task 8: Replace hardcoded model logic in conductor-orchestrator.md

**Status:** [ ]

**Files:**
- Modify: `agents/conductor-orchestrator.md:177-186` (runnable dispatch), and the documentation examples at `:384-448` and `:660`

**Step 1 (test = grep assertion):**
Run: `grep -nE 'claude --print --model (opus|sonnet)' agents/conductor-orchestrator.md`
Expected AFTER edit: no matches.

**Step 2:** Confirm currently FAILS (lists the lines).

**Step 3: Implement** — replace the `case` block (177-186) with resolver-driven dispatch.

> **FIX-1 (from plan evaluation):** Address the resolver via `${CLAUDE_PLUGIN_ROOT}` — the
> convention already used in `hooks/hooks.json` — NOT `$(dirname "$0")`, which does not
> reliably point at the plugin `scripts/` dir when the orchestrator dispatches through
> `run_shell_command`. Keep a `$(dirname "$0")/..` fallback for direct execution. CWD stays
> the project dir so the resolver reads `conductor/config.json` + overlay relative to CWD.

```bash
    # Resolve model via shared resolver (config + session overlay + pins)
    # Plugin scripts live under CLAUDE_PLUGIN_ROOT (see hooks/hooks.json); fall back to
    # a path relative to this file for direct execution.
    local plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    local resolver="${plugin_root}/scripts/resolve-model.sh"
    local model="inherit"
    [ -f "$resolver" ] && model="$(bash "$resolver" "$superpower" 2>/dev/null)"
    [ -z "$model" ] && model="inherit"

    echo "→ Invoking orchestrator-supaconductor:$superpower for track $track_id (model: $model)"
    if [ "$model" = "inherit" ]; then
        claude --print "/orchestrator-supaconductor:$superpower $params"
    else
        claude --print --model "$model" "/orchestrator-supaconductor:$superpower $params"
    fi
    local exit_code=$?
```
Then update the documentation examples (388-448, 660) to show the same resolver pattern, e.g.:
```bash
resolver="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-model.sh"
model=$(bash "$resolver" writing-plans)
[ "$model" = inherit ] && claude --print "/...writing-plans ..." \
                       || claude --print --model "$model" "/...writing-plans ..."
```
(Replace each literal `--model opus/sonnet` example accordingly.)

**Step 4: Verify**
```bash
grep -nE 'claude --print --model (opus|sonnet)' agents/conductor-orchestrator.md  # none
```

**Step 5: Commit**
```bash
git add agents/conductor-orchestrator.md
git commit -m "feat(models): orchestrator dispatch uses resolve-model.sh"
```

---

### Task 9: Fix remaining dispatch literal in orchestrator SKILL doc

**Status:** [ ]

**Files:**
- Modify: `skills/conductor-orchestrator/SKILL.md:998`

**Step 1 (test):**
Run: `grep -rnE 'claude --print --model (opus|sonnet)' skills agents`
Expected AFTER: no matches.

**Step 2:** Confirm currently FAILS (line 998).

**Step 3: Implement** — replace the board-meeting spawn with resolver pattern (FIX-1: `${CLAUDE_PLUGIN_ROOT}`):
```bash
resolver="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-model.sh"
model=$(bash "$resolver" board-meeting)
[ "$model" = inherit ] && claude --print "/orchestrator-supaconductor:board-meeting {question}" \
                       || claude --print --model "$model" "/orchestrator-supaconductor:board-meeting {question}"
```

**Step 4: Verify** `grep -rnE 'claude --print --model (opus|sonnet)' skills agents` → none.

**Step 5: Commit**
```bash
git add skills/conductor-orchestrator/SKILL.md
git commit -m "feat(models): board-meeting spawn uses resolver in orchestrator skill"
```

---

## Phase 6: Documentation

### Task 10: Document config + /use-models + limitation + Requirements in README

**Status:** [ ]

**Files:**
- Modify: `README.md` (Model Selection section near mode/config ~204; **Requirements section ~468**)
- Modify: `CHANGELOG.md` (add entry)

**Step 1a — Requirements (gap E):** the README Requirements list is only "Claude Code CLI" + "Git". The resolver and every hook need bash. Update to:
```markdown
## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Git
- Bash — on Windows this is Git Bash (bundled with Git for Windows); hooks and the model resolver run under it. No jq or other tools required.
```

**Step 1b:** Draft a "Model Selection" section covering: `models` schema, token vocabulary, per-command overrides, `/use-models` forms, precedence order, and the interactive-vs-orchestrated limitation (interactive path follows the session model via `inherit`; per-command overrides only apply on the orchestrated path).

**Step 3: Write** the section + a CHANGELOG entry under Unreleased:
```
- **Configurable model selection** — models are no longer hardcoded per command. Set `models.planning`/`models.execution` and `models.overrides.<command>` in `conductor/config.json`, or `/use-models <plan>+<exec>` for the session. Resolved by `scripts/resolve-model.sh`. Frontmatter now inherits the session model.
```

**Step 4: Verify**
```bash
grep -n "use-models" README.md          # section present
grep -n "Configurable model" CHANGELOG.md
```

**Step 5: Commit**
```bash
git add README.md CHANGELOG.md
git commit -m "docs(models): document configurable model selection + /use-models"
```

---

### Task 11: Full regression run

**Status:** [ ]

**Step 1:** Run the resolver test suite:
```bash
bash scripts/test-resolve-model.sh
```
Expected: `PASS=<n> FAIL=0`.

**Step 2:** Global grep gates (all expect no matches):
```bash
grep -rE '^model:\s*(opus|sonnet|haiku|fable)\b' agents commands
grep -rnE 'claude --print --model (opus|sonnet)' agents skills
```

**Step 3:** End-to-end resolver spot check with overlay + pins (Task 5 dry-run block).

**Step 4:** Fresh-install simulation (fresh-machine coverage):
```bash
d=$(mktemp -d); bash scripts/setup.sh "$d"
grep -q '"models"' "$d/conductor/config.json" && echo "setup writes models OK"
( cd "$d" && bash "$OLDPWD/scripts/resolve-model.sh" writing-plans )   # expect opus
rm -rf "$d"
```

**Step 5: Commit** (if any doc/fixups)
```bash
git commit -am "test(models): regression gates green" || true
```

---

## DAG (parallel execution)

```
Task 1 ─▶ Task 2 ─▶ Task 3 ─▶ Task 4 ─┐        (resolver, strictly sequential)
                                       ├─▶ Task 5  (/use-models — needs resolver)
                                       ├─▶ Task 8  (orchestrator dispatch — needs resolver)
                                       └─▶ Task 9  (skill dispatch — needs resolver)
Task 6 (config schema) ── independent, can run anytime after Task 1
Task 7 (frontmatter → inherit) ── fully independent (no resolver dep)
Task 10 (docs) ── after Tasks 5,6,7,8,9
Task 11 (regression) ── last, after all
```

**Parallel groups:**
- Group A (after Task 4): Task 5, Task 8, Task 9
- Independent early: Task 6, Task 7 (can start immediately)
- Sequential tail: Task 10 → Task 11

## Acceptance Criteria (track-level)
- `bash scripts/test-resolve-model.sh` → FAIL=0.
- No `model: opus|sonnet|haiku|fable` frontmatter remains in `agents/` or `commands/`.
- No `claude --print --model opus|sonnet` literals remain in `agents/` or `skills/`.
- `/use-models fable+sonnet` then resolver returns fable/sonnet respecting config pins; `reset` restores defaults.
- README + CHANGELOG document the feature and the interactive-path limitation.
- **Fresh-install**: `scripts/setup.sh <dir>` produces a `config.json` containing a `models` block; resolver works with zero extra dependencies (no jq); README Requirements list bash.
