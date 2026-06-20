# Services / Servisler

🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

> [Documentation](README.md) · Previous: [← Installation](INSTALLATION.md)

---

## English

Jump to: [Claude](#claude) · [Codex](#codex) · [Antigravity](#antigravity)

### Claude

<img src="assets/claude.svg" alt="Claude" width="40" align="right">

Mimir shows **Claude Code**'s usage limits: the session (5-hour) and weekly windows, with reset times.

**Data source.** Mimir uses the **OAuth token** that Claude Code creates on your machine to query Anthropic's official usage endpoint:

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

### Codex

<img src="assets/codex.svg" alt="Codex" width="40" align="right">

Mimir shows session and weekly quotas for **Codex**, trying two sources in order.

**Data source.** Mimir first queries the **live ChatGPT usage API**. If that fails, it falls back to Codex's local session records:

1. **ChatGPT usage API** (live) — primary source.
2. **Local `~/.codex/sessions` JSONL fallback** — if the API is unreachable.
3. If both fail, the **last-known snapshot**.

**How the local fallback is read.** The **most recent `.jsonl` file** under `~/.codex/sessions` is scanned from the end backwards. From the `rate_limits` field of `token_count` events, Mimir extracts **primary** → session (5-hour) window and **secondary** → weekly window, then computes remaining percentages and reset times.

> 📝 **Note:** If no reset time is found in the local file, the card still shows the remaining percentage, but the countdown may be omitted (the card notes this).

**What's shown.** Session (5-hour) and weekly remaining percentages with reset times. When available, value rows such as a **credit balance** (for these non-percentage rows, Mimir triggers the low-quota badge when they fall below their threshold).

| Symptom | Likely cause / fix |
|---|---|
| No Codex card | No session records under `~/.codex` — use Codex once |
| No countdown | No reset time found in the local file; percentage is still shown |
| Stale data | The API may be unreachable; Mimir shows the local fallback or last snapshot |

### Antigravity

<img src="assets/antigravity.svg" alt="Antigravity" width="40" align="right">

Mimir shows group-based quotas for **Antigravity**. Antigravity no longer manages quota per-model but through **shared group pools**: a **Gemini** group and a **Claude + GPT** group. Each group has a **weekly** and a **5-hour** window.

**Data source.** Mimir tries the following sources in order and uses the first that succeeds:

1. **Group quota summary** — the grouped weekly + 5-hour summary that backs the IDE's "Model Quota" page (primary live source).
2. **Cloud Code authorized API** — a `fetchAvailableModels` call with your Cockpit account's token.
3. **Cockpit cache** — the last authorized data stored locally.
4. **Local language server** data.
5. **Last snapshot** — when the IDE/Cockpit is closed, valid until its reset time passes.

**The menu bar dot.** Since Antigravity has **two session groups** (Gemini, Claude/GPT), the single Antigravity dot shows the color of the **most constrained** group. When the IDE or Cockpit is closed, Mimir shows the **last snapshot**; if there is no account info at all, the card shows **open Antigravity or Cockpit**.

| Symptom | Likely cause / fix |
|---|---|
| "open Antigravity or Cockpit" note | Account info couldn't be read — open the IDE or Cockpit |
| Data looks dimmed | The IDE/Cockpit closed; the last snapshot is being shown |
| Quotas differ from expected | Antigravity uses group-pool logic; read by group, not per-model |

> 🔒 **Privacy:** All reads are local / against authorized endpoints; your data is processed only on your machine and sent to no third party. See [Privacy & Security](PRIVACY.md).

---

## Türkçe

Atla: [Claude](#claude-1) · [Codex](#codex-1) · [Antigravity](#antigravity-1)

### Claude

<img src="assets/claude.svg" alt="Claude" width="40" align="right">

Mimir, **Claude Code**'un kullanım limitlerini gösterir: seans (5 saatlik) ve haftalık pencereler ile yenilenme zamanları.

**Veri kaynağı.** Mimir, Claude Code'un makinenizde oluşturduğu **OAuth token'ını** kullanarak Anthropic'in resmî kullanım uç noktasını sorgular:

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

### Codex

<img src="assets/codex.svg" alt="Codex" width="40" align="right">

Mimir, **Codex** için seans ve haftalık kotaları gösterir. İki kaynağı sırayla dener.

**Veri kaynağı.** Mimir önce **canlı ChatGPT kullanım API'sini** sorgular. Başarısız olursa Codex'in yerel oturum kayıtlarına geri düşer:

1. **ChatGPT kullanım API'si** (canlı) — birincil kaynak.
2. **Yerel `~/.codex/sessions` JSONL yedeği** — API erişilemezse.
3. Her ikisi de başarısız olursa **son bilinen anlık görüntü** (snapshot).

**Yerel yedek nasıl okunur?** `~/.codex/sessions` altındaki **en güncel `.jsonl` dosyası** sondan başa taranır. Mimir, `token_count` olaylarındaki `rate_limits` alanından **primary** → seans (5 saatlik) ve **secondary** → haftalık değerlerini çıkarır; kalan yüzdeleri ve sıfırlanma zamanlarını hesaplar.

> 📝 **Not:** Yerel dosyada sıfırlanma zamanı bulunamazsa kart yine kalan yüzdeyi gösterir, ancak geri sayım gösterilmeyebilir (kart bunu bir notla belirtir).

**Gösterilen bilgiler.** Seans (5 saatlik) ve haftalık kalan yüzdeleri ile sıfırlanma zamanları. Uygun olduğunda **kredi bakiyesi** gibi değer satırları (yüzde olmayan bu satırlar için Mimir, eşik altına inildiğinde düşük-kota rozetini tetikler).

| Belirti | Olası neden / çözüm |
|---|---|
| Codex kartı yok | `~/.codex` altında oturum kaydı yok — Codex'i bir kez kullanın |
| Geri sayım görünmüyor | Yerel dosyada sıfırlanma zamanı bulunamadı; yüzde yine de gösterilir |
| Veri eski | API erişilemiyor olabilir; Mimir yerel yedeği veya son snapshot'ı gösterir |

### Antigravity

<img src="assets/antigravity.svg" alt="Antigravity" width="40" align="right">

Mimir, **Antigravity** için grup bazlı kotaları gösterir. Antigravity kotayı artık per-model değil, **paylaşılan grup havuzları** üzerinden yönetir: bir **Gemini** grubu ve bir **Claude + GPT** grubu. Her grubun bir **haftalık** ve bir **5 saatlik** penceresi vardır.

**Veri kaynağı.** Mimir aşağıdaki kaynakları sırayla dener ve ilk başarılı olanı kullanır:

1. **Grup kota özeti** — IDE'nin "Model Quota" sayfasını besleyen, gruplanmış haftalık + 5 saatlik özet (birincil canlı kaynak).
2. **Cloud Code yetkili API'si** — Cockpit hesabınızın token'ıyla `fetchAvailableModels` çağrısı.
3. **Cockpit önbelleği** — yerel olarak saklanan son yetkili veri.
4. **Yerel dil sunucusu** (language server) verisi.
5. **Son anlık görüntü** (snapshot) — IDE/Cockpit kapalıysa, sıfırlanma zamanı geçene kadar geçerli.

**Menü çubuğundaki nokta.** Antigravity'nin **iki seans grubu** olduğundan (Gemini, Claude/GPT), tek Antigravity noktası **en kısıtlı** grubun rengini gösterir. IDE veya Cockpit kapalıyken Mimir **son anlık görüntüyü** gösterir; hiç hesap bilgisi yoksa kart **Antigravity veya Cockpit'i aç** notunu verir.

| Belirti | Olası neden / çözüm |
|---|---|
| "Antigravity veya Cockpit'i aç" notu | Hesap bilgisi okunamadı — IDE'yi veya Cockpit'i açın |
| Veri soluk görünüyor | IDE/Cockpit kapandı; son snapshot gösteriliyor |
| Kotalar beklenenden farklı | Antigravity grup havuzu mantığı kullanır; per-model değil grup bazında okuyun |

> 🔒 **Gizlilik:** Tüm okuma yereldir/yetkili uç noktalarladır; veriniz yalnızca makinenizde işlenir, hiçbir üçüncü tarafa gönderilmez. Bkz. [Gizlilik ve Güvenlik](PRIVACY.md).
