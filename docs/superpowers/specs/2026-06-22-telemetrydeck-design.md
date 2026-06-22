# Tasarım: TelemetryDeck Entegrasyonu (anonim kullanım istatistikleri)

**Tarih:** 2026-06-22
**Dal:** `feat/telemetrydeck` (main'den)
**Durum:** Onaylandı, implementasyon planı bekleniyor

## Amaç

Mimir için anonim, gizlilik-dostu kullanım istatistikleri toplamak: kaç kullanıcı,
hangi sürüm/macOS, hangi sağlayıcılar kullanılıyor, widget'lar gerçekten kullanılıyor mu,
kullanıcılar güncel kalıyor mu. Sentry (hata/çökme) bunu kapsamaz; bu, **kullanım** içindir.

Mimir gizlilik-odaklı bir uygulama (kota/kimlik verisiyle çalışır). Bu yüzden telemetri
**anonim**, **opt-out** ve **kategorik** (değer içermez) olacak.

## Karar Özeti (kullanıcı onaylı)

- **SDK:** TelemetryDeck SwiftSDK (`https://github.com/TelemetryDeck/SwiftSDK`). Anonim,
  GDPR-uyumlu, IP saklamaz, kurulum başına hash'lenmiş anonim kimlik üretir.
- **İzin modeli:** **Opt-out** — varsayılan açık, kullanıcı kapatabilir.
- **Kapatma yeri:** Menü-çubuğu ikonuna **sağ-tık menüsü** (uygulamada ayar ekranı yok).
- **Sinyaller:** sağlayıcı kullanımı, widget kullanımı, güncelleme etkileşimi (+ SDK'nın
  otomatik topladığı açılış/sürüm/OS/dil).
- **Dev/prod ayrımı:** Sentry deseninin aynısı — `.dev` bundle id'li build'ler hiç göndermez.

## Gizlilik Garantileri (load-bearing)

Asla gönderilmeyecek: kota yüzdeleri, sıfırlanma süreleri/saatleri, kredi bakiyeleri,
hesap kimlikleri/e-posta, token'lar, dosya yolları, herhangi bir PII.

Gönderilecek: yalnızca kategorik var/yok ve sayım bilgisi (hangi sağlayıcı aktif,
hangi widget boyutu yerleştirilmiş). Anonim kimlik TelemetryDeck varsayılanı — özel
kimlik atanmaz. Opt-out → init yok, gönderim yok. Dev build → hiç gönderim yok.

## Mimari

### `Sources/Mimir/Telemetry.swift` (yeni — ince sarmalayıcı)

Tüm telemetri tek bir kapıdan geçer; çağrı yerleri SDK'yı doğrudan bilmez.

- `Telemetry.enabled: Bool` — `UserDefaults.standard` `"telemetry.enabled"` anahtarı,
  **varsayılan `true`** (anahtar yoksa açık = opt-out).
- `Telemetry.start()` — yalnızca `shouldSend` doğruysa `applicationDidFinishLaunching`'te
  SDK'yı başlatır (App ID ile). Birden çok kez güvenle çağrılabilir (idempotent).
- `Telemetry.signal(_ name: String, parameters: [String: String] = [:])` — göndermeden
  önce `shouldSend` kapısını uygular.
- `Telemetry.setEnabled(_ on: Bool)` — anahtarı yazar; `true`'ya çevrilince `start()` çağırır,
  `false`'ta sonraki gönderimler bastırılır.
- `shouldSend(isDev: Bool, enabled: Bool) -> Bool` — **saf fonksiyon** (`!isDev && enabled`),
  unit-test edilir. `isDev` = bundle id `.dev` ile bitiyor mu.
- **App ID:** dosyada sabit (gizli değil, istemciye gömülür — Sentry DSN gibi). Kullanıcı
  telemetrydeck.com'da app oluşturup UUID'yi verir. → **Prerequisite.**

### Sağlayıcı / widget sinyal üreticileri (saf, testable)

- `providerParameters(from services: [ServiceStatus]) -> [String: String]` — Mimir target'ında
  (modeli görür). Çıktı: `["claude": "true"/"false", "codex": ..., "antigravity": ...]`.
  `isAvailable || isStale` ölçütüyle "aktif" sayar. **Hiçbir yüzde/değer içermez.**
- `widgetParameters(families:) -> [String: String]` — yerleştirilmiş widget boyutlarının
  sayımı (örn. `["small":"1","medium":"0",...]`). Girdi `WidgetCenter`'dan alınır (yan etki
  ayrı), üretici saf.

### Sağ-tık menüsü (`Sources/Mimir/MimirApp.swift` + küçük yardımcı)

`NSMenu`:
- `Anonim istatistik gönder` — `state = enabled ? .on : .off`; tıklayınca `setEnabled(!enabled)`
  + `update.toggled` sinyali (yalnızca açıkken anlamlı; kapatınca son sinyal gitmez).
- ─────
- `Güncellemeleri denetle` → mevcut `updaterController.checkForUpdates(nil)` + `update.checkRequested` sinyali.
- `Mimir'den Çık` → `NSApp.terminate(nil)` (şu an çıkış afförderi yok; bu boşluğu doldurur).

**Sol/sağ tık ayrımı:** status item butonu `sendAction(on: [.leftMouseUp, .rightMouseUp])`.
`togglePopover`'da `NSApp.currentEvent?.type == .rightMouseUp` ise menüyü göster
(`statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil`), değilse mevcut
popover davranışı. (Kalıcı `statusItem.menu` atanırsa sol tık da menü açar — bu yüzden geçici atama.)

## Veri Akışı

1. **Açılış** (`applicationDidFinishLaunching`): `isDevBuild` değilse ve `enabled` ise
   `Telemetry.start()`. SDK otomatik açılış/sürüm/OS/dil sinyalini gönderir.
2. **Açılış sonrası**: `WidgetCenter.shared.getCurrentConfigurations` → `widget.installed`
   sinyali (widget'lar yerel/anlık).
3. **3. yenileme**: mevcut `store.$services` sink'inde bir oturum-sayacı tutulur; sayaç 3'e
   ulaşınca (ve bu oturumda henüz gönderilmediyse) `provider.active` sinyali gönderilir.
   **Neden 3. yenileme, açılış değil:** Antigravity yalnızca IDE çalışırken ve poll edildikten
   sonra görünür; açılışta örneklersek eksik sayarız. ~3 dk (60 sn × 3) sonra tablo oturur.
   O turda hâlâ yoksa bir sonraki oturumda yakalanır (toplu istatistikte kabul edilebilir).
4. **Güncelleme denetimi**: menüden "Güncellemeleri denetle" → `update.checkRequested`.

## Sinyaller (özet)

| Sinyal | Ne zaman | Parametreler |
|---|---|---|
| (otomatik) | açılış | sürüm, macOS, dil, cihaz modeli, anonim oturum |
| `provider.active` | 3. yenileme (oturumda bir kez) | `claude`/`codex`/`antigravity` = `true`/`false` |
| `widget.installed` | açılış | boyut başına sayım (`small`/`medium`/`large`/`extraLarge`) |
| `update.checkRequested` | menüden denetim | — |

## Hata Yönetimi

- SDK init/gönderim hataları **yutulur** (telemetri asla uygulamayı etkilemez/çökertmez).
- App ID boş/eksikse `start()` no-op.
- Opt-out / dev build → tüm yollar erkenden sessizce çıkar.

## Test

- `shouldSendTests`: `(isDev, enabled)` dört kombinasyonu.
- `providerParametersTests`: aktif/stale/unavailable karışık servislerden doğru kategorik
  çıktı; **hiçbir yüzde/değer sızmadığını** doğrular.
- `widgetParametersTests`: boyut sayımları doğru.
- (Menü tıklama / SDK gönderimi entegrasyon testi kapsam dışı — saf üreticiler + kapı yeterli.)

## Geliştirme Sonu Denetimleri (zorunlu son faz)

Implementasyon ve testler bittikten sonra, kapatmadan önce:

1. **Güvenlik denetimi** (`security-review` / security-auditor) — yeni bağımlılık (SDK)
   ve gönderim yollarında: sızıntı, enjeksiyon, gizli değer ifşası, güvenli olmayan
   ağ/saklama. Özellikle hiçbir sinyalde token/kimlik/kota değerinin yer almadığını doğrula.
2. **Gizlilik denetimi** — sinyal payload'larını tek tek gözden geçir; yalnızca kategorik
   var/yok ve sayım gittiğini, anonim kimliğin korunduğunu, opt-out'un gerçekten gönderimi
   durdurduğunu (init dahil) ve dev build'lerin tamamen sessiz olduğunu kanıtla.
3. **Code simplify** (`simplify` / code-simplifier) — yalnızca bu görevde değişen kodda:
   tekrar, gereksiz soyutlama, ölü kod temizliği; davranış değişmeden.

Bulgular düzeltilir, testler tekrar yeşil olur, sonra iş kapanır.

## Kapsam Dışı (YAGNI)

- Yenileme sıklığı sinyali (gürültülü — kullanıcı istemedi).
- Widget extension'dan sinyal (uygulama tarafı `WidgetCenter` yeterli; widget'a SDK/ağ eklenmez).
- Ayar ekranı (sağ-tık menü yeterli).
- Özel/atanmış kullanıcı kimliği (anonim varsayılan korunur).

## Dosyalar

- `Package.swift` — TelemetryDeck SwiftSDK bağımlılığı + Mimir target dependency.
- `Sources/Mimir/Telemetry.swift` (yeni) — sarmalayıcı + saf üreticiler + kapı.
- `Sources/Mimir/MimirApp.swift` — `start()`, açılış widget sinyali, sağ-tık menü, sink sayacı.
- `Tests/MimirTests/TelemetryTests.swift` (yeni) — saf fonksiyon testleri.
- `CHANGELOG.md` — sürüm girişi (EN + TR), release sırasında.

## Prerequisite (kullanıcıdan)

telemetrydeck.com'da bir uygulama oluştur → **App ID (UUID)** ver. Gizli değildir
(istemciye gömülür), ama implementasyona başlamadan gerekir.
