// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "setcheck", platforms: [.macOS(.v14)],
    products: [.executable(name: "setcheck", targets: ["Setcheck"]), .library(name: "SetcheckCore", targets: ["SetcheckCore"])],
    targets: [
        .target(name: "SetcheckCore"),
        .executableTarget(name: "Setcheck", dependencies: ["SetcheckCore"]),
        .testTarget(name: "SetcheckCoreTests", dependencies: ["SetcheckCore"])
    ]
)
