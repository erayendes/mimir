🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [Unreleased]

### [2.5.1] - 2026-06-25

#### Added
- New "data unavailable" cue: when a provider's live source can't be reached — for example Antigravity is closed — the widgets, panel, and menu-bar dots now say so clearly and offer to open the app (tap the widget, or the notice in the panel), instead of showing stale numbers or a vanished card. It only appears for apps you actually have installed.

### [2.5] - 2026-06-24

#### Added
- Menu-bar dots now grey out when a model's weekly (7g) quota is spent — matching the widgets and panel, so a full 5-hour session can't read as usable while the week is locked.

#### Changed
- Small widget: the percentage is a touch smaller and sits closer to its bar.
- Claude usage refreshes on its own again, so it stays current between opens (the previous read-only mode could leave Claude data stale on some setups).

#### Fixed
- Claude's 5-hour usage no longer briefly disappears right after its window resets — the live reading is trusted even while the API still reports the just-passed reset time.

### [2.4] - 2026-06-24

#### Added
- A model whose weekly (7g) quota is spent now reads as greyed-out/passive (widget and panel), so a full 5-hour limit can't masquerade as usable while the week is locked.
- Dedicated colour band for the weekly (7g) quota: green ≥50%, amber 10–50%, red below 10% (the 5-hour window keeps its 15% threshold).

#### Changed
- Small widget refresh: larger percentage, slimmer % sign, and the "5s" badge moved back into the header.
- Claude's 5-hour reset now also shows in the widget (falling back to the 5-hour window length when the provider omits it).
- Quota low/refill notifications reworded; messages now include the reset time and remaining duration.

#### Fixed
- Fixed Claude Code login being knocked out. To read Claude usage, Mimir was refreshing Claude Code's OAuth token; that token is single-use and shared with Claude Code, so Mimir's refresh could invalidate Claude Code's copy and drop its session. Mimir now accesses the Claude token read-only — it never refreshes it or writes to the keychain or file. When the token expires it shows the last-known values, and updates automatically once Claude Code refreshes its own token.
- Fixed the percent sign rendering incorrectly in notification text (e.g. "%%100").

### [2.3] - 2026-06-22

**Mimir, beyond the menu bar.**

Why open anything at all?
Not anymore! With Mimir 2.3, your quotas live right on your desktop.

Pick from two widgets — a single bold number or a tidy list of every 5-hour limit. Every percentage and bar glows with its status: green, amber, red. Tell the small one exactly which model to watch. Light mode, dark mode — flawless in both.

The whole picture, without lifting a finger. 😊

> "I put it on my desktop and now I stare at it all day. Am I working or watching quotas? Unclear."
> — **Kenan**, a very close friend of Eray's

> "Updated purely to see the widgets."
> — **Tayfun**, who still owes Eray ₺400

> "Claude was at 9% when I added the widget. I panicked — then thought, what an elegant panic."
> — **Selin**, a LinkedIn connection (they've never met)

> "Completely unbiased: the best widgets in the world."
> — anonymous, **Eray's mother**

> "I get to choose which model it shows? Say no more."
> — **Burak**, who needs something from Eray

#### Added
- macOS desktop widgets, in **two sizes**: a single big number (Small) and a compact list of every 5-hour limit (Medium). Each percentage and bar is coloured by how much you have left — green at 50% or above, amber between 15–50%, red below 15%.
- The Small widget is configurable: long-press → Edit Widget to choose exactly which model it shows. It defaults to whichever is closest to running out.
- Widgets follow the system appearance, in both light and dark mode.
- Right-click the menu-bar icon: toggle anonymous statistics, check for updates, quit Mimir.
- **Anonymous, privacy-first usage statistics**: only categorical info like which providers and widgets you use — your quotas, credits, account, and personal data are never sent. Turn it off anytime from the right-click menu.

### [2.2.2] - 2026-06-22

#### Changed
- The menu-bar dots now show one dot per 5-hour limit instead of one per service, so Antigravity's Gemini and Claude/GPT each get their own dot — you can tell at a glance that one is full while the other is spent. The dots arrange into a compact grid (a 2×2 when there are four).
- The menu-bar icon is a touch larger, filling the full height of the menu bar.

### [2.2.1] - 2026-06-21

#### Fixed
- The menu-bar status dots are back in the same order as the panel (Claude, Codex, Antigravity, top to bottom), so a dot's colour always lines up with the right service. A 2.2 regression could show, for example, a yellow Antigravity dot at the top while its card sat at the bottom of the panel.

### [2.2] - 2026-06-21

#### Fixed
- The menu-bar dots now always match the panel. Every service you're tracking keeps its dot, and a dot turns grey while its 5-hour reading is briefly missing — for example right after the window resets — instead of disappearing. So you'll never again see three services in the panel but only two dots.
- Mimir no longer pops the macOS keychain permission prompt in the background. It reads your Claude login from the credentials file or its own securely cached token, and only reaches for Claude Code's keychain item when you open Mimir yourself — so glancing at Codex or Antigravity never triggers a Claude prompt.

#### Changed
- The menu-bar dots are ordered to match the panel top to bottom, and the grey "no data yet" dot stays legible on both the light and dark menu bar.

### [2.1] - 2026-06-19

#### Fixed
- The macOS keychain no longer keeps asking for permission to read your Claude Code login. Mimir now keeps the token in memory and reads the keychain only at launch and around token expiry, instead of every few minutes.
- The menu-bar icon shows one status dot per service you actually use — no more grey placeholder dots when you track only one or two of Claude, Codex, and Antigravity.

### [2.0] - 2026-06-19

**The best Mimir there has ever been.**

Can a menu bar app really be this beautiful? With Mimir 2.0, yes.

We took everything you love and redesigned it from scratch: the session up front, colours that come alive with status, weekly limits clean and clear — all in a single frosted-glass panel. Flawless in light mode and dark.

The same Mimir; just better in every way. 😊

> "When I first opened it I said 'wow.' My wife heard me, looked, and said 'wow' too."
> — **Kenan**, a very close friend of Eray's

> "There's a light mode now, so I use it during the day too."
> — **Tayfun**, who owes Eray ₺400

> "My quota dropped into the red, the dot lit up, my heart broke — but the design is just so beautiful."
> — **Selin**, a LinkedIn connection (they've never met)

> "I'm completely unbiased: the best app in the world."
> — anonymous, **Eray's mother**

> "Everything in a single panel. I can't imagine anything better."
> — **Burak**, who needs something from Eray

#### Changed
- Redesigned popover. Each service now leads with its 5-hour session as a prominent row — name, a big percentage, and a thin progress bar — with the reset countdown and reset time beneath it. Weekly limits sit below as compact rows, each with a status dot, and any purchased usage credit is shown at the bottom. Antigravity lists its Gemini and Claude/GPT sessions separately.
- Quota level is now colour-coded everywhere (bar, percentage, and weekly dots): green at 50% or above, amber between 15–50%, red below 15%.
- The popover grows to show everything at once — no more inner scrolling — and the whole panel is now real glass: the desktop and windows behind it read through, gently blurred.

#### Added
- Light mode: the popover now follows the system appearance (light or dark).
- The version badge in the footer checks for updates when you click it; hovering it or the milowda link shows the pointer cursor.
- A column of three status dots next to the menu-bar icon shows the 5-hour status of Claude, Codex, and Antigravity at a glance (top to bottom) — green, amber, or red. Built for my brother İlker Utlu ([sigortadanismani.com](https://sigortadanismani.com)).

#### Fixed
- The macOS keychain no longer keeps asking for permission to read your Claude Code login. Mimir now reads it in-process instead of through the `security` command-line tool, so "Always Allow" sticks.

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

[Unreleased]: https://github.com/erayendes/mimir/compare/v2.1...HEAD
[2.1]: https://github.com/erayendes/mimir/compare/v2.0...v2.1
[2.0]: https://github.com/erayendes/mimir/compare/v1.13...v2.0
[1.13]: https://github.com/erayendes/mimir/compare/v1.12...v1.13
[1.12]: https://github.com/erayendes/mimir/compare/v1.11...v1.12
[1.11]: https://github.com/erayendes/mimir/compare/v1.10...v1.11
[1.10]: https://github.com/erayendes/mimir/compare/v1.9...v1.10
[1.9]: https://github.com/erayendes/mimir/compare/v1.7...v1.9
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

### [2.5.1] - 2026-06-25

#### Eklendi
- Yeni "veri alınamadı" durumu: bir sağlayıcının canlı kaynağına ulaşılamadığında — örneğin Antigravity kapalıyken — widget'lar, panel ve menü çubuğu noktaları artık bunu net gösteriyor ve uygulamayı açmayı öneriyor (widget'a ya da paneldeki uyarıya dokun); eski sayıları veya kaybolan kartı göstermek yerine. Yalnızca kurulu uygulamalar için görünür.

### [2.5] - 2026-06-24

#### Eklendi
- Menü çubuğu noktaları, bir modelin haftalık (7g) kotası bitince griye dönüyor — widget ve panelle aynı; haftalık kilitliyken dolu bir 5 saatlik seans "kullanılabilir" görünmüyor.

#### Değiştirildi
- Small widget: yüzde biraz küçüldü ve barına yaklaştı.
- Claude kullanımı tekrar kendi kendine yenileniyor, böylece açışlar arası güncel kalıyor (önceki salt-okur mod bazı kurulumlarda Claude verisini bayat bırakabiliyordu).

#### Düzeltildi
- Claude'un 5 saatlik kullanımı, penceresi sıfırlandıktan hemen sonra kısa süreliğine kaybolmuyor — canlı okuma, API hâlâ geçmiş reset zamanını döndürse bile artık doğru kabul ediliyor.

### [2.4] - 2026-06-24

#### Eklendi
- Haftalık (7g) kotası tükenen model artık gri/pasif gösteriliyor (widget ve panel). Böylece 5 saatlik limit dolu görünse bile o modeli kullanamayacağın belli olur.
- Haftalık (7g) kotasına özel renk eşiği: %50 ve üzeri yeşil, %10–50 arası amber, %10 altı kırmızı (5 saatlik pencere %15 eşiğinde kalmaya devam eder).

#### Değiştirildi
- Small widget tazelendi: yüzde rakamı büyütüldü, % işareti inceltildi, "5s" rozeti başlığa taşındı.
- Claude'un 5 saatlik yenilenme bilgisi artık widget'ta da görünüyor (sağlayıcı süre vermediğinde 5 saatlik pencereye düşülerek).
- Kota uyarı ve yenilenme bildirimleri yeniden yazıldı; mesajlara yenilenme saati ve kalan süre eklendi.

#### Düzeltildi
- **Claude Code oturumunun bozulması giderildi.** Mimir, Claude kotasını okumak için Claude Code'un OAuth erişim anahtarını (token) yeniliyordu. Bu anahtar tek kullanımlık ve Claude Code ile ortak olduğundan, Mimir'in yenilemesi Claude Code'un elindeki kopyayı geçersiz kılıp oturumunu düşürebiliyordu. Mimir artık Claude anahtarına **yalnızca salt-okur** erişiyor; onu asla yenilemez, keychain'e ya da dosyaya yazmaz. Anahtarın süresi dolduğunda son bilinen değerleri gösterir; Claude Code kendi anahtarını tazeleyince Mimir otomatik olarak güncellenir.
- Bildirim metinlerinde yüzde işaretinin yanlış görünmesi (ör. "%%100") düzeltildi.

### [2.3] - 2026-06-22

**Mimir, menü çubuğunun ötesinde.**

Hiçbir şey açmana gerek var mı?
Artık yok! Mimir 2.3 ile kotaların doğrudan masaüstünde.

İki widget arasından seç — tek cesur bir yüzde ya da tüm 5 saatlik limitlerin derli toplu listesi. Her yüzde ve çubuk durumuna göre parlıyor: yeşil, amber, kırmızı. Küçük olanın hangi modeli izleyeceğini sen söyle. Açık mod, koyu mod — ikisinde de kusursuz.

Parmağını kıpırdatmadan tüm tablo. 😊

> "Masaüstüne koydum, gün boyu oraya bakıyorum. İş mi yapıyorum, kota mı izliyorum belli değil."
> — **Kenan**, Eray'ın çok yakın arkadaşı

> "Sırf widget'ları görmek için güncelledim."
> — **Tayfun**, Eray'a hâlâ 400 TL borcu olan biri

> "Widget'ı eklerken Claude %9 çıktı, panikledim — sonra 'ne kadar şık bir panik' dedim."
> — **Selin**, LinkedIn bağlantısı (hiç tanışmadılar)

> "Tamamen tarafsızım: dünyanın en iyi widget'ları."
> — anonim, **Eray'ın annesi**

> "Hangi modeli göstereceğini ben mi seçiyorum? Başka söze gerek yok."
> — **Burak**, Eray'a işi düşmüş biri

#### Eklendi
- macOS masaüstü widget'ları, **iki boyutta**: tek büyük yüzde (Small) ve tüm 5 saatlik limitlerin derli toplu listesi (Medium). Her yüzde ve çubuk, kalanına göre renklenir — %50 ve üzeri yeşil, %15–50 arası amber, %15 altı kırmızı.
- Small widget yapılandırılabilir: hangi modeli göstereceğini seçmek için üzerine uzun bas → Widget'ı Düzenle. Varsayılan olarak tükenmeye en yakın olanı gösterir.
- Widget'lar sistem görünümünü takip eder; hem açık hem koyu temada çalışır.
- Menü çubuğu ikonuna **sağ tık**: anonim istatistikleri aç/kapat, güncellemeleri denetle, Mimir'den çık.
- **Anonim, gizlilik-dostu kullanım istatistikleri**: yalnızca hangi sağlayıcıları ve widget'ları kullandığın gibi kategorik bilgi — kotan, kredilerin, hesabın veya kişisel verin asla gönderilmez. İstediğin an sağ-tık menüsünden kapatabilirsin.

### [2.2.2] - 2026-06-22

#### Değiştirildi
- Menü çubuğu noktaları artık servis başına değil, her 5 saatlik limit başına bir nokta gösteriyor; böylece Antigravity'nin Gemini ve Claude/GPT'si ayrı noktalar — biri doluyken diğerinin tükendiğini bir bakışta görürsün. Noktalar kompakt bir grid'e diziliyor (dört taneyse 2×2).
- Menü çubuğu ikonu bir tık büyüdü, çubuğun tüm yüksekliğini dolduruyor.

### [2.2.1] - 2026-06-21

#### Düzeltildi
- Menü çubuğu durum noktaları yine panelle aynı sırada (üstten alta: Claude, Codex, Antigravity), böylece bir noktanın rengi her zaman doğru servisle hizalanıyor. 2.2'deki bir hata, örneğin sarı Antigravity noktasını en üstte gösterirken kartını panelin en altında bırakabiliyordu.

### [2.2] - 2026-06-21

#### Düzeltildi
- Menü çubuğu noktaları artık panelle her zaman aynı. Takip ettiğin her servis noktasını koruyor; 5 saatlik okuması kısa süre eksikken — örneğin pencere yeni sıfırlandığında — nokta kaybolmak yerine grileşiyor. Yani panelde üç servis varken iki nokta görmeyeceksin.
- Mimir arka planda artık macOS anahtar zinciri izin penceresini açmıyor. Claude girişini kimlik dosyasından ya da kendi güvenli önbelleğindeki token'dan okuyor ve Claude Code'un anahtar zinciri öğesine yalnızca sen Mimir'i açtığında erişiyor — böylece Codex veya Antigravity'ye göz atmak asla Claude istemi tetiklemiyor.

#### Değiştirildi
- Menü çubuğu noktaları panelle aynı sırada (üstten alta) diziliyor ve gri "henüz veri yok" noktası hem açık hem koyu menü çubuğunda okunaklı kalıyor.

### [2.1] - 2026-06-19

#### Düzeltildi
- macOS anahtar zinciri, Claude Code girişini okumak için artık sürekli izin sormuyor. Mimir token'ı bellekte tutuyor ve keychain'i her birkaç dakikada bir değil, yalnızca açılışta ve token süresi dolarken okuyor.
- Menü çubuğu ikonu artık gerçekten kullandığın her servis için tek bir durum noktası gösteriyor — Claude, Codex ve Antigravity'den yalnızca birini ya da ikisini takip ederken gri placeholder noktalar çıkmıyor.

### [2.0] - 2026-06-19

**Bugüne kadar gelmiş geçmiş en güzel Mimir.**

Bir menü çubuğu uygulaması bu kadar mı güzel olur? Mimir 2.0 ile, evet.

Sevdiğin her şeyi aldık ve baştan tasarladık: öne çıkan oturum, durumuna göre canlanan renkler, sade ve net haftalıklar — hepsi tek bir buzlu cam panelde. Açık modda da koyu modda da kusursuz.

Aynı Mimir; sadece her şeyiyle daha iyisi. 😊

> "İlk açtığımda 'vay be' dedim. Eşim duydu, o da baktı, o da 'vay be' dedi."
> — **Kenan**, Eray'ın çok yakın arkadaşı

> "Açık mod gelmiş, artık gündüz de kullanıyorum."
> — **Tayfun**, Eray'a 400 TL borcu olan biri

> "Kotam kırmızıya düştü, nokta yandı, kalbim kırıldı — ama tasarım o kadar güzel ki."
> — **Selin**, LinkedIn bağlantısı (hiç tanışmadılar)

> "Tamamen tarafsızım: dünyanın en iyi uygulaması."
> — anonim, **Eray'ın annesi**

> "Tek panelde her şey. Daha iyisini düşünemiyorum."
> — **Burak**, Eray'a işi düşmüş biri

#### Değişti
- Popover yeniden tasarlandı. Her servis artık önce 5 saatlik oturumunu öne çıkan bir satır olarak gösteriyor — isim, büyük bir yüzde ve ince bir ilerleme çubuğu — altında geri sayım ve sıfırlanma saati. Haftalık limitler aşağıda kompakt satırlar olarak, her biri bir durum noktasıyla; satın alınan kullanım kredisi en altta. Antigravity, Gemini ve Claude/GPT oturumlarını ayrı ayrı listeliyor.
- Kota seviyesi artık her yerde (çubuk, yüzde ve haftalık noktalar) renk kodlu: %50 ve üzeri yeşil, %15–50 arası amber, %15 altı kırmızı.
- Popover her şeyi tek seferde gösterecek kadar büyüyor — iç kaydırma yok — ve panelin tamamı artık gerçek bir cam: arkasındaki masaüstü ve pencereler hafif bulanık şekilde camın ardından görünüyor.

#### Eklendi
- Açık mod: popover artık sistem görünümünü (açık veya koyu) takip ediyor.
- Footer'daki sürüm rozetine tıklayınca güncelleme kontrolü yapılıyor; rozetin veya milowda bağlantısının üzerine gelince işaretçi imleci görünüyor.
- Menü çubuğu ikonunun yanında üç dikey durum noktası: üstten Claude, Codex ve Antigravity'nin 5 saatlik durumunu tek bakışta yeşil/amber/kırmızı gösteriyor. Bu özelliği abim İlker Utlu ([sigortadanismani.com](https://sigortadanismani.com)) için yaptım.

#### Düzeltildi
- macOS anahtar zinciri, Claude Code girişini okumak için artık sürekli izin sormuyor. Mimir bunu `security` komut satırı aracı yerine uygulama içinden okuyor; böylece "Her Zaman İzin Ver" kalıcı oluyor.

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

[Yayımlanmadı]: https://github.com/erayendes/mimir/compare/v2.0...HEAD
[2.0]: https://github.com/erayendes/mimir/compare/v1.13...v2.0
[1.13]: https://github.com/erayendes/mimir/compare/v1.12...v1.13
[1.12]: https://github.com/erayendes/mimir/compare/v1.11...v1.12
[1.11]: https://github.com/erayendes/mimir/compare/v1.10...v1.11
[1.10]: https://github.com/erayendes/mimir/compare/v1.9...v1.10
[1.9]: https://github.com/erayendes/mimir/compare/v1.7...v1.9
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
