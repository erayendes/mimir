# Codex

> [İçindekiler](../README.md) · Servisler: [Claude](claude.md) · **Codex** · [Antigravity →](antigravity.md)

Mimir, **Codex** için seans ve haftalık kotaları gösterir. İki kaynağı sırayla dener.

## Veri kaynağı

Mimir önce **canlı ChatGPT kullanım API'sini** sorgular. Başarısız olursa, Codex'in yerel oturum kayıtlarına geri düşer:

1. **ChatGPT kullanım API'si** (canlı) — birincil kaynak.
2. **Yerel `~/.codex/sessions` JSONL yedeği** — API erişilemezse.
3. Her ikisi de başarısız olursa **son bilinen anlık görüntü** (snapshot).

### Yerel yedek nasıl okunur?

`~/.codex/sessions` altındaki **en güncel `.jsonl` dosyası** sondan başa doğru taranır. Mimir, `token_count` olaylarındaki `rate_limits` alanından:

- **primary** → seans (5 saatlik) penceresi
- **secondary** → haftalık pencere

değerlerini çıkarır ve kalan yüzdeleri ile sıfırlanma zamanlarını hesaplar.

> 📝 **Not:** Yerel dosyada sıfırlanma zamanı bulunamazsa kart yine kalan yüzdeyi gösterir, ancak geri sayım gösterilmeyebilir (kart bunu bir notla belirtir).

## Gösterilen bilgiler

- **Seans (5 saatlik) kalan yüzdesi** ve sıfırlanma zamanı
- **Haftalık kalan yüzdesi** ve sıfırlanma zamanı
- Uygun olduğunda **kredi bakiyesi** gibi değer satırları (yüzde olmayan bu satırlar için Mimir, eşik altına inildiğinde düşük-kota rozetini tetikler)

## Sık karşılaşılanlar

| Belirti | Olası neden / çözüm |
|---|---|
| Codex kartı yok | `~/.codex` altında oturum kaydı yok — Codex'i bir kez kullanın |
| Geri sayım görünmüyor | Yerel dosyada sıfırlanma zamanı bulunamadı; yüzde yine de gösterilir |
| Veri eski | API erişilemiyor olabilir; Mimir yerel yedeği veya son snapshot'ı gösterir |

> 🔒 **Gizlilik:** Tüm okuma yereldir. Bkz. [Gizlilik ve Güvenlik](../gizlilik.md).
