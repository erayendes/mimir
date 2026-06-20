# Menü çubuğunu okuma

> [İçindekiler](README.md) · Önceki: [← Kurulum](kurulum.md) · Sonraki: [Servisler → Claude →](servisler/claude.md)

Mimir'in tüm arayüzü menü çubuğunda yaşar: küçük bir **Mimir simgesi** ve onun yanında dikey bir **renkli nokta sütunu**.

![Mimir popover](../assets/popover.png)

## Renkli noktalar

Simgenin yanındaki her nokta, **5 saatlik seans penceresine** sahip bir servisi temsil eder ve yukarıdan aşağıya şu sırayla dizilir:

1. **Claude**
2. **Codex**
3. **Antigravity** (iki grup kotası vardır — Gemini ve Claude/GPT; nokta **en kısıtlı** olanı yansıtır)

> 📝 **Not:** Yalnızca o an **aktif seans okuması olan** servisler için nokta gösterilir. Kurulu olmayan veya güncel okuması bulunmayan servisler için gri yer tutucu **konmaz** — yani nokta sayısı kullandığınız LLM sayısına eşittir.

### Nokta renkleri

Renk, ilgili servisin 5 saatlik penceresinde **kalan yüzdeye** göre belirlenir:

| Renk | Kalan kota | Anlamı |
|:---:|---|---|
| 🟢 **Yeşil** | %50 – %100 | Bol miktarda hakkınız var |
| 🟡 **Amber** | %15 – %49 | Azalıyor, dikkat |
| 🔴 **Kırmızı** | %15'in altı | Limite yaklaşıldı |

## Açılır pencere (popover)

Menü çubuğu simgesine tıklayınca **açılır pencere** gelir. Her servis bir **kart** olarak gösterilir:

- **Servis adı ve marka ikonu**
- **Seans (5 saatlik) kotası** — belirgin şekilde, yüzde ve geri sayımla
- **Haftalık kota** — varsa özet satır
- **Model satırları** — servise göre per-model kota veya kredi bakiyesi
- **(i) bilgi simgesi** — verinin nereden alındığını ve nasıl tazeleneceğini açıklar
- **Durum notu** — örn. *"token süresi doldu — Claude Code'u aç"* gibi yapılması gerekeni söyler

### Geri sayım biçimi

Yenilenme süreleri kısa birimlerle gösterilir (Türkçe arayüzde): **g** (gün), **s** (saat), **d** (dakika). Örnek: `2s 15d` → 2 saat 15 dakika sonra sıfırlanır.

## Yenileme

- Mimir verileri **dakikada bir otomatik** yeniler.
- Açılır pencereyi her açtığınızda da bir yenileme tetiklenir.
- Bir servis hız sınırına (HTTP 429) takılırsa Mimir geri çekilir (cooldown) ve o servisi bir süre sorgulamayı bırakır; bu sırada **son bilinen veriyi** gösterir.

## "Eski veri" (stale) durumu

Canlı kaynak ortadan kalktığında (ör. Antigravity IDE'si kapandı) servis **kaybolmaz** — Mimir kartı son anlık görüntüyle **soluk** (dimmed) gösterir. Böylece "servis aniden yok oldu" yerine elinizdeki son bilgiyi görürsünüz.

---

Servislerin tek tek nasıl beslendiğini öğrenmek için → **[Servisler: Claude](servisler/claude.md)**.
