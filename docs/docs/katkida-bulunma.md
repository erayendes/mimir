---
id: katkida-bulunma
title: Katkıda Bulunma
sidebar_label: Katkıda Bulunma
description: Mimir'i derleme, geliştirme akışı ve katkı kuralları.
---

# Katkıda Bulunma

Hata raporları ve pull request'ler memnuniyetle karşılanır. Büyük değişiklikler için önce bir [issue](https://github.com/erayendes/mimir/issues) açmanız rica olunur.

## Geliştirme ortamı

- **macOS 14.0+**, **Swift 6.0+** (Xcode 16)
- Swift Package Manager tabanlı proje (`Package.swift`)

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh        # derle + imzala + çalıştır
./script/build_and_run.sh logs   # log akışı ile çalıştır
```

## Proje yapısı (kısa)

| Dosya | Sorumluluk |
|---|---|
| `Sources/Mimir/MimirApp.swift` | Uygulama girişi, menü çubuğu, açılır pencere, ayarlar |
| `Sources/Mimir/PopoverViews.swift` | SwiftUI açılır pencere arayüzü |
| `Sources/Mimir/MimirModels.swift` | `ServiceStatus`, `ModelStatus`, zaman biçimleyici |
| `Sources/Mimir/LiveUsageDataSource.swift` | Veri toplama orkestrasyonu, snapshot/cooldown |
| `Sources/Mimir/ClaudeProvider.swift` | Claude OAuth kullanım sağlayıcısı |
| `Sources/Mimir/CodexProvider.swift` | Codex API + yerel JSONL sağlayıcısı |
| `Sources/Mimir/AntigravityProvider.swift` | Antigravity grup kotası sağlayıcısı |

## Test

Saf ayrıştırma/biçimleme yardımcıları için birim testleri vardır:

```bash
swift test
```

## Sürüm (release) akışı

Releaseler tamamen **GitHub Actions** üzerinde yapılır (`.github/workflows/release.yml`). Geliştiricinin yaptığı:

1. `CHANGELOG.md`'ye yeni sürüm bölümünü ekleyin — **hem `## English` hem `## Türkçe`** altında `### [X.Y]` başlığıyla.
2. Etiketleyip push'layın:

```bash
git tag vX.Y && git push && git push origin vX.Y
```

CI; derler → Developer ID ile imzalar → **notarize + staple** → dSYM'i Sentry'ye yükler → `Mimir.zip` paketler → Sparkle `edSignature` üretir → `appcast.xml`'i main'e commit'ler → GitHub release oluşturur.

:::warning
Üretilen artifact notarized'dır ve Gatekeeper'dan geçer. Kullanıcıya dağıtım için **her zaman CI yolunu** kullanın; yerel build yalnızca ad-hoc imzalıdır.
:::

## Lisans

[MIT](https://github.com/erayendes/mimir/blob/main/LICENSE) © Eray Endes
