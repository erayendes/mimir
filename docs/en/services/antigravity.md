# Antigravity

> [Table of contents](../README.md) · Services: [Claude](claude.md) · [Codex](codex.md) · **Antigravity**

Mimir shows group-based quotas for **Antigravity**. Antigravity no longer manages quota per-model but through **shared group pools**:

- **Gemini** group
- **Claude + GPT** group

Each group has a **weekly** and a **5-hour** window.

## Data source

Mimir tries the following sources in order and uses the first that succeeds:

1. **Group quota summary** — the grouped weekly + 5-hour summary that backs the IDE's "Model Quota" page (primary live source).
2. **Cloud Code authorized API** — a `fetchAvailableModels` call with your Cockpit account's token.
3. **Cockpit cache** — the last authorized data stored locally.
4. **Local language server** data.
5. **Last snapshot** — when the IDE/Cockpit is closed, valid until its reset time passes.

## The menu bar dot

Since Antigravity has **two session groups** (Gemini, Claude/GPT), the single Antigravity dot in the menu bar shows the color of the **most constrained** group. So "whichever is closest to its limit" is visible at a glance.

## When the live source closes

When the Antigravity IDE or Cockpit is closed, live data can't be fetched. In that case:

- Mimir shows the **last snapshot** it captured while one was open (until its reset time passes).
- If there is no account info at all, the card shows this note:

  > **open Antigravity or Cockpit**

## Common situations

| Symptom | Likely cause / fix |
|---|---|
| "open Antigravity or Cockpit" note | Account info couldn't be read — open the IDE or Cockpit |
| Data looks dimmed | The IDE/Cockpit closed; the last snapshot is being shown |
| Quotas differ from expected | Antigravity uses group-pool logic; read by group, not per-model |

> 🔒 **Privacy:** Token exchange and reads are local / against authorized endpoints; your personal data is not sent to third parties. See [Privacy & Security](../privacy.md).
