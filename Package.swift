// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shaken",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Shaken", targets: ["Shaken"])],
    targets: [
        .target(name: "ShakenCore"),
        .executableTarget(name: "Shaken", dependencies: ["ShakenCore"]),
        .testTarget(
            name: "ShakenCoreTests",
            dependencies: ["ShakenCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
