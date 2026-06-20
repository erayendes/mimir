# Reading the menu bar

> [Table of contents](README.md) · Previous: [← Installation](installation.md) · Next: [Services → Claude →](services/claude.md)

Mimir's entire UI lives in the menu bar: a small **Mimir glyph** and, next to it, a vertical **column of colored dots**.

![Mimir popover](../assets/popover.png)

## The colored dots

Each dot next to the glyph represents a service with a **5-hour session window**, ordered top to bottom:

1. **Claude**
2. **Codex**
3. **Antigravity** (has two group quotas — Gemini and Claude/GPT; the dot reflects the **most constrained** one)

> 📝 **Note:** A dot is shown only for services that currently have an **active session reading**. Services that aren't installed or have no current reading get **no** grey placeholder — so the number of dots matches the number of LLMs you actually use.

### Dot colors

The color is based on the **remaining percentage** in that service's 5-hour window:

| Color | Remaining | Meaning |
|:---:|---|---|
| 🟢 **Green** | 50% – 100% | Plenty left |
| 🟡 **Amber** | 15% – 49% | Running low, watch out |
| 🔴 **Red** | below 15% | Near the limit |

## The popover

Click the menu bar glyph to open the **popover**. Each service is shown as a **card**:

- **Service name and brand icon**
- **Session (5-hour) quota** — prominently, with percentage and countdown
- **Weekly quota** — a summary row when available
- **Model rows** — per-model quota or credit balance, depending on the service
- **(i) info icon** — explains where the data comes from and how to refresh it
- **Status note** — e.g. *"token expired — open Claude Code"*, telling you what to do

### Countdown format

Reset times use short units. In the English UI: **d** (days), **h** (hours), **m** (minutes). Example: `2h 15m` → resets in 2 hours 15 minutes.

## Refreshing

- Mimir refreshes data **automatically every minute**.
- Opening the popover also triggers a refresh.
- If a service hits a rate limit (HTTP 429), Mimir backs off (cooldown) and stops querying that service for a while, showing the **last-known data** meanwhile.

## The "stale" state

When a live source disappears (e.g. the Antigravity IDE closes), the service **does not vanish** — Mimir shows the card **dimmed** with the last snapshot. So instead of "the service suddenly disappeared", you keep seeing the latest info you had.

---

To learn how each service is fed individually → **[Services: Claude](services/claude.md)**.
