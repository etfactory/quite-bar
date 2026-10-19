// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietBarCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "QuietBarCore", targets: ["QuietBarCore"])],
    targets: [
        .target(name: "QuietBarCore"),
        .testTarget(name: "QuietBarCoreTests", dependencies: ["QuietBarCore"])
    ]
)
