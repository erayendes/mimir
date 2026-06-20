# Privacy & Security / Gizlilik ve Güvenlik

🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

> [Documentation](README.md) · Previous: [← Services](SERVICES.md)

---

## English

Mimir is designed to be **privacy-first**. The core principle is simple:

> **No personal data or API key ever leaves your machine to reach Mimir's servers** — because Mimir has no such servers.

### What Mimir reads

Mimir reads only **local** sources:

- The AI tools' config/log files: `~/.claude`, `~/.codex`, etc.
- Entries in the macOS **Keychain** created by the respective apps (tokens).

This is data your tools **already** create on your machine; Mimir only reads it.

### Where data goes

Mimir only makes requests to each service's **own official endpoint**, with **that service's own token** (to fetch usage info):

- Anthropic's OAuth usage endpoint for Claude
- The ChatGPT usage API for Codex
- Google Cloud Code authorized endpoints for Antigravity

These requests are the same kind the tool itself would make. **Mimir inserts no server of its own** and relays data to no third party.

### Token handling

- Tokens are kept **in memory** as much as possible; the Keychain (and its permission prompt) is touched only at startup and around token expiry.
- When the Claude token expires, Mimir refreshes it and **writes the new pair back to the Keychain** — so it doesn't break the tool's own session.
- A rejected (401/403) token is dropped from the cache; a dead token is not retried over and over.

### Crash/diagnostic data

To monitor app stability, crash/diagnostic reporting (Sentry) is included. It does **not** contain your usage quota or tokens; it is limited to data about the app's technical health.

### Open source

Mimir is open source (MIT). You can verify all of the above in the source code:

**[github.com/erayendes/mimir →](https://github.com/erayendes/mimir)**

---

## Türkçe

Mimir, **gizlilik odaklı** tasarlanmıştır. Temel ilke basittir:

> **Hiçbir kişisel veri veya API anahtarı, makinenizden çıkıp Mimir'in sunucularına gitmez** — çünkü Mimir'in böyle bir sunucusu yoktur.

### Mimir ne okur?

Mimir yalnızca **yerel** kaynakları okur:

- AI araçlarının yapılandırma/log dosyaları: `~/.claude`, `~/.codex` vb.
- macOS **Keychain**'de ilgili uygulamaların oluşturduğu kayıtlar (token'lar).

Bu veriler, kullandığınız araçların makinenizde **zaten** oluşturduğu verilerdir; Mimir bunları sadece okur.

### Veri nereye gider?

Mimir yalnızca, ilgili servisin **kendi resmî uç noktasına**, **o servisin kendi token'ıyla** istek atar (kullanım bilgisini almak için):

- Claude için Anthropic'in OAuth kullanım uç noktası
- Codex için ChatGPT kullanım API'si
- Antigravity için Google Cloud Code yetkili uç noktaları

Bu istekler, aracın kendisinin yapacağı isteklerle aynı niteliktedir. **Mimir araya kendi sunucusunu sokmaz**, veriyi hiçbir üçüncü tarafa iletmez.

### Token yönetimi

- Token'lar mümkün olduğunca **bellekte** tutulur; Keychain'e (ve onun izin istemine) yalnızca başlangıçta ve token süresi dolmaya yakınken dokunulur.
- Claude token'ı süresi dolduğunda Mimir onu yeniler ve **yeni çiftini Keychain'e geri yazar** — böylece aracın kendi oturumunu bozmaz.
- Reddedilen (401/403) bir token önbellekten düşürülür; ölü token tekrar tekrar denenmez.

### Hata/teşhis verisi

Uygulamanın kararlılığını izlemek için çökme/teşhis raporlaması (Sentry) bulunur. Bu, kullanım kotanızı veya token'larınızı **içermez**; uygulamanın teknik sağlığına ilişkin verilerle sınırlıdır.

### Açık kaynak

Mimir açık kaynaktır (MIT). Yukarıdakilerin tümünü kaynak kodunda doğrulayabilirsiniz:

**[github.com/erayendes/mimir →](https://github.com/erayendes/mimir)**
