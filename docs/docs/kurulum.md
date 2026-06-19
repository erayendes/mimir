---
id: kurulum
title: Kurulum
sidebar_label: Kurulum
description: Mimir'i indirip kurmanın veya kaynaktan derlemenin yolları.
---

# Kurulum

## Gereksinimler

- **macOS 14.0 (Sonoma)** veya üzeri
- Kaynaktan derleyecekseniz: **Swift 6.0+** (Xcode 16 ile birlikte gelir)

## Seçenek 1 — Hazır sürümü indir (önerilen)

1. [Releases](https://github.com/erayendes/mimir/releases) sayfasından en güncel `.dmg` dosyasını indirin.
2. `.dmg`'yi açın ve **Mimir.app**'i **Uygulamalar** klasörünüze sürükleyin.
3. Mimir'i çalıştırın — menü çubuğunda Mimir ikonu belirir.

:::info Notarize edilmiştir
Dağıtılan sürümler Apple tarafından **notarize** edilir; Gatekeeper uyarısı almazsınız. (Sürümler tamamen CI üzerinde imzalanıp notarize edilir.)
:::

## Seçenek 2 — Kaynaktan derle

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

`build_and_run.sh` betiği uygulamayı derler, imzalar ve çalıştırır.

| Komut | Ne yapar |
|---|---|
| `./script/build_and_run.sh` | Derle + imzala + çalıştır |
| `./script/build_and_run.sh logs` | Log akışı ile birlikte çalıştır |
| `./script/build_and_run.sh install` | Derleyip Uygulamalar'a kur |

## İlk çalıştırma

Mimir ilk açıldığında, **oturum açıldığında otomatik başlatma** (Launch at Login) için bir kez izin sorar. Bu sayede kullanım durumunuz her zaman menü çubuğunda hazır olur.

> Bu tercihi daha sonra **Sistem Ayarları › Genel › Açılış Öğeleri** (Login Items) üzerinden değiştirebilirsiniz.

İlk açılışta servislerin görünmesi için ilgili AI araçlarına en az bir kez giriş yapmış olmanız gerekir (Mimir o araçların oluşturduğu yerel verileri okur). Detaylar için her servisin kendi sayfasına bakın:

- [Claude](./servisler/claude.md)
- [Codex](./servisler/codex.md)
- [Antigravity](./servisler/antigravity.md)

## Güncelleme

Mimir, **Sparkle** ile kendi içinden güncellenir. Açılır penceredeki menüden **Güncellemeleri Denetle**'yi kullanabilir veya yeni `.dmg`'yi Releases sayfasından indirebilirsiniz.

---

Kurulum tamam → **[Menü çubuğunu okuma](./menu-cubugu.md)**.
