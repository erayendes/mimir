🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

### Support

#### Frequently Asked Questions

**The app doesn't appear in the menu bar.**
Check Activity Monitor to see if Mimir is running. The app requires macOS 14.0 or later.

**Claude limits are not showing.**
Sign in to Claude Code or the Claude desktop app once — Mimir reads the records they create under `~/.claude` and the macOS Keychain. If the card says *token expired — open Claude Code*, opening Claude Code once refreshes it.

**The ChatGPT card looks wrong or out of date.**
Mimir asks the ChatGPT usage API first and falls back to the local session files under `~/.codex`. If the API is briefly unreachable, the card is dimmed and shows the last-known reading rather than vanishing. Signing in to Codex again refreshes an expired token.

**Antigravity says "open Antigravity or Cockpit".**
The quota is read from the running Antigravity language server or Cockpit, so one of them has to have been open at least once — there are no Google Cloud credentials to configure. With both closed, Mimir shows the last snapshot until its reset time passes.

**A card is dimmed, or a "couldn't fetch" notice appears at the top.**
The live source has been unreachable long enough that the last reading is no longer trustworthy. Both clear on their own once that provider reports data again. Dismiss the notice with the × in its corner if you'd rather not see it.

---

If your issue isn't listed here, [open an issue](https://github.com/erayendes/mimir/issues) and we'll get back to you as soon as possible.

---

## Türkçe

### Destek

#### Sık Sorulan Sorular

**Uygulama menü çubuğunda görünmüyor.**
Aktivite Monitörü'nden Mimir'in çalışıp çalışmadığını kontrol edin. Uygulama macOS 14.0 ve üzerini gerektirir.

**Claude limitleri gösterilmiyor.**
Claude Code'a veya Claude masaüstü uygulamasına bir kez giriş yapın — Mimir bu araçların `~/.claude` altında ve macOS Keychain'de oluşturduğu kayıtları okur. Kart *token süresi doldu — Claude Code'u aç* diyorsa, Claude Code'u bir kez açmak yeterlidir.

**ChatGPT kartı yanlış ya da eski görünüyor.**
Mimir önce ChatGPT kullanım API'sini sorgular, olmazsa `~/.codex` altındaki yerel oturum dosyalarına düşer. API kısa süreliğine erişilemezse kart kaybolmaz; soluk hâlde son bilinen okumayı gösterir. Süresi dolmuş bir token için Codex'e yeniden giriş yapın.

**Antigravity "Antigravity veya Cockpit'i aç" diyor.**
Kota, çalışan Antigravity dil sunucusundan veya Cockpit'ten okunur; bu yüzden ikisinden birinin en az bir kez açılmış olması gerekir — yapılandırılacak bir Google Cloud kimlik bilgisi yoktur. İkisi de kapalıyken Mimir, sıfırlanma zamanı geçene kadar son anlık görüntüyü gösterir.

**Kart soluk görünüyor ya da üstte "veri alınamadı" uyarısı çıktı.**
Canlı kaynağa yeterince uzun süre ulaşılamadı; son okuma artık güvenilir sayılmıyor. O sağlayıcı tekrar veri verdiğinde ikisi de kendiliğinden düzelir. Uyarıyı görmek istemiyorsanız köşesindeki × ile kapatabilirsiniz.

---

Sorununuz burada yoksa [issue açın](https://github.com/erayendes/mimir/issues) — mümkün olan en kısa sürede yanıt verilecektir.
