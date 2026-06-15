# Mimir

macOS menu bar app — Claude Code, Codex ve Antigravity için quota takibi.

## Geliştirme

```bash
./script/build_and_run.sh        # build + sign + çalıştır
./script/build_and_run.sh logs   # log stream ile çalıştır
```

## Release (CI üzerinden)

Releaseler tamamen GitHub Actions'ta yapılır (`.github/workflows/release.yml`).
Geliştiricinin yaptığı:

1. `CHANGELOG.md`'ye yeni sürüm bölümünü ekle — **hem `## English` hem `## Türkçe`
   altında** `### [X.Y]` başlığıyla (release notları buradan çekilir, EN sonra TR).
2. Tag at ve push'la:

```bash
git tag vX.Y && git push && git push origin vX.Y
```

CI şunları yapar: build → Developer ID imzala → **notarize + staple** → dSYM'i
Sentry'ye yükle → `Mimir.zip` paketle → Sparkle `edSignature` üret → `appcast.xml`'i
main'e commit'le → GitHub release oluştur. Artifact notarized'dır (Gatekeeper geçer).

Gerekli secret'lar: `DEVELOPER_ID_CERT(_PASSWORD)`, `NOTARIZATION_API_*`,
`SPARKLE_PRIVATE_KEY` (base64 ed25519), `SENTRY_AUTH_TOKEN`.

### Yerel build

`./script/release.sh <version>` `BUILD_ONLY=1` ile çağrılınca sadece imzasız bundle
+ dSYM üretir (CI'ın kullandığı mod). `BUILD_ONLY` olmadan tam yerel yayın yapar ama
artifact yalnızca ad-hoc imzalı olur (notarize edilmez) — kullanıcıya dağıtım için
CI yolunu kullan. Hızlı deneme için `./script/build_and_run.sh`.
