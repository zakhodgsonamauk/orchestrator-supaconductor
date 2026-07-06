# Spec: Configurable Model Selection

## Goal
Make the model used by each SupaConductor command/agent configurable instead of hardcoded. Running the session on any model (e.g. Fable) must not force Opus/Sonnet for planning/execution commands.

## Requirements
- Config-driven role models: `models.planning` and `models.execution` in `conductor/config.json`.
- Per-command overrides: `models.overrides.<command>` pins a specific command/skill to any model or `inherit`.
- Session command `/use-models`:
  - `/use-models fable+sonnet` → plan=fable, exec=sonnet for the session
  - `/use-models opus` → both roles = opus
  - `/use-models show` → print resolved model per command
  - `/use-models reset` → clear overlay
- Overlay stored in `conductor/.session-models.json`.
- Shared resolver `conductor/bin/resolve-model.sh <command>` prints resolved model id or `inherit`.
- Precedence: **command-pin > session-overlay > role-default > inherit**.
- Interactive path: static `model:` frontmatter in `agents/*.md` + `commands/*.md` changed to `inherit` (follows session model).
- Orchestrated path: `conductor-orchestrator.md` (and parallel-dispatcher / task-worker where they dispatch) call the resolver instead of hardcoded `--model` values; omit `--model` when resolver returns `inherit`.
- Model vocabulary: aliases `opus|sonnet|haiku|fable`, exact ids (`claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5-20251001`, `claude-fable-5`), and `inherit`.
- Back-compat: if `models` block absent, read legacy top-level `planning_model`/`execution_model`.

## Acceptance Criteria
- `resolve-model.sh` returns correct model for each precedence layer (verified by tests).
- Unknown token → `inherit` (never crashes a track).
- `/use-models fable+sonnet` then `/use-models show` reflects fable/sonnet, respecting config command-pins.
- `/use-models reset` removes overlay; resolver returns config defaults.
- No `agents/*.md` or `commands/*.md` frontmatter contains `model: opus|sonnet|haiku|fable` (all `inherit`, except `code-reviewer` already inherit).
- Orchestrator dispatch contains no literal `--model opus|sonnet`; all go through resolver.
- README documents config schema, `/use-models`, and the interactive-vs-orchestrated limitation.

## Out of Scope
- Changing which model is "best" for a role (defaults stay opus/sonnet).
- Per-model prompt tuning.
- Making interactive-path per-command overrides work (frontmatter is static — documented limitation).

## Technical Notes
- Git Bash available on Windows; resolver is bash + jq (fallback to grep/sed if jq absent).
- `conductor/` is gitignored in this repo; resolver + overlay live under `conductor/bin` and `conductor/` — but the resolver script is plugin source, so it must be force-added / relocated to a tracked path. See plan Task 0.
- Full design: `conductor/designs/2026-07-06-configurable-models-design.md`.
