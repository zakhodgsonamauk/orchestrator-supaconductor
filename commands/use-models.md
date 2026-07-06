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

Model selection is fully honored on the **orchestrated path** (the autonomous
Evaluate-Loop, which dispatches child `claude --print` processes via
`scripts/resolve-model.sh`). On the **interactive path** (you typing a command in
your own session), commands inherit your current session model — the overlay and
per-command pins cannot change that, since frontmatter is static.

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
Parse `$ARGUMENTS` (trim whitespace):

- **`reset`** — delete `conductor/.session-models.json` if it exists. Confirm what you did.
- **`show`** — for each command in the role map (see `scripts/resolve-model.sh`), run
  `bash scripts/resolve-model.sh <command>` and print a two-column table
  (command → resolved model). Also print the current overlay contents (or "none").
- **`<a>+<b>`** — validate both tokens against the token list below; if valid, write
  `conductor/.session-models.json` with:
  ```json
  { "planning": "<a>", "execution": "<b>" }
  ```
- **`<single>`** (one token, no `+`) — validate; write both roles to that token:
  ```json
  { "planning": "<x>", "execution": "<x>" }
  ```
- **no args** — print the current overlay (or "none") and this usage table.

**Valid tokens:** `opus`, `sonnet`, `haiku`, `fable`, `inherit`,
`claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5-20251001`, `claude-fable-5`.

Reject invalid tokens by printing the valid-token list; do NOT write a bad overlay.
Each JSON key/value must be on its own line (the resolver parses line-by-line).
After writing, print the new planning/execution models and remind the user that
per-command pins in `conductor/config.json` still apply, and that the interactive
path follows the session model regardless.

## Related
- `conductor/config.json` — `models.planning` / `models.execution` / `models.overrides` defaults
- `scripts/resolve-model.sh` — the resolver this overlay feeds
