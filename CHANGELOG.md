🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

### [1.13] - 2026-06-17

#### Added
- Turkish localization: Mimir now displays in Turkish when macOS is set to Turkish, and in English otherwise — chosen automatically from the system language.

#### Changed
- Usage rows now lead with the remaining time; the reset clock moved to a secondary spot, and weekly windows show just the countdown. Claude's Sonnet weekly window is now always shown.

### [1.12] - 2026-06-16

#### Changed
- Crash reporting no longer flags normal dialogs (the update sheet or the login prompt) as "app not responding".

### [1.11] - 2026-06-15

#### Added
- First launch now offers to open Mimir automatically at login (toggleable later in System Settings › Login Items).

#### Fixed
- Security: OAuth credentials and the Antigravity language-server token are no longer passed as command-line arguments, so other local processes can't read them from the process table.
- The Antigravity info text and status labels are now in English, matching the rest of the app.

### [1.10] - 2026-06-15

#### Fixed
- Release builds are now Developer ID-signed and notarized by Apple, so macOS opens them without Gatekeeper warnings and Sparkle auto-updates install cleanly.

### [1.9] - 2026-06-15

#### Added
- Sparkle auto-update integration: "Check for updates" now uses the native Sparkle sheet instead of a browser redirect. The button moved from a separate line to an inline refresh icon next to the version number in the branding footer.

#### Changed
- Branding footer: "milowda" byline is now a clickable link to milowda.com/apps/mimir.

### [1.7] - 2026-06-15

#### Added
- Credit & billing tracking ([#8](https://github.com/erayendes/mimir/issues/8), [#9](https://github.com/erayendes/mimir/issues/9), [#10](https://github.com/erayendes/mimir/issues/10)): each service card now surfaces its financial layer when there is one — Antigravity shows the Google One AI credit balance, Codex shows the premium credit balance, and Claude shows pay-as-you-go billing usage (spent / monthly limit). All of it is read from data the existing integrations already fetch (no extra login), the row is omitted for accounts without credits/billing, and the menu-bar low badge also lights when a balance is below its threshold. (Antigravity credit expiry/activity and a dedicated Gemini quota card, [#11](https://github.com/erayendes/mimir/issues/11), are deferred — no reachable data source yet.)

### [1.6] - 2026-06-15

#### Added
- Mimir now refreshes Claude's OAuth token itself, the same way it already does for Codex and Antigravity. When the token is expired or within 5 minutes of expiry, it exchanges the stored refresh token for a fresh one and writes the rotated pair back to where it came from (the keychain entry, updated in place, or `~/.claude/.credentials.json`). So Claude usage stays live and correct without depending on Claude Code to refresh first — and because the new token is written back, Claude Code's own login keeps working. On refresh failure it falls back to last-known data and backs off rather than hammering the token endpoint

#### Fixed
- Claude could show a stale reading (or none at all) when its token wasn't being refreshed — e.g. a 5-hour window that had already reset shown as if current. Card data is now trusted by reset time rather than cache age (a window still within its reset shows; one that has reset is blanked), and the last-known reading is persisted, so the card stays correct and never silently vanishes
- App-hang reports on quit: the terminate-time Sentry flush blocked the main thread for up to 2s, tripping Sentry's own 2000 ms app-hang detector (MIMIR-4). The flush timeout is now 1s, safely under the threshold

### [1.5] - 2026-06-14

#### Changed
- Quota notifications reworked around the 5-hour and weekly windows. Live Claude/Codex warn once when the 5h window drops below 20% or the weekly window below 10%; the 5h "refilled" notice fires only after the window fully drains to 0% and resets to 100%, while the weekly "refilled" fires on every reset. Per-model rows no longer notify, and messages are now English with the live percentage and reset countdown
- Antigravity notifications limited to a single reliable event — its weekly refill. Usage/low and 5h alerts are dropped because Antigravity data is only live while the IDE is open; but the weekly reset time is deterministic and the quota can't be spent while the IDE is closed, so "weekly quota refilled" fires exactly when that time passes, even with the IDE closed and even if the quota was never touched

#### Fixed
- A service card could silently vanish on a transient failure. The last-known snapshot pattern (previously Antigravity-only) now covers Claude and Codex too: each service's last live reading is persisted and, when a live fetch fails, shown instead of hidden — fresh windows live-from-cache, reset-passed windows blanked, all-stale as a dimmed "güncel değil" card. Only a service that has never once produced a reading is hidden
- Claude no longer hammers the usage API with a dead token. Mimir reads the token's `expiresAt` and, if it has already expired, skips the API call entirely (this was what escalated to HTTP 429), showing last-known data with a "token expired — open Claude Code" note. Mimir stays read-only — it never refreshes Claude's token (which could rotate Claude Code's own credentials out from under it); live data returns automatically once Claude Code refreshes the keychain
- Added per-service fetch backoff: after an HTTP 429 (honoring `Retry-After`) or an expired token, Mimir parks that service from network polling for a cooldown and serves it from the snapshot, clearing the cooldown on the next live success

### [1.4] - 2026-06-12

#### Changed
- Antigravity now reflects its new grouped quota model. Antigravity moved quota off per-model limits and onto shared group buckets — a **Gemini** group and a **Claude + GPT** group, each with a weekly and a 5-hour window — exposed via the new `RetrieveUserQuotaSummary` language-server RPC. The card now shows four rows (Gemini · 5h, Gemini · Weekly, Claude/GPT · 5h, Claude/GPT · Weekly) sourced from that endpoint, instead of one row per model family from the old per-model `GetUserStatus` (which only ever carried the 5-hour window)

#### Fixed
- Popover height was locked at its 500pt maximum even when fewer cards were shown (e.g. only Codex running), leaving a large empty area below the branding footer. SwiftUI preference updates were being silently dropped inside the `TimelineView`/`ScrollView` hierarchy, so the height listener never saw the measured value. The popover is now sized directly from the measured content, so it shrinks and grows live as services appear, disappear, or expand their info panel

### [1.3] - 2026-06-10

#### Added
- In-app update check ([#20](https://github.com/erayendes/mimir/issues/20)): on launch and once per day, Mimir queries the GitHub Releases API and shows an unobtrusive banner at the top of the popover when a newer version is available; tapping it opens the release page in the browser
- Antigravity quota snapshot: the last live reading is persisted to disk, so quota and reset time stay visible after the IDE/Cockpit closes — until each model's reset time passes, after which the card is marked "güncel değil" instead of showing stale numbers

#### Changed
- Popover empty state ([#18](https://github.com/erayendes/mimir/issues/18)): services with no data are no longer rendered as meaningless "0%" rows; when nothing is running, a centred placeholder is shown, and a spinner appears while refreshing. A stale Antigravity snapshot ("güncel değil") is kept visible (dimmed) rather than hidden, so a closed IDE doesn't make the card silently vanish
- Antigravity card now has an (i) info icon explaining that quota is read from the local language server and that Antigravity must be open to refresh the data (last-seen values are shown while it's closed)

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

[Unreleased]: https://github.com/erayendes/mimir/compare/v1.8...HEAD
[1.8]: https://github.com/erayendes/mimir/compare/v1.7...v1.8
[1.7]: https://github.com/erayendes/mimir/compare/v1.6...v1.7
[1.6]: https://github.com/erayendes/mimir/compare/v1.5...v1.6
[1.5]: https://github.com/erayendes/mimir/compare/v1.4...v1.5
[1.4]: https://github.com/erayendes/mimir/compare/v1.3...v1.4
[1.3]: https://github.com/erayendes/mimir/compare/v1.2.2...v1.3
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

### [1.13] - 2026-06-17

#### Eklendi
- Türkçe dil desteği: macOS Türkçe olduğunda Mimir Türkçe, değilse İngilizce görünür — sistem dilinden otomatik seçilir.

#### Değişti
- Kullanım satırları artık önce kalan süreyi gösteriyor; sıfırlanma saati ikincil konuma alındı ve haftalık pencereler yalnızca geri sayımı gösteriyor. Claude'un Sonnet haftalık penceresi artık her zaman görünüyor.

### [1.12] - 2026-06-16

#### Değişti
- Hata raporlama, normal dialog'ları (güncelleme penceresi veya giriş sorusu) artık "uygulama yanıt vermiyor" olarak işaretlemiyor.

### [1.11] - 2026-06-15

#### Eklendi
- İlk açılışta Mimir'i girişte otomatik başlatma seçeneği sunuluyor (sonradan System Settings › Login Items'tan değiştirilebilir).

#### Düzeltildi
- Güvenlik: OAuth kimlik bilgileri ve Antigravity dil-sunucusu token'ı artık komut satırı argümanı olarak geçirilmiyor; böylece sistemdeki başka süreçler bunları process table'dan okuyamıyor.
- Antigravity bilgi metni ve durum etiketleri artık İngilizce (uygulamanın geri kalanıyla uyumlu).

### [1.10] - 2026-06-15

#### Düzeltildi
- Release derlemeleri artık Developer ID ile imzalanıp Apple tarafından notarize ediliyor; macOS Gatekeeper uyarısı vermeden açıyor ve Sparkle otomatik güncellemeleri sorunsuz kuruluyor.

### [1.9] - 2026-06-15

#### Eklendi
- Sparkle otomatik güncelleme entegrasyonu: "Check for updates" artık tarayıcıya yönlendirmek yerine native Sparkle sheet'ini açıyor. Buton, branding footer'da ayrı bir satırdan versiyon numarasının yanındaki inline yenile ikonuna taşındı.

#### Değişti
- Branding footer: "milowda" yazısı milowda.com/apps/mimir'e tıklanabilir link oldu.

### [1.7] - 2026-06-15

#### Eklendi
- Kredi & fatura takibi ([#8](https://github.com/erayendes/mimir/issues/8), [#9](https://github.com/erayendes/mimir/issues/9), [#10](https://github.com/erayendes/mimir/issues/10)): her servis kartı, varsa finansal katmanını da gösteriyor — Antigravity Google One AI kredi bakiyesini, Codex premium kredi bakiyesini, Claude ise kullandıkça-öde fatura kullanımını (harcanan / aylık limit). Hepsi mevcut entegrasyonların zaten çektiği veriden okunuyor (ek giriş yok); kredi/fatura olmayan hesaplarda satır gizleniyor ve menü çubuğu düşük rozeti bakiye eşiğin altına düşünce de yanıyor. (Antigravity kredi son-kullanma/aktivitesi ve ayrı bir Gemini kota kartı, [#11](https://github.com/erayendes/mimir/issues/11), erişilebilir kaynak olmadığı için ertelendi.)

### [1.6] - 2026-06-15

#### Eklendi
- Mimir artık Claude'un OAuth token'ını da kendi yeniliyor — tıpkı Codex ve Antigravity'de yaptığı gibi. Token dolmuşsa ya da dolmasına 5 dakikadan az kalmışsa, saklı refresh token'ı yenisiyle değişip rotate edilen çifti geldiği yere geri yazıyor (keychain girdisi yerinde güncelleniyor, ya da `~/.claude/.credentials.json`). Böylece Claude kullanımı, Claude Code'un önce tazelemesine bağlı kalmadan canlı ve doğru kalıyor; yeni token geri yazıldığı için Claude Code'un kendi girişi de bozulmuyor. Refresh başarısız olursa son-bilinen veriye düşüp token endpoint'ini dövmek yerine geri çekiliyor

#### Düzeltildi
- Token tazelenmediğinde Claude bayat (ya da hiç) değer gösterebiliyordu — örn. çoktan resetlenmiş 5 saatlik pencere güncelmiş gibi. Kart verisi artık cache yaşına değil reset zamanına göre güveniliyor (reseti gelmemiş pencere gösteriliyor, resetlenmiş pencere boşaltılıyor) ve son-bilinen okuma saklanıyor; böylece kart doğru kalıyor ve asla sessizce kaybolmuyor
- Çıkışta app-hang raporu: kapanış anındaki Sentry flush'ı ana thread'i 2 saniyeye kadar bloke edip Sentry'nin kendi 2000 ms app-hang dedektörünü tetikliyordu (MIMIR-4). Flush timeout'u artık 1 saniye, eşiğin güvenle altında

### [1.5] - 2026-06-14

#### Değişti
- Kota bildirimleri 5 saatlik ve haftalık pencereler etrafında yeniden kurgulandı. Canlı Claude/Codex, 5h penceresi %20'nin veya haftalık pencere %10'un altına düşünce bir kez uyarıyor; 5h "yenilendi" bildirimi yalnızca pencere tamamen %0'a inip %100'e dönünce, haftalık "yenilendi" ise her reset'te geliyor. Model bazlı satırlar artık bildirim üretmiyor ve mesajlar canlı yüzde + reset geri sayımıyla İngilizce
- Antigravity bildirimleri tek güvenilir olaya indirildi — haftalık yenilenme. Kullanım/düşük ve 5h uyarıları kaldırıldı çünkü Antigravity verisi yalnızca IDE açıkken canlı; ama haftalık reset zamanı deterministik ve IDE kapalıyken kota harcanamadığı için "haftalık kota yenilendi", o zaman geldiğinde IDE kapalı olsa ve kota hiç kullanılmamış olsa bile gönderiliyor

#### Düzeltildi
- Bir servis kartı geçici bir hatada sessizce kaybolabiliyordu. Son-bilinen snapshot deseni (önceden yalnızca Antigravity'de) artık Claude ve Codex'i de kapsıyor: her servisin son canlı okuması diske kaydediliyor ve canlı çekim başarısız olunca gizlenmek yerine gösteriliyor — taze pencereler cache'ten canlı, reseti geçmiş pencereler boş, hepsi bayatsa soluk "güncel değil" kartı. Yalnızca hiç okuma üretmemiş bir servis gizleniyor
- Claude artık ölü token'la usage API'sini dövmüyor. Mimir token'ın `expiresAt`'ini okuyor ve süresi dolmuşsa API çağrısını hiç yapmıyor (429'a tırmanan şey buydu); son-bilinen veriyi "token expired — open Claude Code" notuyla gösteriyor. Mimir read-only kalıyor — Claude token'ını asla yenilemiyor (Claude Code'un kendi kimlik bilgilerini rotate edebilir); Claude Code keychain'i tazeleyince canlı veri otomatik dönüyor
- Servis-bazlı çekim backoff'u eklendi: bir HTTP 429'dan (`Retry-After`'a uyarak) ya da süresi dolmuş token'dan sonra Mimir o servisi bir cooldown boyunca ağ taramasından alıkoyup snapshot'tan besliyor; sonraki canlı başarıda cooldown temizleniyor

### [1.4] - 2026-06-12

#### Değişti
- Antigravity, yeni gruplu kota modeline uyarlandı. Antigravity kotayı model bazlı limitlerden çıkarıp paylaşılan grup kovalarına taşıdı — bir **Gemini** grubu ve bir **Claude + GPT** grubu, her birinde haftalık ve 5 saatlik birer pencere — bunlar yeni `RetrieveUserQuotaSummary` dil-sunucusu RPC'sinden geliyor. Kart artık model ailesi başına tek satır yerine bu endpoint'ten dört satır gösteriyor (Gemini · 5h, Gemini · Weekly, Claude/GPT · 5h, Claude/GPT · Weekly); eski model-bazlı `GetUserStatus` yalnızca 5 saatlik pencereyi taşıyordu

#### Düzeltildi
- Popover yüksekliği, daha az kart gösterildiğinde bile (örn. yalnızca Codex çalışırken) 500pt'lik üst sınırında sabit kalıyor ve branding footer'ın altında büyük bir boşluk bırakıyordu. SwiftUI preference güncellemeleri `TimelineView`/`ScrollView` hiyerarşisi içinde sessizce düşüyor, bu yüzden yükseklik dinleyicisi ölçülen değeri hiç görmüyordu. Popover artık doğrudan ölçülen içeriğe göre boyutlanıyor; böylece servisler göründükçe, kayboldukça veya bilgi panelini açtıkça canlı olarak küçülüp büyüyor

### [1.3] - 2026-06-10

#### Eklendi
- Uygulama içi güncelleme kontrolü ([#20](https://github.com/erayendes/mimir/issues/20)): açılışta ve günde bir kez Mimir, GitHub Releases API'sini sorgular ve daha yeni bir sürüm varsa popover'ın üstünde göze batmayan bir banner gösterir; tıklandığında release sayfası tarayıcıda açılır
- Antigravity kota anlık görüntüsü: son canlı okuma diske kaydedilir, böylece IDE/Cockpit kapandıktan sonra da kota ve reset saati görünür kalır — her modelin reset saati geçene kadar; geçtikten sonra kart eski değer yerine "güncel değil" olarak işaretlenir

#### Değişti
- Popover boş durumu ([#18](https://github.com/erayendes/mimir/issues/18)): verisi olmayan servisler artık anlamsız "%0" satırları olarak gösterilmiyor; hiçbir şey çalışmıyorsa ortalanmış bir placeholder, yenileme sırasında bir spinner gösteriliyor. Eski Antigravity anlık görüntüsü ("güncel değil") gizlenmek yerine soluk şekilde görünür kalıyor — böylece kapalı bir IDE kartın sessizce kaybolmasına yol açmıyor
- Antigravity kartına, kotanın yerel dil sunucusundan okunduğunu ve verinin güncellenmesi için Antigravity'nin açık olması gerektiğini (kapalıyken son görülen değerlerin gösterildiğini) açıklayan bir (i) bilgi ikonu eklendi

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

[Yayımlanmadı]: https://github.com/erayendes/mimir/compare/v1.8...HEAD
[1.8]: https://github.com/erayendes/mimir/compare/v1.7...v1.8
[1.7]: https://github.com/erayendes/mimir/compare/v1.6...v1.7
[1.6]: https://github.com/erayendes/mimir/compare/v1.5...v1.6
[1.5]: https://github.com/erayendes/mimir/compare/v1.4...v1.5
[1.4]: https://github.com/erayendes/mimir/compare/v1.3...v1.4
[1.3]: https://github.com/erayendes/mimir/compare/v1.2.2...v1.3
[1.2.2]: https://github.com/erayendes/mimir/compare/v1.2...v1.2.2
[1.2]: https://github.com/erayendes/mimir/compare/v1.1...v1.2
[1.1]: https://github.com/erayendes/mimir/compare/v1.0...v1.1
[1.0]: https://github.com/erayendes/mimir/compare/v0.2...v1.0
[0.2]: https://github.com/erayendes/mimir/compare/v0.1...v0.2
[0.1]: https://github.com/erayendes/mimir/releases/tag/v0.1
