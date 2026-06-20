# Installation / Kurulum

🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

> [Documentation](README.md) · Next: [Services →](SERVICES.md)

---

## English

### Requirements

- **macOS 14.0 (Sonoma)** or later
- To build from source: **Swift 6.0+** (ships with Xcode 16)

### Option 1 — Download a release (recommended)

1. Grab the latest `.dmg` from the [Releases](https://github.com/erayendes/mimir/releases) page.
2. Open the `.dmg` and drag **Mimir.app** into your **Applications** folder.
3. Launch Mimir — the Mimir icon appears in the menu bar.

> ℹ️ **Notarized** — Distributed releases are notarized by Apple, so you won't get a Gatekeeper warning. (Releases are signed and notarized entirely on CI.)

### Option 2 — Build from source

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

The `build_and_run.sh` script builds, signs, and runs the app.

| Command | What it does |
|---|---|
| `./script/build_and_run.sh` | Build + sign + run |
| `./script/build_and_run.sh logs` | Run with a log stream |
| `./script/build_and_run.sh install` | Build and install into Applications |

### First launch

On first launch, Mimir asks once for permission to **Launch at Login** so your usage is always in the menu bar.

> You can change this later under **System Settings › General › Login Items**.

For services to appear, you must have signed in to each AI tool at least once (Mimir reads the local data those tools create). See each service's page for details:

- [Claude](SERVICES.md)
- [Codex](SERVICES.md)
- [Antigravity](SERVICES.md)

### Updating

Mimir updates itself via **Sparkle**. Use **Check for Updates** from the popover menu, or download the new `.dmg` from the Releases page.

Stuck on something? → [Support & FAQ](SUPPORT.md). Otherwise → **[Services](SERVICES.md)**.

---

## Türkçe

### Gereksinimler

- **macOS 14.0 (Sonoma)** veya üzeri
- Kaynaktan derleyecekseniz: **Swift 6.0+** (Xcode 16 ile birlikte gelir)

### Seçenek 1 — Hazır sürümü indir (önerilen)

1. [Releases](https://github.com/erayendes/mimir/releases) sayfasından en güncel `.dmg` dosyasını indirin.
2. `.dmg`'yi açın ve **Mimir.app**'i **Uygulamalar** klasörünüze sürükleyin.
3. Mimir'i çalıştırın — menü çubuğunda Mimir ikonu belirir.

> ℹ️ **Notarize edilmiştir** — Dağıtılan sürümler Apple tarafından notarize edilir; Gatekeeper uyarısı almazsınız. (Sürümler tamamen CI üzerinde imzalanıp notarize edilir.)

### Seçenek 2 — Kaynaktan derle

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

### İlk çalıştırma

Mimir ilk açıldığında, **oturum açıldığında otomatik başlatma** (Launch at Login) için bir kez izin sorar. Bu sayede kullanım durumunuz her zaman menü çubuğunda hazır olur.

> Bu tercihi daha sonra **Sistem Ayarları › Genel › Açılış Öğeleri** (Login Items) üzerinden değiştirebilirsiniz.

İlk açılışta servislerin görünmesi için ilgili AI araçlarına en az bir kez giriş yapmış olmanız gerekir (Mimir o araçların oluşturduğu yerel verileri okur). Detaylar için her servisin kendi sayfasına bakın:

- [Claude](SERVICES.md)
- [Codex](SERVICES.md)
- [Antigravity](SERVICES.md)

### Güncelleme

Mimir, **Sparkle** ile kendi içinden güncellenir. Açılır penceredeki menüden **Güncellemeleri Denetle**'yi kullanabilir veya yeni `.dmg`'yi Releases sayfasından indirebilirsiniz.

Takıldığınız bir nokta olursa → [Destek & SSS](SUPPORT.md). Kurulum tamamsa → **[Servisler](SERVICES.md)**.
