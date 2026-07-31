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

This app runs entirely locally and sends no data over the network. Security concerns typically relate to:

- Local file access (`~/.claude`, `~/.codex`, etc.)
- macOS Keychain read operations
- Antigravity / Gemini API token handling

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

Bu proje macOS'ta yerel olarak çalışır ve ağ üzerinden herhangi bir veri göndermez. Güvenlik endişeleri genellikle şu konularla ilgilidir:

- Yerel dosya erişimi (`~/.claude`, `~/.codex` vb.)
- macOS Keychain okuma işlemleri
- Antigravity / Gemini API token yönetimi
