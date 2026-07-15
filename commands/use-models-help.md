---
name: use-models-help
description: "Reference card explaining /use-models and SupaConductor model configuration"
model: inherit
user_invocable: true
---

# /orchestrator-supaconductor:use-models-help — Model Config Reference

Print the reference below to the user verbatim (formatted as Markdown). This is a one-shot
reference card — do NOT enter any mode, edit files, or run commands.

---

## What controls which model runs

SupaConductor maps every command to a **role** — `planning` or `execution` — and each role
has a default model. You can override per session, pin individual commands, or force the
session model. A resolver (`scripts/resolve-model.sh`) computes the final model.

**Precedence (highest first):**
1. `force_session_model: true` → always `inherit`
2. per-command pin (`models.overrides.<command>`)
3. session overlay (`/use-models <plan>+<exec>`)
4. role default (`models.planning` / `models.execution`)
5. `inherit`

The resolved model is then **probed**: if it can't be selected (e.g. running on Ollama or any
non-Anthropic backend), it falls back to the running session model (`inherit`) instead of
erroring. Probe result is cached once per run.

## Defaults
`planning: inherit`, `execution: sonnet`. So planning commands run on your session model;
execution commands try `sonnet` and fall back to the session model if it isn't available.

## Tokens
Aliases: `opus` `sonnet` `haiku` `fable`. Exact ids: `claude-opus-4-8`, `claude-sonnet-5`,
`claude-haiku-4-5-20251001`, `claude-fable-5`. Or `inherit` (use the running session model).

## Commands

**Session (ephemeral — `conductor/.session-models.json`):**
| Command | Effect |
|---------|--------|
| `/use-models fable+sonnet` | this session: planning=fable, execution=sonnet |
| `/use-models opus` | this session: both roles = opus |
| `/use-models show` | show config defaults, overrides, force flag, overlay, and the resolved model per command |
| `/use-models reset` | delete the session overlay + per-run probe cache |

**Persistent (`conductor/config.json`):**
| Command | Effect |
|---------|--------|
| `/use-models set-default inherit+sonnet` | set the role defaults |
| `/use-models pin board-meeting=opus` | pin one command to a model (or `inherit`) |
| `/use-models unpin board-meeting` | remove a pin |
| `/use-models force on` / `off` | toggle `force_session_model` |

`/use-models help` shows this card.

## Interactive vs orchestrated (important)
- **Orchestrated path** (the autonomous Evaluate-Loop) fully honors all of the above.
- **Interactive path** (you typing a command in your own session) always runs on your current
  session model — command frontmatter is static `inherit`, so overlays/pins don't change it
  there. Running your session on Fable therefore runs interactive commands on Fable.

## Where things live
- `conductor/config.json` → `models.{planning,execution,overrides,force_session_model}`
- `conductor/.session-models.json` → session overlay (gitignored)
- `scripts/resolve-model.sh` → the resolver
