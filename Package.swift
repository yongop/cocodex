// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Co-Count",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Co-Count", targets: ["Cocount"])],
    targets: [
        .target(name: "CocountCore"),
        .executableTarget(name: "Cocount", dependencies: ["CocountCore"],
                          resources: [.copy("Resources/CocountIcon.svg"),
                                      .copy("Resources/CocountMenuBarIcon.svg")]),
    ]
)
