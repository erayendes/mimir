🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

### [1.0] - 2026-06-10

#### Added
- Sentry crash and error monitoring (SDK 9.16.1) with breadcrumbs on every service refresh
- Automated `.zip` release pipeline via GitHub Actions on `v*` tag push

#### Changed
- Menu bar icon updated to new Mimir/Viking design with RGBA transparent background
- Icon pre-built at startup in two states (normal, low-quota); no disk I/O on 60s refresh ticks
- Low-quota indicator changed from red overlay to a red dot badge on the icon corner
- `--csrf_token` flag parsing now supports both space-separated and `=`-style formats
- Status item switched from `variableLength` to `squareLength` to prevent invisible zero-width button on macOS Sequoia
- Antigravity OAuth credentials now read from local credentials file instead of being hardcoded

#### Fixed
- Menu bar icon failed to appear on macOS Sequoia when SF Symbol loading returned nil silently — replaced with `AppIcon.png` loaded via `Bundle.main`
- Icon rendered with a visible square background artifact — replaced AppIcon.png with RGBA version and added circular `NSBezierPath` clip
- Menu bar icon was blurry on Retina displays due to `lockFocus` creating a 1× bitmap — replaced with deferred `NSImage` drawing handler that renders at native scale
- `contentTintColor` now explicitly reset on each refresh to prevent stale tint state

#### Security
- Fixed command injection in Antigravity language server integration: `csrf_token` read from `ps` output was interpolated directly into a shell string passed to `/bin/zsh -lc`, allowing a malicious process to execute arbitrary commands; replaced with direct `Process` + argument array call to `curl`, bypassing the shell entirely
- PID parsed from `ps` output is now validated as `Int` before use in shell commands
- Removed hardcoded Google OAuth client credentials from source code

### [0.2] - 2026-05-02

#### Added
- Live Codex usage fetching from the ChatGPT usage API using local Codex OAuth auth, with automatic token refresh
- Local Codex session JSONL parsing as a fallback when live usage data is unavailable

#### Changed
- Standardized quota display across all providers to show remaining percentage (`NN% left`)
- Reset countdown is now shown inline in the same row as the percentage

### [0.1] - 2026-04-01

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

[Unreleased]: https://github.com/erayendes/mimir/compare/v1.0...HEAD
[1.0]: https://github.com/erayendes/mimir/compare/v0.2...v1.0
[0.2]: https://github.com/erayendes/mimir/compare/v0.1...v0.2
[0.1]: https://github.com/erayendes/mimir/releases/tag/v0.1

---

## Türkçe

Bu projedeki tüm önemli değişiklikler bu dosyada belgelenecektir.

Format [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) standardına,
sürümlendirme ise [Semantic Versioning](https://semver.org/spec/v2.0.0.html) kurallarına uygundur.

### [Yayımlanmadı]

### [1.0] - 2026-06-10

#### Eklendi
- Sentry çökme ve hata izleme entegrasyonu (SDK 9.16.1); her servis yenilemesinde breadcrumb kaydı
- `v*` tag push'uyla GitHub Actions üzerinden otomatik `.zip` release pipeline'ı

#### Değişti
- Menü çubuğu ikonu RGBA saydam arka planlı yeni Mimir/Viking tasarımıyla güncellendi
- İkon uygulama açılışında iki durumda (normal, düşük-kota) önceden oluşturuldu; 60 saniyelik yenileme döngülerinde disk I/O yok
- Düşük-kota göstergesi kırmızı örtü yerine ikon köşesindeki kırmızı nokta rozetine dönüştürüldü
- `--csrf_token` bayrak ayrıştırması artık hem boşluklu hem `=` biçimini destekliyor
- macOS Sequoia'da sıfır genişlikli görünmez butonu önlemek için status item `variableLength` yerine `squareLength` olarak değiştirildi
- Antigravity OAuth kimlik bilgileri artık kaynak kodda sabit değil, yerel credentials dosyasından okunuyor

#### Düzeltildi
- macOS Sequoia'da SF Symbol yüklemesi sessizce nil döndürdüğünde menü çubuğu ikonu görünmüyordu — `Bundle.main` üzerinden `AppIcon.png` yüklenerek giderildi
- İkon görünür kare arka planla render ediliyordu — AppIcon.png RGBA sürümüyle değiştirildi ve dairesel `NSBezierPath` kırpması eklendi
- `lockFocus` 1× bitmap oluşturduğundan Retina ekranlarda menü çubuğu ikonu bulanık görünüyordu — yerel ölçekte render eden ertelenmiş `NSImage` çizim işleyicisiyle değiştirildi
- `contentTintColor` her yenilemede artık açıkça sıfırlanıyor, eski renk kirliliği engellendi

#### Güvenlik
- Antigravity dil sunucusu entegrasyonundaki komut enjeksiyonu açığı giderildi: `ps` çıktısından okunan `csrf_token` doğrudan `/bin/zsh -lc` shell dizgisine ekleniyor ve keyfi komut çalıştırmaya izin veriyordu; `runShell` yerine argümanları dizi olarak geçen doğrudan `Process` + `curl` çağrısı kullanıldı, shell devreye girmiyor
- `ps` çıktısından alınan PID, shell komutlarında kullanılmadan önce `Int` olarak doğrulanıyor
- Kaynak koddan hardcoded Google OAuth client credentials kaldırıldı

### [0.2] - 2026-05-02

#### Eklendi
- Yerel Codex OAuth kimlik doğrulaması kullanılarak ChatGPT kullanım API'sinden canlı Codex kullanım verisi çekme ve otomatik token yenileme
- Canlı veri alınamadığında yedek olarak yerel Codex oturum JSONL dosyası ayrıştırma

#### Değişti
- Tüm sağlayıcılarda kota gösterimi kalan yüzde olarak standartlaştırıldı (`%NN kaldı`)
- Yenileme geri sayımı artık yüzdeyle aynı satırda gösteriliyor

### [0.1] - 2026-04-01

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

[Yayımlanmadı]: https://github.com/erayendes/mimir/compare/v1.0...HEAD
[1.0]: https://github.com/erayendes/mimir/compare/v0.2...v1.0
[0.2]: https://github.com/erayendes/mimir/compare/v0.1...v0.2
[0.1]: https://github.com/erayendes/mimir/releases/tag/v0.1
