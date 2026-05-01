import AppKit
import Foundation

enum BrandIconLoader {
    static func image(named name: String) -> NSImage? {
        // Package.swift'te .copy("Resources") dediğimiz için 
        // kaynaklar "Resources/BrandIcons/..." altında bulunur.
        let resourcePath = "Resources/BrandIcons/\(name).svg"
        
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources/BrandIcons")
                ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "BrandIcons")
                ?? Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}
