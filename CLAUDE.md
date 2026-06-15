# Mimir

macOS menu bar app — Claude Code, Codex ve Antigravity için quota takibi.

## Geliştirme

```bash
./script/build_and_run.sh        # build + sign + çalıştır
./script/build_and_run.sh logs   # log stream ile çalıştır
```

## Release

```bash
./script/release.sh <version> "<notes>"
```

Tek komut: build → sign → zip → edSignature → appcast güncelle → GitHub release → push.

Örnek: `./script/release.sh 1.8 "Added Gemini support"`

Sparkle private key macOS Keychain'de saklanıyor, otomatik okunur.
