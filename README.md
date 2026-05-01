# Mimir

Mimir, modern yapay zeka araçlarının (Claude, Codex, Gemini ve Antigravity) kullanım limitlerini ve yenilenme sürelerini macOS menü barınızdan anlık olarak takip etmenizi sağlayan şık ve hafif bir uygulamadır.

![Mimir Menu Bar](Sources/Mimir/Resources/AppIcon.png)

## Özellikler

- **Menü Bar Takibi:** Tüm AI servislerinizin durumunu popover penceresiyle tek bakışta görün.
- **Anlık Limitler:** Claude seans limitleri, Codex kredileri ve Gemini kota bilgilerini anlık olarak izleyin.
- **Geri Sayım:** Limitlerinizin tam olarak ne zaman yenileneceğini (reset zamanı) görün.
- **Minimalist Tasarım:** macOS sistem temasıyla tam uyumlu, monokrom ikon ve modern arayüz.
- **Güvenli:** Kişisel API anahtarlarınızı kodun içinde tutmaz; yerel uygulama yapılandırmalarınızı ve Keychain'i kullanarak verileri çeker.

## Desteklenen Servisler

- **Claude:** Claude Code ve OAuth kullanımı üzerinden seans ve haftalık limit takibi.
- **Codex:** Yerel seans kayıtları üzerinden premium kredi ve limit takibi.
- **Gemini:** Google Cloud Quota API entegrasyonu ile Pro ve Flash modellerinin takibi.
- **Antigravity:** Yerel dil sunucusu (Language Server) ve Cockpit entegrasyonu ile model bazlı takip.

## Kurulum

### Gereksinimler
- macOS 14.0+
- Swift 6.0+

### Derleme ve Yükleme
Projeyi klonladıktan sonra terminal üzerinden şu komutla doğrudan Uygulamalar klasörünüze kurabilirsiniz:

```bash
./script/build_and_run.sh install
```

Bu komut uygulamayı derleyecek, ikonlarını paketleyecek ve `/Applications/Mimir.app` yoluna taşıyacaktır.

## Gizlilik ve Güvenlik

Mimir, hiçbir kişisel verinizi veya API anahtarınızı uzak sunuculara göndermez. Tüm veri çekme işlemleri bilgisayarınızda yerel olarak gerçekleşir. Uygulama, kullandığınız araçların yerel log dosyalarını (`~/.codex`, `~/.claude` vb.) ve macOS Keychain'i okuyarak çalışır.

## Lisans

Bu proje kişisel kullanım için geliştirilmiştir. Tüm hakları saklıdır.
