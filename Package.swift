// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Typesong",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Typesong", path: "Sources/Typesong")
    ]
)
