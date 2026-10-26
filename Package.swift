// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Spy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Spy", targets: ["Spy"])],
    targets: [.executableTarget(name: "Spy", path: "Sources")]
)
