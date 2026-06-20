# Installation

> [Table of contents](README.md) · Next: [Reading the menu bar →](menu-bar.md)

## Requirements

- **macOS 14.0 (Sonoma)** or later
- To build from source: **Swift 6.0+** (ships with Xcode 16)

## Option 1 — Download a release (recommended)

1. Grab the latest `.dmg` from the [Releases](https://github.com/erayendes/mimir/releases) page.
2. Open the `.dmg` and drag **Mimir.app** into your **Applications** folder.
3. Launch Mimir — the Mimir icon appears in the menu bar.

> ℹ️ **Notarized** — Distributed releases are notarized by Apple, so you won't get a Gatekeeper warning. (Releases are signed and notarized entirely on CI.)

## Option 2 — Build from source

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

The `build_and_run.sh` script builds, signs, and runs the app.

| Command | What it does |
|---|---|
| `./script/build_and_run.sh` | Build + sign + run |
| `./script/build_and_run.sh logs` | Run with a log stream |
| `./script/build_and_run.sh install` | Build and install into Applications |

## First launch

On first launch, Mimir asks once for permission to **Launch at Login** so your usage is always in the menu bar.

> You can change this later under **System Settings › General › Login Items**.

For services to appear, you must have signed in to each AI tool at least once (Mimir reads the local data those tools create). See each service's page for details:

- [Claude](services/claude.md)
- [Codex](services/codex.md)
- [Antigravity](services/antigravity.md)

## Updating

Mimir updates itself via **Sparkle**. Use **Check for Updates** from the popover menu, or download the new `.dmg` from the Releases page.

---

Stuck on something? → [Support & FAQ](../../SUPPORT.md). Otherwise → **[Reading the menu bar](menu-bar.md)**.
