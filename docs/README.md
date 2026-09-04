# Mimir

🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

![Mimir menu bar](assets/mimir_github-social-preview-0.png)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/erayendes)
[![Yerli üretim](https://img.shields.io/badge/YERL%C4%B0%20%C3%9CRET%C4%B0M-red?style=flat&label=%F0%9F%A4%9D&color=red&link=https%3A%2F%2Fmilowda.com)](https://milowda.com)

---

## English

> Track your AI tool usage limits from the macOS menu bar.

Mimir is a lightweight macOS menu bar app that shows real-time usage limits and
reset countdowns for your AI tools — Claude, Codex and Antigravity (which covers
Gemini, Claude and GPT) — without leaving your workflow.

### Features

- **Menu bar at a glance** — all your AI service statuses in a single popover
- **Live limits** — session and weekly quotas, per-model rows and credit balances, updated in real time
- **Desktop widget** — a Small widget that tracks the popover
- **Reset countdowns** — know exactly when each limit refreshes
- **Color status dots** — green / amber / red based on remaining quota
- **Minimalist design** — monochrome icon, full macOS light/dark mode support
- **No backend** — Mimir talks only to each provider's own endpoint, with that provider's own token; your quota figures and tokens go nowhere else

### Supported services

| Service | Data source |
|---|---|
| **Claude** | Claude desktop app session, or Claude Code OAuth (`~/.claude`) |
| **Codex** | ChatGPT usage API + local JSONL fallback |
| **Antigravity** | Local language server + Cockpit (Gemini and Claude/GPT groups) |

### Installation

#### Requirements

- **macOS 14.0 (Sonoma)** or later
- To build from source: **Swift 6.0+** (ships with Xcode 16)

#### Option 1 — Download a release (recommended)

1. Grab the latest `Mimir.zip` from the [Releases](https://github.com/erayendes/mimir/releases) page.
2. Unzip it and drag **Mimir.app** into your **Applications** folder.
3. Launch Mimir — the Mimir icon appears in the menu bar.

> ℹ️ **Notarized** — Distributed releases are notarized by Apple, so you won't get a Gatekeeper warning. (Releases are signed and notarized entirely on CI.)

#### Option 2 — Build from source

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

The `build_and_run.sh` script builds, signs, and runs the app.

| Command | What it does |
|---|---|
| `./script/build_and_run.sh` | Build + sign + run |
| `./script/build_and_run.sh logs` | Run with a log stream |
| `./script/build_and_run.sh install` | Build and install into Applications |

#### First launch

On first launch, Mimir asks once for permission to **Launch at Login** so your usage is always in the menu bar.

> You can change this later under **System Settings › General › Login Items**.

For services to appear, you must have signed in to each AI tool at least once (Mimir reads the local data those tools create). See each service's page for details:

See **[Services](#services)** for Claude, Codex and Antigravity.

#### Updating

Mimir updates itself via **Sparkle**. Use **Check for Updates** from the popover menu, or download the new `Mimir.zip` from the Releases page.

Stuck on something? → [Support & FAQ](../.github/SUPPORT.md).

### Reading the menu bar

Mimir's entire UI lives in the menu bar: a small **Mimir glyph** and a vertical **column of colored dots**, one per service (Claude, Codex, Antigravity — Antigravity's dot reflects its most-constrained group). Each dot follows that service's session window, falling back to its weekly quota when there is no session window — which was the case for Codex while OpenAI's 5-hour limit was withdrawn. Since August 2026 Plus accounts report it again and the dot follows it; Pro accounts still fall back to the weekly quota. A dot appears only for services with an active reading, so the count matches the LLMs you actually use.

**Dot colors** — based on the remaining percentage in the window the dot is tracking:

| Color | Remaining | Meaning |
|:---:|---|---|
| 🟢 Green | 50–100% | Plenty left |
| 🟡 Amber | 15–49% | Running low |
| 🔴 Red | below 15% | Near the limit |

**The popover** — click the glyph to open it. Each service is a card with its name and brand icon, the session (5-hour) quota shown prominently with percentage and countdown, a weekly summary row, per-model quota or credit rows, an (i) info icon, and a status note (e.g. *"token expired — open Claude Code"*). When a service has no session window, the weekly reading is promoted into that spot instead. Reset times use short units — e.g. `2h 15m`.

**Refreshing & stale state** — Mimir refreshes every minute and on each popover open; if a service hits a rate limit (HTTP 429) it backs off and shows the last-known data. When a live source disappears (e.g. the Antigravity IDE closes), the card is shown **dimmed** with the last snapshot instead of vanishing. If it stays unreachable long enough, a notice appears at the top of the popover; dismiss it with the **×** in its corner and that service's dots leave the menu bar with it. Both return once the service reports data again, so a later outage is still announced.

### Services

Jump to: [Claude](#claude) · [Codex](#codex) · [Antigravity](#antigravity)

#### Claude

<img src="assets/claude.svg" alt="Claude" width="40" align="right">

Mimir shows your Claude account's usage limits: the session (5-hour) and weekly windows, with reset times.

**Data source.** Two paths, tried in order:

1. **The Claude desktop app's session** (preferred). Mimir decrypts the app's own session cookie using the macOS Keychain key the app itself uses, then reads your account's live usage from claude.ai. This is what most people are actually on, and it stays accurate whether or not you use the CLI.
2. **Claude Code's OAuth token**, used against Anthropic's official usage endpoint:

```
GET https://api.anthropic.com/api/oauth/usage
```

- The token is read from Claude Code's records under `~/.claude` / the macOS **Keychain**.
- The response is **cached for 5 minutes**, so the Keychain (and its permission prompt) is touched only at launch and around token expiry.

**Token refresh.** Anthropic rotates the **refresh token**. If the token is expired or within 5 minutes of expiry, Mimir refreshes it proactively and **writes the new pair back to the Keychain** — keeping Claude Code's own login valid too. If the refresh fails, the card shows **token expired — open Claude Code**; just open Claude Code once and sign in.

**What's shown.** Session (5-hour) and weekly remaining percentages with reset times. The **Claude dot** in the menu bar is colored by the session percentage.

| Symptom | Likely cause / fix |
|---|---|
| No Claude card | Claude Code may never have been signed in — open it once and sign in |
| "token expired" note | Open Claude Code; it resolves once the token refreshes |
| Frozen / dimmed data | Temporary error or rate limit; Mimir shows last-known data and refreshes shortly |

#### Codex

<img src="assets/codex.svg" alt="Codex" width="40" align="right">

Mimir shows session and weekly quotas for **Codex**, trying two sources in order.

**Data source.** Mimir first queries the **live ChatGPT usage API**. If that fails, it falls back to Codex's local session records:

1. **ChatGPT usage API** (live) — primary source.
2. **Local `~/.codex/sessions` JSONL fallback** — if the API is unreachable.
3. If both fail, the **last-known snapshot**.

**How the local fallback is read.** The **most recent `.jsonl` file** under `~/.codex/sessions` is scanned from the end backwards, taking the `rate_limits` field of `token_count` events.

**How windows are classified.** Each window is identified by its **real length**, not by which slot it arrives in. OpenAI removed Codex's 5-hour limit in July 2026, leaving only the *weekly* window — and leaving it in the `primary` slot, which used to mean "5-hour". Since 25 August 2026 the 5-hour window is back for **Plus** accounts, alongside the weekly one rather than replacing it; **Pro** still reports the weekly window alone. Both shapes work without an update, because Mimir classifies by length rather than slot. A window of 6 hours or less is the session; anything longer is a longer-term quota. If the length is missing, Mimir falls back to how far the reset is (a 5-hour window can never reset more than 5h out), and only then to the slot. When there is no session window, the card drops that block and promotes the longer-term reading rather than showing a misleading 100%.

**Longer-term windows are labelled by their real size, not assumed to be 7 days.** The badge ("7d", "30d") comes from the window's reported total length — ChatGPT Go moved to a ~30-day window in mid-2026, and Plus/Pro stayed weekly. The badge is derived from the window length only, never from the countdown: on day 27 of a 30-day window the badge still reads "30d". When a provider reports no length, Mimir shows its plain weekly label rather than printing a guessed number.

> 📝 **Note:** If no reset time is found in the local file, the card still shows the remaining percentage, but the countdown may be omitted (the card notes this).

**Reset credits.** Alongside the balance, Codex can hold **reset credits** — one-shot passes that clear a spent rate-limit window. Mimir reads them from the ChatGPT API and shows how many you have, plus how long until the first one expires. Only credits that are both still available and not yet expired are counted (one can lapse between polls), and the row is omitted entirely when there are none. This is a bonus reading: if the request fails, the rest of the Codex card is unaffected.

**What's shown.** Session (5-hour) and weekly remaining percentages with reset times. When available, value rows such as the **credit balance** and **reset credits** (for these non-percentage rows, Mimir triggers the low-quota badge when they fall below their threshold).

| Symptom | Likely cause / fix |
|---|---|
| No Codex card | No session records under `~/.codex` — use Codex once |
| No countdown | No reset time found in the local file; percentage is still shown |
| Stale data | The API may be unreachable; Mimir shows the local fallback or last snapshot |

#### Antigravity

<img src="assets/antigravity.svg" alt="Antigravity" width="40" align="right">

Mimir shows group-based quotas for **Antigravity**. Antigravity no longer manages quota per-model but through **shared group pools**: a **Gemini** group and a **Claude + GPT** group. Each group has a **weekly** and a **5-hour** window.

**Data source.** Mimir tries the following sources in order and uses the first that succeeds:

1. **Group quota summary** — the grouped weekly + 5-hour summary that backs the IDE's "Model Quota" page (primary live source).
2. **Cloud Code authorized API** — a `fetchAvailableModels` call with your Cockpit account's token.
3. **Cockpit cache** — the last authorized data stored locally.
4. **Local language server** data. Several can be running at once — the desktop app and the IDE each start their own, and both report the same account quota — so Mimir asks each in turn until one answers. A server that has just launched can reply with an auth error while its sibling serves fine, and stopping at the first one would drop the whole source.
5. **Last snapshot** — when the IDE/Cockpit is closed, valid until its reset time passes.

**The menu bar dot.** Since Antigravity has **two session groups** (Gemini, Claude/GPT), the single Antigravity dot shows the color of the **most constrained** group. When the IDE or Cockpit is closed, Mimir shows the **last snapshot**; if there is no account info at all, the card shows **open Antigravity or Cockpit**.

| Symptom | Likely cause / fix |
|---|---|
| "open Antigravity or Cockpit" note | Account info couldn't be read — open the IDE or Cockpit |
| Data looks dimmed | The IDE/Cockpit closed; the last snapshot is being shown |
| Quotas differ from expected | Antigravity uses group-pool logic; read by group, not per-model |

> 🔒 **Privacy:** All reads are local / against authorized endpoints; your data is processed only on your machine and sent to no third party. See [Privacy & Security](#privacy--security).

### Privacy & Security

Mimir is designed to be **privacy-first**. The core principle is simple:

> **No personal data or API key ever leaves your machine to reach Mimir's servers** — because Mimir has no such servers.

#### What Mimir reads

Mimir reads only **local** sources:

- The AI tools' config/log files: `~/.claude`, `~/.codex`, etc.
- Entries in the macOS **Keychain** created by the respective apps (tokens).
- The **Claude desktop app's** session cookie, decrypted with the same macOS Keychain key
  the app itself uses — this is what gives Claude's live reading.

This is data your tools **already** create on your machine; Mimir only reads it.

#### Where data goes

Mimir only makes requests to each service's **own official endpoint**, with **that service's own token** (to fetch usage info):

- Anthropic's OAuth usage endpoint for Claude
- The ChatGPT usage API for Codex
- Google Cloud Code authorized endpoints for Antigravity

These requests are the same kind the tool itself would make. **Mimir inserts no server of its own**, and your quota figures and tokens are relayed to no one.

Two services do receive data, and neither gets anything about your usage:

| Service | What it receives | Control |
|---|---|---|
| **Sentry** | Crash and error reports — technical app health only | Always on in released builds |
| **TelemetryDeck** | Anonymous, categorical signals: which providers are in use (the provider name, never a value) and how many widgets are placed | Opt-out from the popover menu |

No quota percentages, reset times, credit balances, account ids or tokens are ever sent to either. Development builds send nothing at all.

#### Token handling

- Tokens are kept **in memory** as much as possible; the Keychain (and its permission prompt) is touched only at startup and around token expiry.
- When the Claude token expires, Mimir refreshes it and **writes the new pair back to the Keychain** — so it doesn't break the tool's own session.
- A rejected (401/403) token is dropped from the cache; a dead token is not retried over and over.

#### Crash/diagnostic data

To monitor app stability, crash/diagnostic reporting (Sentry) is included. It does **not** contain your usage quota or tokens; it is limited to data about the app's technical health.

#### Open source

Mimir is open source (MIT). You can verify all of the above in the source code:

**[github.com/erayendes/mimir →](https://github.com/erayendes/mimir)**

### Roadmap

> [!NOTE]
> The full roadmap is tracked as GitHub issues — new services, credit tracking,
> Homebrew distribution, and more.
> **[View open issues →](https://github.com/erayendes/mimir/issues)**

### About the name

**Mímir** is a figure from Norse mythology renowned for knowledge and wisdom — the
guardian of the well beneath Yggdrasil from which Odin drank, sacrificing an eye for
insight. After he was beheaded in the Æsir–Vanir war, Odin preserved his head and
kept consulting it for counsel. The name fits the app: a quiet advisor that, at a
single glance, tells you how much you have left and when it resets.

### Contributing

Bug reports and pull requests are welcome. For major changes, please open an
issue first. See [Contributing](../.github/CONTRIBUTING.md) · [Support & FAQ](../.github/SUPPORT.md) · [Changelog](CHANGELOG.md).

---

## Türkçe

> AI araçlarınızın kullanım limitlerini macOS menü çubuğundan takip edin.

Mimir; Claude, Codex ve Antigravity (Gemini, Claude ve GPT gruplarını kapsar) gibi
AI araçlarınızın kullanım limitlerini ve yenilenme sürelerini iş akışınızı bölmeden macOS menü çubuğundan
anlık olarak gösteren hafif bir uygulamadır.

### Özellikler

- **Menü çubuğunda tek bakış** — tüm AI servislerinizin durumu tek bir popover'da
- **Anlık limitler** — seans ve haftalık kotalar, model bazlı satırlar ve kredi bakiyeleri gerçek zamanlı güncellenir
- **Masaüstü widget'ı** — popover'ı takip eden Small boyut
- **Geri sayım** — her limitin tam olarak ne zaman yenileneceğini gösterir
- **Renkli durum noktaları** — kalan kotaya göre yeşil / amber / kırmızı
- **Minimalist tasarım** — monokrom ikon, macOS açık/koyu tema desteği
- **Arka uç yok** — Mimir yalnızca her sağlayıcının kendi uç noktasına, o sağlayıcının kendi token'ıyla bağlanır; kota bilgileriniz ve token'larınız başka hiçbir yere gitmez

### Desteklenen servisler

| Servis | Veri kaynağı |
|---|---|
| **Claude** | Claude masaüstü uygulaması oturumu veya Claude Code OAuth (`~/.claude`) |
| **Codex** | ChatGPT kullanım API'si + yerel JSONL yedeği |
| **Antigravity** | Yerel dil sunucusu + Cockpit (Gemini ve Claude/GPT grupları) |

### Kurulum

#### Gereksinimler

- **macOS 14.0 (Sonoma)** veya üzeri
- Kaynaktan derleyecekseniz: **Swift 6.0+** (Xcode 16 ile birlikte gelir)

#### Seçenek 1 — Hazır sürümü indir (önerilen)

1. [Releases](https://github.com/erayendes/mimir/releases) sayfasından en güncel `Mimir.zip` dosyasını indirin.
2. Arşivi açın ve **Mimir.app**'i **Uygulamalar** klasörünüze sürükleyin.
3. Mimir'i çalıştırın — menü çubuğunda Mimir ikonu belirir.

> ℹ️ **Notarize edilmiştir** — Dağıtılan sürümler Apple tarafından notarize edilir; Gatekeeper uyarısı almazsınız. (Sürümler tamamen CI üzerinde imzalanıp notarize edilir.)

#### Seçenek 2 — Kaynaktan derle

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

`build_and_run.sh` betiği uygulamayı derler, imzalar ve çalıştırır.

| Komut | Ne yapar |
|---|---|
| `./script/build_and_run.sh` | Derle + imzala + çalıştır |
| `./script/build_and_run.sh logs` | Log akışı ile birlikte çalıştır |
| `./script/build_and_run.sh install` | Derleyip Uygulamalar'a kur |

#### İlk çalıştırma

Mimir ilk açıldığında, **oturum açıldığında otomatik başlatma** (Launch at Login) için bir kez izin sorar. Bu sayede kullanım durumunuz her zaman menü çubuğunda hazır olur.

> Bu tercihi daha sonra **Sistem Ayarları › Genel › Açılış Öğeleri** (Login Items) üzerinden değiştirebilirsiniz.

İlk açılışta servislerin görünmesi için ilgili AI araçlarına en az bir kez giriş yapmış olmanız gerekir (Mimir o araçların oluşturduğu yerel verileri okur). Detaylar için her servisin kendi sayfasına bakın:

Claude, Codex ve Antigravity için bkz. **[Servisler](#servisler)**.

#### Güncelleme

Mimir, **Sparkle** ile kendi içinden güncellenir. Açılır penceredeki menüden **Güncellemeleri Denetle**'yi kullanabilir veya yeni `Mimir.zip` dosyasını Releases sayfasından indirebilirsiniz.

Takıldığınız bir nokta olursa → [Destek & SSS](../.github/SUPPORT.md).

### Menü çubuğunu okuma

Mimir'in tüm arayüzü menü çubuğunda yaşar: küçük bir **Mimir simgesi** ve yanında dikey bir **renkli nokta sütunu** — her servis için bir nokta (Claude, Codex, Antigravity — Antigravity noktası en kısıtlı grubunu yansıtır). Her nokta o servisin seans penceresini izler; seans penceresi yoksa haftalık kotaya düşer — OpenAI 5 saatlik limiti kaldırdığı dönemde Codex'te durum buydu. Ağustos 2026'dan beri Plus hesaplar bu pencereyi yeniden bildiriyor ve nokta onu izliyor; Pro hesaplarda hâlâ haftalık kotaya düşülüyor. Nokta yalnızca aktif okuması olan servisler için görünür; yani nokta sayısı kullandığınız LLM sayısına eşittir.

**Nokta renkleri** — noktanın izlediği penceredeki kalan yüzdeye göre:

| Renk | Kalan | Anlamı |
|:---:|---|---|
| 🟢 Yeşil | %50–100 | Bol hakkınız var |
| 🟡 Amber | %15–49 | Azalıyor |
| 🔴 Kırmızı | %15'in altı | Limite yakın |

**Açılır pencere (popover)** — simgeye tıklayınca açılır. Her servis bir karttır: ad ve marka ikonu, belirgin gösterilen seans (5 saatlik) kotası (yüzde + geri sayım), haftalık özet satırı, per-model kota veya kredi satırları, (i) bilgi simgesi ve bir durum notu (örn. *"token süresi doldu — Claude Code'u aç"*). Bir servisin seans penceresi yoksa haftalık okuma o alana terfi eder. Yenilenme süreleri kısa birimlerle: örn. `2s 15d`.

**Yenileme & eski veri** — Mimir dakikada bir ve her popover açılışında yeniler; bir servis hız sınırına (HTTP 429) takılırsa geri çekilir ve son bilinen veriyi gösterir. Canlı kaynak kaybolduğunda (ör. Antigravity IDE'si kapanınca) kart yok olmaz, **soluk** (dimmed) hâlde son anlık görüntüyle kalır. Yeterince uzun süre ulaşılamazsa popover'ın üstünde bir uyarı belirir; köşesindeki **×** ile kapattığınızda o servisin noktaları da menü çubuğundan gider. Servis tekrar veri verince ikisi de geri gelir, böylece sonraki bir kesinti yine bildirilir.

### Servisler

Atla: [Claude](#claude-1) · [Codex](#codex-1) · [Antigravity](#antigravity-1)

#### Claude

<img src="assets/claude.svg" alt="Claude" width="40" align="right">

Mimir, Claude hesabınızın kullanım limitlerini gösterir: seans (5 saatlik) ve haftalık pencereler ile yenilenme zamanları.

**Veri kaynağı.** Sırayla denenen iki yol var:

1. **Claude masaüstü uygulamasının oturumu** (tercih edilen). Mimir, uygulamanın kendi oturum çerezini, uygulamanın da kullandığı macOS Keychain anahtarıyla çözer ve hesabınızın canlı kullanımını claude.ai'den okur. Çoğu kullanıcının gerçekte bulunduğu yer burasıdır; CLI kullanıp kullanmadığınızdan bağımsız olarak doğru kalır.
2. **Claude Code'un OAuth token'ı** ile Anthropic'in resmî kullanım uç noktası:

```
GET https://api.anthropic.com/api/oauth/usage
```

- Token, Claude Code'un `~/.claude` altındaki kayıtlarından / macOS **Keychain**'den okunur.
- Yanıt 5 dakikalık bir **önbelleğe** alınır; böylece Keychain'e yalnızca uygulama başlarken ve token süresi dolmaya yakınken dokunulur.

**Token yenileme.** Anthropic, **refresh token**'ı döndürür (rotation). Token'ın süresi dolmuşsa veya dolmasına 5 dakikadan az kalmışsa Mimir token'ı proaktif yeniler ve **yeni çiftini Keychain'e geri yazar** — böylece Claude Code'un kendi oturumu da geçerli kalır. Yenileme başarısız olursa kart **token süresi doldu — Claude Code'u aç** notunu gösterir; Claude Code'u bir kez açıp giriş yapmanız yeterlidir.

**Gösterilen bilgiler.** Seans (5 saatlik) ve haftalık kalan yüzdeleri ile sıfırlanma zamanları. Menü çubuğundaki **Claude noktası** seans yüzdesine göre renklenir.

| Belirti | Olası neden / çözüm |
|---|---|
| Claude kartı yok | Claude Code'a hiç giriş yapılmamış olabilir — bir kez açıp giriş yapın |
| "token süresi doldu" notu | Claude Code'u açın; token yenilenince düzelir |
| Veri donuk / soluk | Geçici hata ya da hız sınırı; Mimir son bilinen veriyi gösterir, kısa süre sonra yeniler |

#### Codex

<img src="assets/codex.svg" alt="Codex" width="40" align="right">

Mimir, **Codex** için seans ve haftalık kotaları gösterir. İki kaynağı sırayla dener.

**Veri kaynağı.** Mimir önce **canlı ChatGPT kullanım API'sini** sorgular. Başarısız olursa Codex'in yerel oturum kayıtlarına geri düşer:

1. **ChatGPT kullanım API'si** (canlı) — birincil kaynak.
2. **Yerel `~/.codex/sessions` JSONL yedeği** — API erişilemezse.
3. Her ikisi de başarısız olursa **son bilinen anlık görüntü** (snapshot).

**Yerel yedek nasıl okunur?** `~/.codex/sessions` altındaki **en güncel `.jsonl` dosyası** sondan başa taranır; `token_count` olaylarındaki `rate_limits` alanı okunur.

**Pencereler nasıl sınıflandırılır?** Her pencere, geldiği slota göre değil **gerçek uzunluğuna** göre tanınır. OpenAI Temmuz 2026'da Codex'in 5 saatlik limitini kaldırdı; geriye tek pencere olarak *haftalık* olan kaldı — üstelik eskiden "5 saatlik" anlamına gelen `primary` slotunda. 25 Ağustos 2026'dan beri 5 saatlik pencere **Plus** hesaplarda geri döndü; haftalığın yerine değil, yanına. **Pro** hesaplarda hâlâ yalnızca haftalık pencere dönüyor. İki şekil de güncelleme gerektirmeden çalışıyor, çünkü Mimir slota değil uzunluğa bakıyor. 6 saat ve altı seans, daha uzunu uzun vadeli kota sayılır. Uzunluk bilgisi yoksa Mimir sıfırlanmanın ne kadar uzakta olduğuna bakar (5 saatlik bir pencere asla 5 saatten uzağa sıfırlanamaz), en son çare olarak slota. Seans penceresi yoksa kart o bloğu düşürür ve yanıltıcı bir %100 göstermek yerine uzun vadeli okumayı öne çıkarır.

**Uzun vadeli pencereler 7 gün varsayılmaz, gerçek boyutuyla etiketlenir.** Rozet ("7g", "30g") pencerenin bildirilen toplam uzunluğundan gelir — ChatGPT Go 2026 ortasında ~30 günlük pencereye geçti, Plus/Pro haftalık kaldı. Rozet yalnızca pencere uzunluğundan türetilir, geri sayımdan asla: 30 günlük bir pencerenin 27. gününde de rozet "30g" yazar. Sağlayıcı uzunluk bildirmiyorsa Mimir tahmini bir sayı yazmak yerine düz haftalık etiketini gösterir.

> 📝 **Not:** Yerel dosyada sıfırlanma zamanı bulunamazsa kart yine kalan yüzdeyi gösterir, ancak geri sayım gösterilmeyebilir (kart bunu bir notla belirtir).

**Sıfırlama hakkı.** Bakiyenin yanında Codex'te **sıfırlama hakkı** olabilir — dolan bir kota penceresini temizleyen tek kullanımlık haklar. Mimir bunları ChatGPT API'sinden okur; kaç tane olduğunu ve ilkinin ne kadar süre sonra dolacağını gösterir. Yalnızca hem hâlâ kullanılabilir hem de süresi dolmamış haklar sayılır (bir hak iki sorgu arasında süresini doldurabilir); hiç yoksa satır hiç çizilmez. Bu ek bir okumadır: istek başarısız olursa Codex kartının geri kalanı etkilenmez.

**Gösterilen bilgiler.** Seans (5 saatlik) ve haftalık kalan yüzdeleri ile sıfırlanma zamanları. Uygun olduğunda **kredi bakiyesi** ve **sıfırlama hakkı** gibi değer satırları (yüzde olmayan bu satırlar için Mimir, eşik altına inildiğinde düşük-kota rozetini tetikler).

| Belirti | Olası neden / çözüm |
|---|---|
| Codex kartı yok | `~/.codex` altında oturum kaydı yok — Codex'i bir kez kullanın |
| Geri sayım görünmüyor | Yerel dosyada sıfırlanma zamanı bulunamadı; yüzde yine de gösterilir |
| Veri eski | API erişilemiyor olabilir; Mimir yerel yedeği veya son snapshot'ı gösterir |

#### Antigravity

<img src="assets/antigravity.svg" alt="Antigravity" width="40" align="right">

Mimir, **Antigravity** için grup bazlı kotaları gösterir. Antigravity kotayı artık per-model değil, **paylaşılan grup havuzları** üzerinden yönetir: bir **Gemini** grubu ve bir **Claude + GPT** grubu. Her grubun bir **haftalık** ve bir **5 saatlik** penceresi vardır.

**Veri kaynağı.** Mimir aşağıdaki kaynakları sırayla dener ve ilk başarılı olanı kullanır:

1. **Grup kota özeti** — IDE'nin "Model Quota" sayfasını besleyen, gruplanmış haftalık + 5 saatlik özet (birincil canlı kaynak).
2. **Cloud Code yetkili API'si** — Cockpit hesabınızın token'ıyla `fetchAvailableModels` çağrısı.
3. **Cockpit önbelleği** — yerel olarak saklanan son yetkili veri.
4. **Yerel dil sunucusu** (language server) verisi. Aynı anda birden fazlası çalışıyor olabilir — masaüstü uygulaması ve IDE ayrı ayrı kendi sunucusunu başlatır, ikisi de aynı hesap kotasını bildirir — bu yüzden Mimir cevap alana kadar hepsini sırayla dener. Yeni başlamış bir sunucu kimlik doğrulama hatası döndürürken diğeri sorunsuz cevap verebilir; ilkinde durmak kaynağın tamamını düşürürdü.
5. **Son anlık görüntü** (snapshot) — IDE/Cockpit kapalıysa, sıfırlanma zamanı geçene kadar geçerli.

**Menü çubuğundaki nokta.** Antigravity'nin **iki seans grubu** olduğundan (Gemini, Claude/GPT), tek Antigravity noktası **en kısıtlı** grubun rengini gösterir. IDE veya Cockpit kapalıyken Mimir **son anlık görüntüyü** gösterir; hiç hesap bilgisi yoksa kart **Antigravity veya Cockpit'i aç** notunu verir.

| Belirti | Olası neden / çözüm |
|---|---|
| "Antigravity veya Cockpit'i aç" notu | Hesap bilgisi okunamadı — IDE'yi veya Cockpit'i açın |
| Veri soluk görünüyor | IDE/Cockpit kapandı; son snapshot gösteriliyor |
| Kotalar beklenenden farklı | Antigravity grup havuzu mantığı kullanır; per-model değil grup bazında okuyun |

> 🔒 **Gizlilik:** Tüm okuma yereldir/yetkili uç noktalarladır; veriniz yalnızca makinenizde işlenir, hiçbir üçüncü tarafa gönderilmez. Bkz. [Gizlilik ve Güvenlik](#gizlilik-ve-güvenlik).

### Gizlilik ve Güvenlik

Mimir, **gizlilik odaklı** tasarlanmıştır. Temel ilke basittir:

> **Hiçbir kişisel veri veya API anahtarı, makinenizden çıkıp Mimir'in sunucularına gitmez** — çünkü Mimir'in böyle bir sunucusu yoktur.

#### Mimir ne okur?

Mimir yalnızca **yerel** kaynakları okur:

- AI araçlarının yapılandırma/log dosyaları: `~/.claude`, `~/.codex` vb.
- macOS **Keychain**'de ilgili uygulamaların oluşturduğu kayıtlar (token'lar).
- **Claude masaüstü uygulamasının** oturum çerezi; uygulamanın kendi kullandığı macOS
  Keychain anahtarıyla çözülür — Claude'un canlı okumasını sağlayan kaynak budur.

Bu veriler, kullandığınız araçların makinenizde **zaten** oluşturduğu verilerdir; Mimir bunları sadece okur.

#### Veri nereye gider?

Mimir yalnızca, ilgili servisin **kendi resmî uç noktasına**, **o servisin kendi token'ıyla** istek atar (kullanım bilgisini almak için):

- Claude için Anthropic'in OAuth kullanım uç noktası
- Codex için ChatGPT kullanım API'si
- Antigravity için Google Cloud Code yetkili uç noktaları

Bu istekler, aracın kendisinin yapacağı isteklerle aynı niteliktedir. **Mimir araya kendi sunucusunu sokmaz**; kota bilgileriniz ve token'larınız hiç kimseye iletilmez.

İki servis veri alır, ikisi de kullanımınıza dair hiçbir şey görmez:

| Servis | Ne alır | Denetim |
|---|---|---|
| **Sentry** | Çökme ve hata raporları — yalnızca uygulamanın teknik sağlığı | Yayınlanan sürümlerde her zaman açık |
| **TelemetryDeck** | Anonim, kategorik sinyaller: hangi sağlayıcıların kullanıldığı (yalnızca sağlayıcının adı, hiçbir değer değil) ve kaç widget eklendiği | Popover menüsünden kapatılabilir |

İkisine de kota yüzdesi, sıfırlanma zamanı, kredi bakiyesi, hesap kimliği veya token gönderilmez. Geliştirme sürümleri hiçbir şey göndermez.

#### Token yönetimi

- Token'lar mümkün olduğunca **bellekte** tutulur; Keychain'e (ve onun izin istemine) yalnızca başlangıçta ve token süresi dolmaya yakınken dokunulur.
- Claude token'ı süresi dolduğunda Mimir onu yeniler ve **yeni çiftini Keychain'e geri yazar** — böylece aracın kendi oturumunu bozmaz.
- Reddedilen (401/403) bir token önbellekten düşürülür; ölü token tekrar tekrar denenmez.

#### Hata/teşhis verisi

Uygulamanın kararlılığını izlemek için çökme/teşhis raporlaması (Sentry) bulunur. Bu, kullanım kotanızı veya token'larınızı **içermez**; uygulamanın teknik sağlığına ilişkin verilerle sınırlıdır.

#### Açık kaynak

Mimir açık kaynaktır (MIT). Yukarıdakilerin tümünü kaynak kodunda doğrulayabilirsiniz:

**[github.com/erayendes/mimir →](https://github.com/erayendes/mimir)**

### Yol Haritası

> [!NOTE]
> Yol haritasının tamamı GitHub issue'ları olarak takip ediliyor — yeni servisler,
> kredi takibi, Homebrew dağıtımı ve daha fazlası.
> **[Açık issue'ları görüntüle →](https://github.com/erayendes/mimir/issues)**

### Meraklısına: İsmin hikâyesi

**Mímir**, İskandinav mitolojisinde bilgelik ve bilgiyle anılan bir figürdür —
Yggdrasil'in kökündeki bilgelik kuyusunun bekçisidir; Odin o kuyudan içip kavrayış
kazanmak için bir gözünü feda eder. Æsir–Vanir savaşında başı kesildikten sonra Odin
başını saklayıp akıl danışmak için ona başvurmaya devam eder. İsim uygulamayla
örtüşüyor: tek bakışta ne kadar hakkınız kaldığını ve ne zaman yenileneceğini söyleyen
sessiz bir danışman.

### Katkıda Bulunma

Hata raporları ve pull request'ler memnuniyetle karşılanır. Büyük değişiklikler için
önce bir issue açın. Bkz. [Katkı](../.github/CONTRIBUTING.md) · [Destek & SSS](../.github/SUPPORT.md) · [Sürüm Notları](CHANGELOG.md).

---

[MIT](../LICENSE) © Eray Endes
