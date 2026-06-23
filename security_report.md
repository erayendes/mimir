## Mimir Kod Kalitesi ve Güvenlik Analizi Raporu

**Tarih:** 2025-02-12
**Kapsam:** Dosya yazma işlemleri (Time-of-Check to Time-of-Use - TOCTOU Zafiyeti)

### Bulgular

Mimir'in kaynak kodunda yapılan incelemeler sonucunda, çeşitli dosyalarda `Data.write(to:options: .atomic)` ve sonrasında dosya izinlerini değiştirmek için `FileManager.default.setAttributes` kullanıldığı veya eksik bırakıldığı tespit edilmiştir. Bu durum, özellikle auth bilgileri gibi hassas veriler dosyaya yazılırken TOCTOU (Time-of-Check to Time-of-Use) olarak bilinen bir güvenlik zafiyetine yol açmaktadır.

`.atomic` opsiyonu ile yazma işlemi gerçekleştirildiğinde, sistem önce rastgele isimli bir geçici dosya oluşturur, ardından hedef dosyayı değiştirir. Ancak yeni oluşturulan dosya varsayılan sistem izinleriyle yaratılır. Eğer bu geçici dosyanın izinleri yeterince kısıtlı değilse (örneğin 0600 yerine varsayılan izinlerle oluşturulmuşsa), `setAttributes` çağrılana kadar geçecek olan o kısa süre zarfında, sistemdeki başka bir süreç (process) bu dosyayı okuyabilir.

Hassas dosyalar söz konusu olduğunda, dosya ilk baştan güvenli izinlerle oluşturulmalı ve ardından asıl dosyanın yerine konmalıdır.

Etkilenen Dosyalar:
1. `Sources/Mimir/LiveUsageDataSource.swift`:
   - `saveSnapshot` içinde `try? data.write(to: url, options: .atomic)` var.
2. `Sources/Mimir/ClaudeProvider.swift`:
   - `writeClaudeUsageCache` metodunda `try data.write(to: url, options: .atomic)` var.
   - `writeClaudeCredential` (satır 481 civarı) içinde `try? data.write(to: url, options: .atomic)` mevcut ve hassas kimlik bilgileri içeriyor.
3. `Sources/Mimir/CodexProvider.swift`:
   - `writeCodexAuth` metodunda (satır 305):
     ```swift
     try? data.write(to: state.path, options: .atomic)
     try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path.path)
     ```
     Bu kullanım klasik bir TOCTOU zafiyeti örneğidir.
4. `Sources/MimirShared/WidgetPayload.swift`:
   - `WidgetStore.write` içinde `try? data.write(to: url, options: .atomic)` bulunuyor.

### Önerilen Çözüm

Projenin kurallarına ve güvenlik en iyi uygulamalarına uygun olarak `Data.write(options: .atomic)` çağrıları kaldırılmalı ve bunun yerine, projenin mevcut bir parçası olan (veya eklenecek) `LiveUsageDataSource.secureAtomicWrite(data:to:permissions:)` yardımcı metodu kullanılmalıdır.

Bu metot, dosyayı önce belirlenmiş güvenli izinlerle (örn. 0600) benzersiz bir geçici dosya olarak oluşturmalı, ardından `FileManager.default.replaceItem` kullanarak hedef dosyayla atomik bir şekilde değiştirmelidir. Bu yaklaşım, dosya yazılır yazılmaz her zaman doğru izinlere sahip olmasını sağlar.
