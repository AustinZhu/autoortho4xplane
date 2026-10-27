// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoOrtho",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AutoOrtho", targets: ["AutoOrtho"])],
    targets: [.executableTarget(name: "AutoOrtho", path: "Sources")],
    swiftLanguageModes: [.v5]
)
