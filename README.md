🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

### Mimir

> Track your AI tool usage limits from the macOS menu bar.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

Mimir is a lightweight macOS menu bar app that shows real-time usage limits and reset countdowns for your AI tools — Claude, Codex, Gemini, and Antigravity — without leaving your workflow.

#### Features

- **Menu bar at a glance** — see all your AI service statuses in a single popover
- **Live limits** — Claude session limits, Codex credits, and Gemini quotas updated in real time
- **Reset countdowns** — know exactly when each limit refreshes
- **Minimalist design** — monochrome icon, fully respects macOS light/dark mode
- **Privacy-first** — reads only local app configs and macOS Keychain; no data ever leaves your machine

#### Supported Services

| Service | Data source |
|---|---|
| **Claude** | Claude Code OAuth (`~/.claude`) |
| **Codex** | ChatGPT usage API + local JSONL fallback |
| **Antigravity** | Local language server + Cockpit |

More services coming — see the [Roadmap](ROADMAP.md).

#### Installation

**Requirements:** macOS 14.0 (Sonoma) or later · Swift 6.0+ (for building from source)

**Download:** Grab the latest `.dmg` from the [Releases](https://github.com/erayendes/mimir/releases) page, open it, and drag **Mimir.app** to your Applications folder.

**Build from source:**

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

#### Privacy & Security

Mimir never sends any personal data or API keys to remote servers. All data is fetched locally by reading tool log files (`~/.codex`, `~/.claude`, etc.) and macOS Keychain entries created by the respective apps.

#### Contributing

Bug reports and pull requests are welcome. For major changes, please open an issue first.

---

## Türkçe

### Mimir

> AI araçlarınızın kullanım limitlerini macOS menü çubuğundan takip edin.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

Mimir, Claude, Codex, Gemini ve Antigravity gibi AI araçlarınızın kullanım limitlerini ve yenilenme sürelerini iş akışınızı bozmadan macOS menü çubuğundan anlık olarak gösterir.

#### Özellikler

- **Menü çubuğunda tek bakış** — tüm AI servislerinizin durumunu tek bir popover'da görün
- **Anlık limitler** — Claude seans limitleri, Codex kredileri ve Gemini kotaları gerçek zamanlı güncellenir
- **Geri sayım** — her limitin tam olarak ne zaman yenileneceğini öğrenin
- **Minimalist tasarım** — monokrom ikon, macOS açık/koyu tema desteği
- **Gizlilik odaklı** — yalnızca yerel uygulama ayarlarını ve macOS Keychain'i okur; hiçbir veri makinenizden çıkmaz

#### Desteklenen Servisler

| Servis | Veri kaynağı |
|---|---|
| **Claude** | Claude Code OAuth (`~/.claude`) |
| **Codex** | ChatGPT kullanım API'si + yerel JSONL yedeği |
| **Antigravity** | Yerel dil sunucusu + Cockpit |

Daha fazla servis yolda — [Yol Haritası](ROADMAP.md)'na bakın.

#### Kurulum

**Gereksinimler:** macOS 14.0 (Sonoma) veya üzeri · Swift 6.0+ (kaynak koddan derleme için)

**İndirme:** [Releases](https://github.com/erayendes/mimir/releases) sayfasından son `.dmg` dosyasını indirin, açın ve **Mimir.app**'i Uygulamalar klasörünüze sürükleyin.

**Kaynak koddan derleme:**

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh install
```

#### Gizlilik ve Güvenlik

Mimir, kişisel verilerinizi veya API anahtarlarınızı hiçbir zaman uzak sunuculara göndermez. Tüm veriler yerel olarak araç log dosyaları (`~/.codex`, `~/.claude` vb.) ve ilgili uygulamaların oluşturduğu macOS Keychain kayıtları okunarak elde edilir.

#### Katkıda Bulunma

Hata raporları ve pull request'ler memnuniyetle karşılanır. Büyük değişiklikler için önce bir issue açmanız rica olunur.

---

[MIT](LICENSE) © Eray Endes
