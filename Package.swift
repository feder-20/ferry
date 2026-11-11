// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ferry",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Ferry", path: "Sources/Ferry"),
        .testTarget(name: "FerryTests", dependencies: ["Ferry"], path: "Tests/FerryTests")
    ]
)
