---
name: use-models
description: "Set session or persistent model config (writes conductor/.session-models.json or config.json)"
model: inherit
arguments:
  - name: use-models
    description: "'<plan>+<exec>' | '<single>' | show | reset | set-default <p>+<e> | pin <cmd>=<model> | unpin <cmd> | force on|off | help"
    required: false
user_invocable: true
---

# /orchestrator-supaconductor:use-models — Model Configuration

Configure which models SupaConductor uses. Two scopes:

- **Session overlay** — `conductor/.session-models.json` (ephemeral, gitignored). Sets the
  two role models for this session only.
- **Persistent config** — `conductor/config.json` → `models.*`. Defaults, per-command pins,
  and the `force_session_model` flag.

**Precedence:** `force_session_model` → per-command pin → session overlay → role default →
`inherit`. The resolved model is then probed for availability: if it can't be selected
(e.g. an Ollama backend), it falls back to the running session model (`inherit`) instead of
erroring. Set `force_session_model` on to skip probing and always use the session model.

Model selection is fully honored on the **orchestrated path** (the autonomous Evaluate-Loop,
which dispatches child processes via `scripts/resolve-model.sh`). On the **interactive path**
(you typing a command in your own session) commands inherit your current session model —
frontmatter is static `inherit`, so the overlay/pins can't change it there.

## Model tokens
Aliases `opus` `sonnet` `haiku` `fable`; exact ids `claude-opus-4-8`, `claude-sonnet-5`,
`claude-haiku-4-5-20251001`, `claude-fable-5`; or `inherit`.

## Usage

**Session (ephemeral):**
| Command | Effect |
|---------|--------|
| `/use-models fable+sonnet` | overlay: planning=fable, execution=sonnet |
| `/use-models opus` | overlay: both roles = opus |
| `/use-models show` | print resolved model per command + all config |
| `/use-models reset` | delete the overlay and the per-run probe cache |

**Persistent (`config.json`):**
| Command | Effect |
|---------|--------|
| `/use-models set-default inherit+sonnet` | set `models.planning` / `models.execution` |
| `/use-models pin board-meeting=opus` | set `models.overrides["board-meeting"]` |
| `/use-models unpin board-meeting` | remove that override |
| `/use-models force on` \| `off` | set `models.force_session_model` |

| `/use-models help` | print the full reference card (same as `/use-models-help`) |

## Your task
Parse `$ARGUMENTS` (trim whitespace). Validate every model token against the list below;
reject invalid tokens by printing the valid-token list and writing nothing.

- **`help`** — print the reference card (see `/use-models-help`) and stop.
- **`reset`** — delete `conductor/.session-models.json` and `conductor/.model-availability.json`
  if present. Confirm what you did.
- **`show`** — print:
  1. Config defaults: `models.planning`, `models.execution`, `models.force_session_model`.
  2. `models.overrides` entries.
  3. Session overlay contents (or "none").
  4. A resolved table: for each command in the role map (see `scripts/resolve-model.sh`),
     run `bash scripts/resolve-model.sh <command>` and print command → resolved model.
- **`set-default <a>+<b>`** — write `models.planning=<a>`, `models.execution=<b>` in
  `conductor/config.json` (create the `models` object if missing). Keep other keys intact.
- **`set-default <x>`** — set both roles to `<x>`.
- **`pin <command>=<model>`** — set `models.overrides["<command>"] = "<model>"` in
  `conductor/config.json`. Create `overrides` if absent. Write each override on its own line
  (the resolver parses line-by-line).
- **`unpin <command>`** — remove `<command>` from `models.overrides`.
- **`force on`** / **`force off`** — set `models.force_session_model` to `true` / `false`.
- **`<a>+<b>`** — write session overlay `{ "planning": "<a>", "execution": "<b>" }` (one key
  per line) to `conductor/.session-models.json`.
- **`<single>`** — session overlay with both roles = `<x>`.
- **no args** — print the current overlay (or "none") and this usage table.

**Valid tokens:** `opus`, `sonnet`, `haiku`, `fable`, `inherit`, `claude-opus-4-8`,
`claude-sonnet-5`, `claude-haiku-4-5-20251001`, `claude-fable-5`.

After any write, print the new state and remind the user of the precedence order and that
the interactive path follows the session model regardless.

## Related
- `/orchestrator-supaconductor:use-models-help` — full reference card
- `conductor/config.json` — persistent `models.*` config
- `scripts/resolve-model.sh` — the resolver these settings feed
