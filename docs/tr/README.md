# Mimir Dokümantasyonu

🇹🇷 Türkçe · [🇬🇧 English](../en/README.md) · [↑ Dil seçimi](../README.md)

**Mimir**, kullandığınız yapay zekâ araçlarının — **Claude**, **Codex**, **Gemini** ve **Antigravity** — kullanım limitlerini ve yenilenme sürelerini iş akışınızı bölmeden **macOS menü çubuğundan** anlık olarak gösteren hafif bir uygulamadır.

![Mimir menü çubuğu popover'ı](../assets/popover.png)

Bir terminal komutu çalıştırıp limitinize takılmak yerine, menü çubuğundaki küçük göstergeye bakıp ne kadar hakkınız kaldığını ve limitin ne zaman sıfırlanacağını anında görürsünüz.

## İçindekiler

1. [Kurulum](kurulum.md)
2. [Menü çubuğunu okuma](menu-cubugu.md)
3. **Servisler**
   - [Claude](servisler/claude.md)
   - [Codex](servisler/codex.md)
   - [Antigravity](servisler/antigravity.md)
4. [Gizlilik ve Güvenlik](gizlilik.md)

Ayrıca: [Destek & SSS](../../SUPPORT.md) · [Katkıda Bulunma](../../CONTRIBUTING.md) · [Sürüm Notları](../../CHANGELOG.md)

## Öne çıkan özellikler

- **Tek bakışta menü çubuğu** — tüm AI servislerinizin durumu tek bir küçük göstergede ve açılır pencerede (popover).
- **Canlı limitler** — Claude seans limitleri, Codex kredileri/kotaları ve Antigravity grup kotaları gerçek zamanlı izlenir.
- **Geri sayım** — her limitin tam olarak ne zaman yenileneceği gösterilir.
- **Renkli durum göstergeleri** — kalan kotaya göre yeşil / amber / kırmızı noktalar.
- **Minimalist tasarım** — monokrom ikon, macOS açık/koyu temaya tam uyum.
- **Gizlilik odaklı** — yalnızca yerel uygulama ayarlarını ve macOS Keychain'i okur; [hiçbir veri makinenizden çıkmaz](gizlilik.md).

## Desteklenen servisler

| Servis | Veri kaynağı | Detay |
|---|---|---|
| **Claude** | Claude Code OAuth (`~/.claude`) | [Claude →](servisler/claude.md) |
| **Codex** | ChatGPT kullanım API'si + yerel `~/.codex` JSONL yedeği | [Codex →](servisler/codex.md) |
| **Antigravity** | Yerel dil sunucusu + Cockpit hesabı | [Antigravity →](servisler/antigravity.md) |

## Nasıl çalışır? (kısa)

Mimir, çalışan/kurulu AI araçlarının makinenizde zaten oluşturduğu **yerel verileri** okur:

1. İlgili aracın yapılandırma dosyalarını (`~/.claude`, `~/.codex` vb.) ve macOS **Keychain** kayıtlarını okur.
2. Mümkün olduğunda servisin **resmî kullanım API'sini** (aracın kendi token'ıyla) sorgular.
3. Sonucu menü çubuğunda gösterir ve **dakikada bir** otomatik yeniler.

Canlı kaynak geçici olarak kullanılamadığında (ör. Antigravity IDE'si kapalıyken) Mimir, servisi tamamen kaybetmek yerine **son bilinen anlık görüntüyü** (snapshot) gösterir.

## Gereksinimler

- **macOS 14.0 (Sonoma)** veya üzeri
- Kaynaktan derlemek için **Swift 6.0+**

---

Hazırsanız → **[Kurulum](kurulum.md)** ile devam edin.
