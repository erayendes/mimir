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

Sparkle private key kalıcı olarak diskte tutulmaz. `release.sh` imzalama anında
key'i Keychain'den geçici bir dizine (`$TMPDIR`, cloud-sync edilmez) export eder,
`--ed-key-file` ile imzalar ve hemen siler. Keychain erişimi `generate_keys` için
zaten yetkili olduğundan prompt çıkmaz. Key yalnızca Keychain'de yaşar.

CI veya harici key yönetimi için: `SPARKLE_PRIVATE_KEY_FILE` ortam değişkenini bir
key dosyasına ayarla — bu durumda export yapılmaz, dosya olduğu gibi kullanılır
(silinmez).
