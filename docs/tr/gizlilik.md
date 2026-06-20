# Gizlilik ve Güvenlik

> [İçindekiler](README.md) · Önceki: [← Menü çubuğu](menu-cubugu.md)

Mimir, **gizlilik odaklı** tasarlanmıştır. Temel ilke basittir:

> **Hiçbir kişisel veri veya API anahtarı, makinenizden çıkıp Mimir'in sunucularına gitmez** — çünkü Mimir'in böyle bir sunucusu yoktur.

## Mimir ne okur?

Mimir yalnızca **yerel** kaynakları okur:

- AI araçlarının yapılandırma/log dosyaları: `~/.claude`, `~/.codex` vb.
- macOS **Keychain**'de ilgili uygulamaların oluşturduğu kayıtlar (token'lar).

Bu veriler, kullandığınız araçların makinenizde **zaten** oluşturduğu verilerdir; Mimir bunları sadece okur.

## Veri nereye gider?

Mimir yalnızca, ilgili servisin **kendi resmî uç noktasına**, **o servisin kendi token'ıyla** istek atar (kullanım bilgisini almak için):

- Claude için Anthropic'in OAuth kullanım uç noktası
- Codex için ChatGPT kullanım API'si
- Antigravity için Google Cloud Code yetkili uç noktaları

Bu istekler, aracın kendisinin yapacağı isteklerle aynı niteliktedir. **Mimir araya kendi sunucusunu sokmaz**, veriyi hiçbir üçüncü tarafa iletmez.

## Token yönetimi

- Token'lar mümkün olduğunca **bellekte** tutulur; Keychain'e (ve onun izin istemine) yalnızca başlangıçta ve token süresi dolmaya yakınken dokunulur.
- Claude token'ı süresi dolduğunda Mimir onu yeniler ve **yeni çiftini Keychain'e geri yazar** — böylece aracın kendi oturumunu bozmaz.
- Reddedilen (401/403) bir token önbellekten düşürülür; ölü token tekrar tekrar denenmez.

## Hata/teşhis verisi

Uygulamanın kararlılığını izlemek için çökme/teşhis raporlaması (Sentry) bulunur. Bu, kullanım kotanızı veya token'larınızı **içermez**; uygulamanın teknik sağlığına ilişkin verilerle sınırlıdır.

## Açık kaynak

Mimir açık kaynaktır (MIT). Yukarıdakilerin tümünü kaynak kodunda doğrulayabilirsiniz:

**[github.com/erayendes/mimir →](https://github.com/erayendes/mimir)**
