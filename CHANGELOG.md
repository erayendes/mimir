🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

#### Added
- Sentry crash and error monitoring (SDK 9.16.1) with breadcrumbs on every service refresh

#### Changed
- Menu bar icon updated to new Mimir/Viking design
- Icon pre-built at startup in two states (normal, low-quota); no disk I/O on 60s refresh ticks
- Low-quota indicator changed from red overlay to a red dot badge on the icon corner
- `--csrf_token` flag parsing now supports both space-separated and `=`-style formats

#### Fixed
- Menu bar icon was blurry on Retina displays due to `lockFocus` creating a 1× bitmap — replaced with deferred `NSImage` drawing handler that renders at native scale
- Icon was hard to see on dark menu bars — replaced with new high-contrast design
- `contentTintColor` now explicitly reset on each refresh to prevent stale tint state

### [1.1.0] - 2026-05-02

#### Added
- Live Codex usage fetching from the ChatGPT usage API using local Codex OAuth auth, with automatic token refresh
- Local Codex session JSONL parsing as a fallback when live usage data is unavailable

#### Changed
- Standardized quota display across all providers to show remaining percentage (`NN% left`)
- Reset countdown is now shown inline in the same row as the percentage

### [1.0.0] - 2026-04-01

#### Added
- Menu bar app with popover for Claude, Codex, Gemini, and Antigravity
- Claude session and weekly limit tracking via Claude Code OAuth (`~/.claude`)
- Codex premium credit and limit tracking from local session JSONL files
- Gemini Pro and Flash quota tracking via Google Cloud Quota API
- Antigravity model-level tracking via local language server and Cockpit integration
- Reset countdown timers for each service
- macOS light/dark mode support with monochrome menu bar icon
- Build and install script (`script/build_and_run.sh`)
- Automated DMG release pipeline via GitHub Actions

[Unreleased]: https://github.com/erayendes/mimir/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/erayendes/mimir/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/erayendes/mimir/releases/tag/v1.0.0

---

## Türkçe

Bu projedeki tüm önemli değişiklikler bu dosyada belgelenecektir.

Format [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) standardına,
sürümlendirme ise [Semantic Versioning](https://semver.org/spec/v2.0.0.html) kurallarına uygundur.

### [Yayımlanmadı]

#### Eklendi
- Sentry çökme ve hata izleme entegrasyonu (SDK 9.16.1); her servis yenilemesinde breadcrumb kaydı

#### Değişti
- Menü çubuğu ikonu yeni Mimir/Viking tasarımıyla güncellendi
- İkon uygulama açılışında iki durumda (normal, düşük-kota) önceden oluşturuldu; 60 saniyelik yenileme döngülerinde disk I/O yok
- Düşük-kota göstergesi kırmızı örtü yerine ikon köşesindeki kırmızı nokta rozetine dönüştürüldü
- `--csrf_token` bayrak ayrıştırması artık hem boşluklu hem `=` biçimini destekliyor

#### Düzeltildi
- `lockFocus` 1× bitmap oluşturduğundan Retina ekranlarda menü çubuğu ikonu bulanık görünüyordu — yerel ölçekte render eden ertelenmiş `NSImage` çizim işleyicisiyle değiştirildi
- Koyu menü çubuklarında ikon zor seçiliyordu — yüksek kontrastlı yeni tasarımla giderildi
- `contentTintColor` her yenilemede artık açıkça sıfırlanıyor, eski renk kirliliği engellendi

### [1.1.0] - 2026-05-02

#### Eklendi
- Yerel Codex OAuth kimlik doğrulaması kullanılarak ChatGPT kullanım API'sinden canlı Codex kullanım verisi çekme ve otomatik token yenileme
- Canlı veri alınamadığında yedek olarak yerel Codex oturum JSONL dosyası ayrıştırma

#### Değişti
- Tüm sağlayıcılarda kota gösterimi kalan yüzde olarak standartlaştırıldı (`%NN kaldı`)
- Yenileme geri sayımı artık yüzdeyle aynı satırda gösteriliyor

### [1.0.0] - 2026-04-01

#### Eklendi
- Claude, Codex, Gemini ve Antigravity için popover'lı menü çubuğu uygulaması
- Claude Code OAuth aracılığıyla Claude oturum ve haftalık limit takibi (`~/.claude`)
- Yerel oturum JSONL dosyalarından Codex premium kredi ve limit takibi
- Google Cloud Quota API ile Gemini Pro ve Flash kota takibi
- Yerel dil sunucusu ve Cockpit entegrasyonu ile Antigravity model bazlı takip
- Her servis için yenileme geri sayım sayacı
- Monokrom menü çubuğu ikonu ile macOS açık/koyu tema desteği
- Derleme ve kurulum scripti (`script/build_and_run.sh`)
- GitHub Actions üzerinden otomatik DMG release pipeline'ı

[Yayımlanmadı]: https://github.com/erayendes/mimir/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/erayendes/mimir/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/erayendes/mimir/releases/tag/v1.0.0
