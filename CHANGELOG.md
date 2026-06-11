🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

#### Added
- In-app update check ([#20](https://github.com/erayendes/mimir/issues/20)): on launch and once per day, Mimir queries the GitHub Releases API and shows an unobtrusive banner at the top of the popover when a newer version is available; tapping it opens the release page in the browser
- Antigravity quota snapshot: the last live reading is persisted to disk, so quota and reset time stay visible after the IDE/Cockpit closes — until each model's reset time passes, after which the card is marked "güncel değil" instead of showing stale numbers

#### Fixed
- Antigravity quota and reset time were not shown even with the IDE open — the `lsof` port lookup was missing the `-a` flag, so the `-iTCP`/`-p` filters were OR'd instead of AND'd, returning every listening port on the system; probing dozens of wrong ports blew the 8-second fetch timeout and produced no data. Added `-a` so only the language server's own ports are probed

### [1.2.2] - 2026-06-10

#### Fixed
- App crashed immediately on launch on macOS 26 (Tahoe) — `UNUserNotificationCenter.getNotificationSettings` callback was called on a background thread while Swift 6 strict concurrency treated the closure as `@MainActor`-isolated, causing `dispatch_assert_queue_fail` → `EXC_BREAKPOINT`; switched to the async `notificationSettings()` API which suspends and resumes correctly

### [1.2] - 2026-06-10

#### Fixed
- Antigravity language server detection was looking for `language_server_macos` but binary is `bin/language_server`
- Antigravity Cockpit cache files older than 6 hours are now skipped — stale cache was showing 100% quota after exhaustion
- Gemini model variants (Flash/Pro, all tiers) merged into a single "Gemini" entry for cleaner display
- Claude model variants and GPT-OSS merged into a single "Claude" entry
- Removed misused `startProfiler`/`stopProfiler` calls; Sentry now flushes properly on app terminate

### [1.1] - 2026-06-10

#### Changed
- Menu bar now uses dedicated `MenuIcon.png` instead of `AppIcon.png` for better visibility
- `AppIcon.png` updated to full-bleed design (no padding/border)

#### Fixed
- Menu bar icon invisible in light theme — `MenuIcon.png` is now a proper template image
- `NSAppearance.currentDrawing()` replaced with correct API for macOS 14+

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

[Unreleased]: https://github.com/erayendes/mimir/compare/v1.2.2...HEAD
[1.2.2]: https://github.com/erayendes/mimir/compare/v1.2...v1.2.2
[1.2]: https://github.com/erayendes/mimir/compare/v1.1...v1.2
[1.1]: https://github.com/erayendes/mimir/compare/v1.0...v1.1
[1.0]: https://github.com/erayendes/mimir/compare/v0.2...v1.0
[0.2]: https://github.com/erayendes/mimir/compare/v0.1...v0.2
[0.1]: https://github.com/erayendes/mimir/releases/tag/v0.1

---

## Türkçe

Bu projedeki tüm önemli değişiklikler bu dosyada belgelenecektir.

Format [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) standardına,
sürümlendirme ise [Semantic Versioning](https://semver.org/spec/v2.0.0.html) kurallarına uygundur.

### [Yayımlanmadı]

#### Eklendi
- Uygulama içi güncelleme kontrolü ([#20](https://github.com/erayendes/mimir/issues/20)): açılışta ve günde bir kez Mimir, GitHub Releases API'sini sorgular ve daha yeni bir sürüm varsa popover'ın üstünde göze batmayan bir banner gösterir; tıklandığında release sayfası tarayıcıda açılır
- Antigravity kota anlık görüntüsü: son canlı okuma diske kaydedilir, böylece IDE/Cockpit kapandıktan sonra da kota ve reset saati görünür kalır — her modelin reset saati geçene kadar; geçtikten sonra kart eski değer yerine "güncel değil" olarak işaretlenir

#### Düzeltildi
- IDE açık olmasına rağmen Antigravity kotası ve reset saati görünmüyordu — `lsof` port aramasında `-a` bayrağı eksikti, bu yüzden `-iTCP`/`-p` filtreleri AND yerine OR'lanıyor ve sistemdeki tüm dinleyen portlar dönüyordu; onlarca yanlış portu denemek 8 saniyelik zaman aşımını patlatıp veriyi boş bırakıyordu. `-a` eklenerek yalnızca dil sunucusunun kendi portları sorgulanıyor

### [1.2.2] - 2026-06-10

#### Düzeltildi
- macOS 26 (Tahoe) üzerinde uygulama açılışta çöküyordu — `UNUserNotificationCenter.getNotificationSettings` callback'i arka plan thread'inde çağrılıyordu; Swift 6 strict concurrency kapatmayı `@MainActor`-izole sayınca `dispatch_assert_queue_fail` → `EXC_BREAKPOINT` hatasına yol açıyordu; async `notificationSettings()` API'sine geçilerek düzeltildi

### [1.2] - 2026-06-10

#### Düzeltildi
- Antigravity dil sunucusu tespiti `language_server_macos` arıyordu; binary `bin/language_server` olarak düzeltildi
- 6 saatten eski Antigravity Cockpit cache dosyaları artık atlanıyor — eski cache kota bitmesine rağmen %100 gösteriyordu
- Gemini model varyantları (Flash/Pro, tüm katmanlar) tek "Gemini" girdisinde birleştirildi
- Claude model varyantları ve GPT-OSS tek "Claude" girdisinde birleştirildi
- Hatalı `startProfiler`/`stopProfiler` çağrıları kaldırıldı; Sentry uygulama kapanışında artık doğru flush yapıyor

### [1.1] - 2026-06-10

#### Değişti
- Menü çubuğu artık `AppIcon.png` yerine ayrı `MenuIcon.png` kullanıyor — daha iyi görünürlük
- `AppIcon.png` tam kenarlı tasarımla güncellendi (kenar boşluğu/çerçeve yok)

#### Düzeltildi
- Açık temada menü çubuğu ikonu görünmüyordu — `MenuIcon.png` artık doğru template image olarak işaretlendi
- macOS 14+ için `NSAppearance.currentDrawing()` yerine doğru API kullanıldı

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

[Yayımlanmadı]: https://github.com/erayendes/mimir/compare/v1.2.2...HEAD
[1.2.2]: https://github.com/erayendes/mimir/compare/v1.2...v1.2.2
[1.2]: https://github.com/erayendes/mimir/compare/v1.1...v1.2
[1.1]: https://github.com/erayendes/mimir/compare/v1.0...v1.1
[1.0]: https://github.com/erayendes/mimir/compare/v0.2...v1.0
[0.2]: https://github.com/erayendes/mimir/compare/v0.1...v0.2
[0.1]: https://github.com/erayendes/mimir/releases/tag/v0.1
