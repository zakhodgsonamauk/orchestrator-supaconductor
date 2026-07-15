# Design: Model-Availability Fallback + Config Commands

**Date**: 2026-07-15
**Status**: Approved (brainstorming)
**Builds on**: `2026-07-06-configurable-models-design.md` (the resolver, `/use-models`, frontmatter→inherit).

## Problem
Configured Claude models (opus/sonnet) may be unavailable when the harness runs a non-Anthropic backend (e.g. Ollama). Forcing `--model opus` there errors. We want: keep opus/sonnet as *defaults*, but if switching to a configured model fails, silently stay on whatever model is already running (`inherit`) instead of erroring. Also: a new default of planning=inherit / execution=sonnet, and slash commands to manage the persistent config + a help card.

## Key insight
The **interactive path** already uses `model: inherit` frontmatter → always the running model → already Ollama-safe. The **only** place a Claude model is forced is the orchestrator's `claude --print --model X` dispatch. So the probe/fallback and the `force_session_model` flag only affect the orchestrated path.

## Resolution order (updated)
```
resolve(command):
  1. if config.models.force_session_model == true       -> inherit   # manual escape hatch, short-circuits
  2. candidate = command-pin ?? overlay ?? role-default ?? inherit    # existing logic + valid_token
  3. if candidate == inherit                             -> inherit
  4. if NOT available(candidate)                          -> inherit   # probe/cache
  5. else                                                 -> candidate
```
Steps 1 and 4 are new; 2–3 unchanged from the prior design.

## `available(model)` — probe once, cache per-run
```
available(M):
  cachefile = ${CONDUCTOR_PROBE_CACHE:-conductor/.model-availability.json}
  if cachefile has line "M=0" -> return false
  if cachefile has line "M=1" -> return true
  # test hook (hermetic): if $CONDUCTOR_PROBE_RESULT is set, use it and cache it
  #   available -> ok=0 ; unavailable -> ok=1(nonzero)
  else: run `claude --print --model "M" "ok"` with ~20s timeout ; ok = (exit == 0)
  append "M=<0|1>" to cachefile
  return ok
```
- **Per-run scope**: the orchestrator exports `CONDUCTOR_PROBE_CACHE="$(mktemp -u)"` once at loop start; dispatched children inherit it → one shared cache per run, auto-fresh each run (fresh temp path). When unset (standalone `/use-models show`), the resolver uses the default `conductor/.model-availability.json` and probes if the entry is absent.
- **One probe per distinct model per run** (opus/sonnet → ≤2). Under Ollama both fail fast → cached → everything inherits.
- **No double-run of real agents** — probe is a trivial throwaway `claude` call.
- **No recursion** — probe calls `claude` directly, never the resolver.
- **Timeout guard** — if `timeout` is available, wrap the probe; on timeout treat as unavailable → inherit (safe).

## `force_session_model`
`config.models.force_session_model: true` → resolver returns `inherit` for everything, skips probes. For known-Ollama setups. Default `false`.

## New defaults (config template + live config)
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
- planning=`inherit` → planning commands use the session model (no probe).
- execution=`sonnet` → execution commands try sonnet, fall back to session if unavailable.

## `/use-models` — full surface
Session overlay (ephemeral, `conductor/.session-models.json`):
| Command | Effect |
|---------|--------|
| `/use-models <plan>+<exec>` | session overlay roles |
| `/use-models <single>` | both roles = token |
| `/use-models reset` | delete overlay + per-run probe cache |
| `/use-models show` | table: config defaults, overrides, force flag, session overlay, resolved model per command |
| `/use-models help` | print the reference card (same as /use-models-help) |

Persistent config (`conductor/config.json`, new):
| Command | Effect |
|---------|--------|
| `/use-models set-default <plan>+<exec>` | write `models.planning` / `models.execution` |
| `/use-models pin <command>=<model>` | set `models.overrides["<command>"]` (one entry per line) |
| `/use-models unpin <command>` | remove that override |
| `/use-models force on` \| `off` | set `models.force_session_model` |

All tokens validated against the vocabulary (`opus|sonnet|haiku|fable|inherit` + exact ids). Invalid → reject, no write.

## `/use-models-help`
Dedicated, discoverable slash command (`commands/use-models-help.md`, `model: inherit`) that prints a one-shot reference card: full command surface (session + persistent), token vocabulary, precedence order, Ollama/fallback behavior, `force_session_model`, and the interactive-vs-orchestrated note. One-shot display (pattern: caveman-help). `/use-models help` shows the same card.

## Files touched
- `scripts/resolve-model.sh` — force flag (step 1) + `available()` probe/cache (step 4)
- `scripts/test-resolve-model.sh` — +tests (probe hook available/unavailable, force flag, seeded cache, new defaults)
- `commands/use-models.md` — persistent subcommands + help + richer show
- `commands/use-models-help.md` — new reference command
- `scripts/setup.sh`, `commands/setup.md`, `commands/conductor-setup.md`, live `conductor/config.json` — new defaults + `force_session_model`
- `agents/conductor-orchestrator.md` — `export CONDUCTOR_PROBE_CACHE` at loop start
- `README.md`, `CHANGELOG.md` — document fallback, flag, new defaults, config commands, help

## Testing (hermetic — no real claude/network)
- `CONDUCTOR_PROBE_RESULT=unavailable` + execution role=sonnet → resolver returns `inherit`.
- `CONDUCTOR_PROBE_RESULT=available` + sonnet → returns `sonnet`.
- `force_session_model: true` → `inherit` regardless of pins/overlay.
- Pre-seeded cache `sonnet=0` → returns `inherit` without invoking the probe.
- New default config (planning=inherit) → planning command returns `inherit` (no probe).
- All prior 13 tests still pass (add `models.planning:"opus"` fixtures where they assert opus, or keep their own configs — fixtures are self-contained, so unaffected).

## Out of scope
- Detecting *which* non-Anthropic backend is running (we only care: does `--model M` succeed).
- Changing interactive-path behavior (already inherit).
