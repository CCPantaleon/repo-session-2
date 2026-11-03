// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OKCopy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OKCopy", targets: ["OKCopy"])],
    targets: [
        .target(name: "IngestCore"),
        .executableTarget(name: "OKCopy", dependencies: ["IngestCore"]),
        .testTarget(name: "IngestCoreTests", dependencies: ["IngestCore"])
    ]
)
