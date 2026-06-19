---
id: claude
title: Claude
sidebar_label: Claude
description: Mimir'in Claude Code kullanım limitlerini nasıl okuduğu ve gösterdiği.
---

# Claude

Mimir, **Claude Code**'un kullanım limitlerini gösterir: seans (5 saatlik) ve haftalık pencereler ile yenilenme zamanları.

## Veri kaynağı

Mimir, Claude Code'un makinenizde oluşturduğu **OAuth token'ını** kullanarak Anthropic'in resmî kullanım uç noktasını sorgular:

```
GET https://api.anthropic.com/api/oauth/usage
```

- Token, Claude Code'un `~/.claude` altındaki kayıtlarından / macOS **Keychain**'den okunur.
- Yanıt, 5 dakikalık bir **önbelleğe** alınır; böylece Keychain'e (ve onun izin istemine) yalnızca uygulama başlarken ve token'ın süresi dolmaya yakınken dokunulur.

## Token yenileme

Anthropic, **refresh token**'ı döndürür (rotation). Token'ın süresi dolmuşsa veya dolmasına 5 dakikadan az kalmışsa Mimir token'ı proaktif olarak yeniler ve **yeni çiftini Keychain'e geri yazar** — böylece Claude Code'un kendi oturumu da geçerli kalır.

Yenileme başarısız olursa kart şu notu gösterir:

> **token süresi doldu — Claude Code'u aç**

Bu durumda Claude Code'u bir kez açıp giriş yapmanız yeterlidir; Mimir bir sonraki yenilemede tekrar veri çekecektir.

## Gösterilen bilgiler

- **Seans (5 saatlik) kalan yüzdesi** ve sıfırlanma zamanı
- **Haftalık kalan yüzdesi** ve sıfırlanma zamanı
- Menü çubuğundaki **Claude noktası** seans yüzdesine göre renklenir

## Sık karşılaşılanlar

| Belirti | Olası neden / çözüm |
|---|---|
| Claude kartı yok | Claude Code'a hiç giriş yapılmamış olabilir — bir kez açıp giriş yapın |
| "token süresi doldu" notu | Claude Code'u açın; token yenilenince düzelir |
| Veri donuk / soluk | Geçici hata ya da hız sınırı; Mimir son bilinen veriyi gösterir, kısa süre sonra yeniler |

:::info Gizlilik
Token ve kullanım verisi yalnızca makinenizde işlenir; Anthropic dışındaki hiçbir sunucuya gönderilmez. Bkz. [Gizlilik ve Güvenlik](../gizlilik.md).
:::
