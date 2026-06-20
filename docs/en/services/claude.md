# Claude

> [Table of contents](../README.md) · Services: **Claude** · [Codex →](codex.md) · [Antigravity →](antigravity.md)

Mimir shows **Claude Code**'s usage limits: the session (5-hour) and weekly windows, with reset times.

## Data source

Mimir uses the **OAuth token** that Claude Code creates on your machine to query Anthropic's official usage endpoint:

```
GET https://api.anthropic.com/api/oauth/usage
```

- The token is read from Claude Code's records under `~/.claude` / the macOS **Keychain**.
- The response is **cached for 5 minutes**, so the Keychain (and its permission prompt) is touched only at launch and around token expiry.

## Token refresh

Anthropic rotates the **refresh token**. If the token is expired or within 5 minutes of expiry, Mimir refreshes it proactively and **writes the new pair back to the Keychain** — keeping Claude Code's own login valid too.

If the refresh fails, the card shows this note:

> **token expired — open Claude Code**

Just open Claude Code once and sign in; Mimir will fetch data again on the next refresh.

## What's shown

- **Session (5-hour) remaining percentage** and reset time
- **Weekly remaining percentage** and reset time
- The **Claude dot** in the menu bar is colored by the session percentage

## Common situations

| Symptom | Likely cause / fix |
|---|---|
| No Claude card | Claude Code may never have been signed in — open it once and sign in |
| "token expired" note | Open Claude Code; it resolves once the token refreshes |
| Frozen / dimmed data | Temporary error or rate limit; Mimir shows last-known data and refreshes shortly |

> 🔒 **Privacy:** Token and usage data are processed only on your machine; nothing is sent anywhere except Anthropic. See [Privacy & Security](../privacy.md).
