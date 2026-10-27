// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoOrthoNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AutoOrthoNative", targets: ["AutoOrthoNative"])],
    targets: [.executableTarget(name: "AutoOrthoNative", path: "Sources")],
    swiftLanguageModes: [.v5]
)
