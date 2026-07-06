# Design: Configurable Model Selection

**Date**: 2026-07-06
**Status**: Approved (brainstorming)
**Problem**: The plugin hardcodes models per command/agent. Running the session on Fable still forces Opus for `new-track`, `writing-plans`, etc. Model choice must be configurable and flexible.

## Root cause

Two forcing mechanisms:

1. **Static frontmatter** — `model: opus|sonnet` hardcoded in every `agents/*.md` and some `commands/*.md`. Claude Code reads this at launch (interactive path).
2. **Orchestrator dispatch** — `conductor-orchestrator.md` hardcodes `claude --print --model opus/sonnet` in a `case` block (lines 177-182) plus many literal `--model` lines.

`config.json` already contains `planning_model`/`execution_model` but **nothing reads them** — dead config.

## Two invocation paths (key constraint)

| Path | Model chosen by | Configurable |
|------|-----------------|--------------|
| Interactive (`/new-track` typed in session) | frontmatter `model:` at launch — static, cannot read a file | only via `inherit` → follows session model |
| Orchestrated (`claude --print --model X` child procs) | `--model` flag at dispatch | fully — reads config + overlay |

**Design consequence**: strip static forcing to `inherit` everywhere (fixes interactive — Fable session → Fable), AND wire config+overlay into orchestrated dispatch (full control on automated path). Per-command overrides + `/use-models` are fully honored only on the orchestrated path; documented limitation.

## §1 Model vocabulary

Any model field accepts:

| Token | Meaning |
|-------|---------|
| `opus` `sonnet` `haiku` `fable` | short alias → latest of tier |
| `claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5-20251001`, `claude-fable-5` | exact id |
| `inherit` | use session model (no `--model` flag) |

Unknown token → error + fall back to `inherit` (never crash a track).

## §2 Config schema (`conductor/config.json`)

```json
{
  "mode": "agentic",
  "max_fix_cycles": 5,
  "models": {
    "planning": "opus",
    "execution": "sonnet",
    "overrides": {
      "board-meeting": "opus",
      "new-track": "inherit"
    }
  }
}
```

- `models.planning` / `models.execution` — role defaults.
- `models.overrides` — per-command pins by command/skill name (highest priority). Any §1 token including `inherit`.
- Back-compat: if `models` absent, read legacy top-level `planning_model`/`execution_model`. Migrate on first `/use-models` write.

## §3 Command→role map

Static table inside resolver:

- **planning**: `writing-plans`, `brainstorming`, `loop-planner`, `loop-plan-evaluator`, `new-track`, `board-meeting`, `ceo`, `cto`, `cmo`, `ux-designer`
- **execution**: `executing-plans`, `loop-executor`, `loop-execution-evaluator`, `loop-fixer`, `systematic-debugging`, `task-worker`, `parallel-dispatcher`

## §4 Session overlay + `/use-models`

Overlay `conductor/.session-models.json` (gitignored under `conductor/`):
```json
{ "planning": "fable", "execution": "sonnet" }
```

Command `/use-models`:

| Invocation | Effect |
|-----------|--------|
| `/use-models fable+sonnet` | plan=fable, exec=sonnet for session |
| `/use-models opus` | both roles = opus |
| `/use-models show` | print resolved model for every command |
| `/use-models reset` | delete overlay → config defaults |

Overlay sets role models only. Per-command config pins still win.

## §5 Resolver (`conductor/bin/resolve-model.sh`)

`resolve-model.sh <command-name>` → prints model id or `inherit`:

```
role = ROLE_MAP[command]
if config.models.overrides[command] exists  -> echo it            # 1 command pin
elif overlay[role] exists                    -> echo overlay[role]  # 2 session
elif config.models[role] exists              -> echo it             # 3 role default
else                                         -> echo "inherit"      # 4 fallback
```

Precedence: **command-pin > session-overlay > role-default > inherit**.

## §6 Wiring

- Interactive: every `model: opus|sonnet` in `agents/*.md` + `commands/*.md` frontmatter → `model: inherit`.
- Orchestrated: replace hardcoded `case` (orchestrator lines 177-182) and every literal `--model opus/sonnet`:
  ```bash
  model=$(conductor/bin/resolve-model.sh "$superpower")
  if [ "$model" = "inherit" ]; then claude --print "/..."
  else claude --print --model "$model" "/..."; fi
  ```
  Same in `parallel-dispatcher.md`, `task-worker.md` where they dispatch.

## §7 Testing

- Resolver unit checks: each precedence layer, unknown-token→inherit, back-compat legacy fields, missing overlay/config.
- `/use-models show` snapshot before/after `fable+sonnet`.

## Scope

config.json, ~20 frontmatter blocks, orchestrator dispatch, +2 new files (resolver, `/use-models` command), README docs.

## Defaulted decisions

- Overlay filename `conductor/.session-models.json`.
- `/use-models opus` single-arg = both roles.
