import AppKit

enum CocountIcon {
    // The menu bar uses wider cutouts so the terminal mark survives at small sizes.
    static let image = loadImage(named: "CocountIcon")
    static let menuBarImage: NSImage = {
        let image = loadImage(named: "CocountMenuBarIcon")
        image.size = NSSize(width: 20, height: 20)
        return image
    }()

    private static func loadImage(named name: String) -> NSImage {
        let resourceBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("Co-Count_Cocount.bundle")) }
            ?? Bundle.module
        guard let url = resourceBundle.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing \(name).svg resource")
        }
        image.isTemplate = true
        return image
    }
}
