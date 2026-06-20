# Codex

> [Table of contents](../README.md) · Services: [Claude](claude.md) · **Codex** · [Antigravity →](antigravity.md)

Mimir shows session and weekly quotas for **Codex**, trying two sources in order.

## Data source

Mimir first queries the **live ChatGPT usage API**. If that fails, it falls back to Codex's local session records:

1. **ChatGPT usage API** (live) — primary source.
2. **Local `~/.codex/sessions` JSONL fallback** — if the API is unreachable.
3. If both fail, the **last-known snapshot**.

### How the local fallback is read

The **most recent `.jsonl` file** under `~/.codex/sessions` is scanned from the end backwards. From the `rate_limits` field of `token_count` events, Mimir extracts:

- **primary** → session (5-hour) window
- **secondary** → weekly window

and computes the remaining percentages and reset times.

> 📝 **Note:** If no reset time is found in the local file, the card still shows the remaining percentage, but the countdown may be omitted (the card notes this).

## What's shown

- **Session (5-hour) remaining percentage** and reset time
- **Weekly remaining percentage** and reset time
- When available, value rows such as a **credit balance** (for these non-percentage rows, Mimir triggers the low-quota badge when they fall below their threshold)

## Common situations

| Symptom | Likely cause / fix |
|---|---|
| No Codex card | No session records under `~/.codex` — use Codex once |
| No countdown | No reset time found in the local file; percentage is still shown |
| Stale data | The API may be unreachable; Mimir shows the local fallback or last snapshot |

> 🔒 **Privacy:** All reads are local. See [Privacy & Security](../privacy.md).
