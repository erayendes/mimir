🇬🇧 [English](#english) · 🇹🇷 [Türkçe](#türkçe)

---

## English

### Contributing

Thanks for considering a contribution to Mimir!

#### Before You Start

For significant changes, please [open an issue](https://github.com/erayendes/mimir/issues) first and describe what you'd like to do. This avoids unnecessary work and ensures your proposal fits the project's direction.

#### Development Setup

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh
```

**Requirements:** macOS 14.0+, Swift 6.0+

#### Pull Request Process

1. Fork the repo and create a new branch: `git checkout -b feature/description`
2. Make your changes
3. Write a clear commit message
4. Open a pull request with a brief explanation of what and why

#### Code Style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- If adding a new service, study the existing pattern in `MimirModels.swift` and `LiveUsageDataSource.swift` and follow it

#### Bug Reports

If you found a bug, [open an issue](https://github.com/erayendes/mimir/issues) and include:

- Your macOS version
- Steps to reproduce
- Expected vs. actual behavior

---

## Türkçe

### Katkıda Bulunma Rehberi

Mimir'e katkıda bulunmayı düşündüğünüz için teşekkürler!

#### Başlamadan Önce

Büyük değişiklikler için önce bir [issue açın](https://github.com/erayendes/mimir/issues) ve ne yapmak istediğinizi kısaca açıklayın. Bu sayede gereksiz iş yapmaktan kaçınılır ve önerinizin projeye uygun olup olmadığı önceden netleştirilebilir.

#### Geliştirme Ortamı

```bash
git clone https://github.com/erayendes/mimir.git
cd mimir
./script/build_and_run.sh
```

**Gereksinimler:** macOS 14.0+, Swift 6.0+

#### Pull Request Süreci

1. Repo'yu fork'layın ve yeni bir dal oluşturun: `git checkout -b ozellik/aciklama`
2. Değişikliklerinizi yapın
3. Anlamlı bir commit mesajı yazın
4. Pull request açın; ne yaptığınızı ve neden yaptığınızı kısaca açıklayın

#### Kod Stili

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)'a uyun
- Yeni bir servis ekleniyorsa `MimirModels.swift` ve `LiveUsageDataSource.swift` dosyalarındaki mevcut yapıyı inceleyin ve aynı deseni takip edin

#### Hata Bildirimi

Bir hata bulduysanız [issue açın](https://github.com/erayendes/mimir/issues) ve şunları belirtin:

- macOS sürümü
- Hatanın nasıl yeniden üretileceği
- Beklenen ve gerçekleşen davranış
