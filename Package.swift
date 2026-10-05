// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoniView",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MoniView", targets: ["MoniView"])
    ],
    targets: [
        .executableTarget(name: "MoniView")
    ]
)
