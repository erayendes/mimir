🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

### Security Policy

#### Supported Versions

| Version | Support |
|---|---|
| 1.1.x | Active |
| 1.0.x | Critical patches only |
| < 1.0 | No support |

#### Reporting a Vulnerability

Mimir accesses macOS Keychain and local log files, so we take security issues seriously.

**Please do not disclose security vulnerabilities publicly.**

Instead, send an email directly to [erayendes@gmail.com](mailto:erayendes@gmail.com). We aim to respond within 48 hours.

Please include:

- The type of vulnerability (e.g. unauthorized Keychain access, local file read)
- Steps required to trigger it
- Potential impact

#### Scope

The app runs on your machine and has no backend of its own, but it is not offline: it
calls each provider's own usage endpoint with that provider's own token, and sends crash
and anonymous usage telemetry. See [Privacy & Security](../docs/README.md#privacy--security) for the full
list. Security concerns typically relate to:

- Local file access (`~/.claude`, `~/.codex`, etc.)
- macOS Keychain read operations, and reading the Claude desktop app's session cookie
- Token handling for the Anthropic, ChatGPT and Google Cloud Code endpoints
- The release pipeline (signing, notarization, the Sparkle update feed)

---

## Türkçe

### Güvenlik Politikası

#### Desteklenen Sürümler

| Sürüm | Destek durumu |
|---|---|
| 1.x | Aktif destek |
| 1.0.x | Kritik yamalar |
| < 1.0 | Destek yok |

#### Güvenlik Açığı Bildirimi

Mimir, macOS Keychain ve yerel log dosyalarına eriştiğinden güvenlik açıklarını ciddiye alıyoruz.

**Bir güvenlik açığı keşfettiyseniz lütfen bunu kamuya açık olarak paylaşmayın.**

Bunun yerine doğrudan [erayendes@gmail.com](mailto:erayendes@gmail.com) adresine e-posta gönderin. 48 saat içinde yanıt vermeye çalışırız.

Bildiriminizde şunları belirtin:

- Açığın türü (örn. yetkisiz Keychain erişimi, yerel dosya okuma)
- Açığı tetiklemek için gereken adımlar
- Olası etkisi

#### Kapsam

Mimir macOS'ta yerel çalışır ve **kendi arka uç sunucusu yoktur** — kotalarınız ve token'larınız bize ait bir sunucuya gitmez. Ağ trafiği üç grupla sınırlıdır:

1. **Sağlayıcıların kendi kota uç noktaları**, o sağlayıcının kendi token'ıyla — Anthropic, OpenAI, Google. Aracın kendisinin yapacağı isteklerle aynı nitelikte.
2. **Çökme raporları** (Sentry, yayınlanan sürümlerde açık) ve **anonim kategorik kullanım sinyalleri** (TelemetryDeck, popover menüsünden kapatılabilir). İkisi de kota değeri, token veya hesap bilgisi taşımaz.
3. **Sparkle güncelleme akışı** (`appcast.xml`).

Tam döküm: [Gizlilik ve Güvenlik](../docs/README.md#gizlilik-ve-güvenlik).

Güvenlik endişeleri genellikle şu konularla ilgilidir:

- Yerel dosya erişimi (`~/.claude`, `~/.codex` vb.)
- macOS Keychain okuma işlemleri
- Antigravity / Gemini API token yönetimi
- Yukarıdaki uç noktalara giden isteklerin içeriği
