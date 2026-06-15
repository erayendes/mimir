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

Sparkle private key `~/.config/mimir/sparkle_ed_private_key` dosyasından okunur
(`--ed-key-file`), böylece imzalama Keychain prompt'u olmadan non-interactive çalışır.
Dosya yoksa Keychain'e düşer. Tek seferlik export (normal terminalde):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/.config/mimir/sparkle_ed_private_key
```

Farklı bir konum için `SPARKLE_PRIVATE_KEY_FILE` ortam değişkenini ayarla.
