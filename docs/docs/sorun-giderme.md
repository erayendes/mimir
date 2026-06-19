---
id: sorun-giderme
title: Sorun Giderme
sidebar_label: Sorun Giderme
description: Mimir'de sık karşılaşılan durumlar ve çözümleri.
---

# Sorun Giderme

## Bir servis hiç görünmüyor

Mimir, servisleri ilgili aracın **yerel verisinden** okur. Servis kartı yoksa o araca büyük olasılıkla hiç giriş yapılmamıştır.

- **Claude** → Claude Code'u açıp giriş yapın (`~/.claude` oluşur).
- **Codex** → Codex'i bir kez kullanın (`~/.codex/sessions` oluşur).
- **Antigravity** → Antigravity IDE'sini veya Cockpit'i açın.

## "token süresi doldu — Claude Code'u aç" notu

Claude token'ı yenilenemedi. **Claude Code'u açıp** oturumun geçerli olduğundan emin olun; Mimir bir sonraki yenilemede tekrar veri çeker. Ayrıntı: [Claude](./servisler/claude.md#token-yenileme).

## "Antigravity veya Cockpit'i aç" notu

Antigravity hesap bilgisi okunamadı. **IDE'yi veya Cockpit'i** açın. Kapalıyken Mimir son anlık görüntüyü (soluk) gösterir. Ayrıntı: [Antigravity](./servisler/antigravity.md).

## Veri eski / soluk görünüyor

Bu normaldir. Canlı kaynak geçici olarak erişilemediğinde (kapalı IDE, hız sınırı, ağ hatası) Mimir servisi kaybetmek yerine **son bilinen veriyi** gösterir. Kaynak geri geldiğinde otomatik tazelenir.

## Limit göstergesi güncellenmiyor

- Mimir **dakikada bir** yeniler; açılır pencereyi açmak da yenileme tetikler.
- Servis hız sınırına (HTTP 429) takıldıysa Mimir geçici olarak **geri çekilir** (cooldown) ve bu sırada eski veriyi gösterir.

## Menü çubuğunda nokta yok

Nokta yalnızca **aktif seans okuması olan** servisler için gösterilir. Hiç AI aracı kullanımınız okunamıyorsa nokta da olmaz — ilgili araçlara giriş yaptığınızdan emin olun.

## Uygulama açılışta başlamıyor

İlk açılıştaki "açılışta başlat" iznini reddettiyseniz: **Sistem Ayarları › Genel › Açılış Öğeleri** (Login Items) altından Mimir'i ekleyin.

## Gatekeeper uyarısı (kaynaktan derleme)

Dağıtılan `.dmg` sürümleri notarize edilmiştir ve uyarı vermez. **Kaynaktan** derlediğiniz yapı yalnızca ad-hoc imzalı olabilir; bu durumda Gatekeeper uyarısı normaldir. Dağıtım için [Releases](https://github.com/erayendes/mimir/releases) sayfasındaki sürümü kullanın.

## Sorun çözülmediyse

[GitHub Issues](https://github.com/erayendes/mimir/issues) üzerinden bir kayıt açın. Mümkünse log akışıyla yeniden üretin:

```bash
./script/build_and_run.sh logs
```
