# Spec: Model-Availability Fallback + Config Commands

## Goal
Keep opus/sonnet as configurable defaults, but if switching to a configured Claude model fails (e.g. harness running Ollama), silently fall back to the running session model (`inherit`) instead of erroring. Change defaults to planning=inherit / execution=sonnet. Add slash commands to manage the persistent config and a help card.

## Requirements
- **Availability fallback**: when the resolver produces a non-`inherit` model, verify the model can actually be selected; if not, return `inherit`. Detected by a one-time-per-run probe (`claude --print --model M "ok"`), cached per run.
- **Per-run cache**: cache path from `$CONDUCTOR_PROBE_CACHE` (orchestrator sets a fresh temp path per loop); default `conductor/.model-availability.json` when unset.
- **Hermetic test hook**: `$CONDUCTOR_PROBE_RESULT` (`available`|`unavailable`) short-circuits the real probe so tests never call `claude`.
- **`force_session_model` flag**: `config.models.force_session_model: true` → resolver returns `inherit` for everything, skips probing.
- **New defaults**: `models.planning: "inherit"`, `models.execution: "sonnet"`, `models.force_session_model: false` in setup.sh, both setup command templates, and live config.
- **Resolution order**: force-flag → command-pin → session-overlay → role-default → inherit, THEN availability-probe on the resolved candidate.
- **`/use-models` persistent subcommands**: `set-default <plan>+<exec>`, `pin <cmd>=<model>`, `unpin <cmd>`, `force on|off` (edit `config.json`); plus `help`; richer `show`.
- **`/use-models-help`**: dedicated one-shot reference command.
- Docs: README + CHANGELOG.

## Acceptance Criteria
- Resolver: force flag → inherit; probe-unavailable → inherit; probe-available → candidate; seeded cache honored without probing; new default (planning=inherit) → inherit with no probe.
- All prior resolver tests still pass; new tests hermetic (no `claude` call).
- `/use-models set-default`, `pin`, `unpin`, `force` correctly mutate `config.json` (one override per line); invalid tokens rejected.
- `/use-models-help` and `/use-models help` print the reference card.
- Orchestrator exports `CONDUCTOR_PROBE_CACHE` once at loop start.
- README documents fallback, `force_session_model`, new defaults, config commands, help.

## Out of Scope
- Detecting which backend is running (only care whether `--model M` succeeds).
- Interactive-path changes (frontmatter already `inherit`).

## Technical Notes
- jq-free bash (sed), consistent with existing resolver.
- Probe wrapped in `timeout` when available; timeout/error → unavailable → inherit (safe).
- Design: `conductor/designs/2026-07-15-model-fallback-design.md`.
