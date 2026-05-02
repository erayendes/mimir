# Changelog

## 2026-05-02

- Standardized Mimir's quota display around remaining percentage across providers.
- Updated the UI to show values as `NN% left` with the reset countdown in the same row.
- Added Codex live usage fetching from the ChatGPT usage API using local Codex OAuth auth, with token refresh support.
- Kept local Codex session JSONL parsing as a fallback when live usage data is unavailable.
