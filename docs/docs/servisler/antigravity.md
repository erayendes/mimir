---
id: antigravity
title: Antigravity
sidebar_label: Antigravity
description: Mimir'in Antigravity grup kotalarını (Gemini / Claude+GPT) nasıl okuduğu.
---

# Antigravity

Mimir, **Antigravity** için grup bazlı kotaları gösterir. Antigravity kotayı artık per-model değil, **paylaşılan grup havuzları** üzerinden yönetir:

- **Gemini** grubu
- **Claude + GPT** grubu

Her grubun bir **haftalık** ve bir **5 saatlik** penceresi vardır.

## Veri kaynağı

Mimir aşağıdaki kaynakları sırayla dener ve ilk başarılı olanı kullanır:

1. **Grup kota özeti** — IDE'nin "Model Quota" sayfasını besleyen, gruplanmış haftalık + 5 saatlik özet (birincil canlı kaynak).
2. **Cloud Code yetkili API'si** — Cockpit hesabınızın token'ıyla `fetchAvailableModels` çağrısı.
3. **Cockpit önbelleği** — yerel olarak saklanan son yetkili veri.
4. **Yerel dil sunucusu** (language server) verisi.
5. **Son anlık görüntü** (snapshot) — IDE/Cockpit kapalıysa, sıfırlanma zamanı geçene kadar geçerli.

## Menü çubuğundaki nokta

Antigravity'nin **iki seans grubu** olduğundan (Gemini, Claude/GPT), menü çubuğundaki tek Antigravity noktası **en kısıtlı** grubun rengini gösterir. Böylece "hangisi olursa olsun en yakın limit" tek bakışta görünür.

## Canlı kaynak kapandığında

Antigravity IDE'si veya Cockpit kapalıyken canlı veri alınamaz. Bu durumda:

- Mimir, açıkken yakaladığı **son anlık görüntüyü** gösterir (sıfırlanma zamanı geçene kadar).
- Hiç hesap bilgisi yoksa kart şu notu verir:

  > **Antigravity veya Cockpit'i aç**

## Sık karşılaşılanlar

| Belirti | Olası neden / çözüm |
|---|---|
| "Antigravity veya Cockpit'i aç" notu | Hesap bilgisi okunamadı — IDE'yi veya Cockpit'i açın |
| Veri soluk görünüyor | IDE/Cockpit kapandı; son snapshot gösteriliyor |
| Kotalar beklenenden farklı | Antigravity grup havuzu mantığı kullanır; per-model değil grup bazında okuyun |

:::info Gizlilik
Token alışverişi ve okuma yereldir/yetkili uç noktalarladır; kişisel veriniz üçüncü taraflara gönderilmez. Bkz. [Gizlilik ve Güvenlik](../gizlilik.md).
:::
