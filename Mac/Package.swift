// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CouchpadMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CGVirtualDisplay",
            path: "Sources/CGVirtualDisplay"
        ),
        .executableTarget(
            name: "CouchpadMac",
            dependencies: ["CGVirtualDisplay"],
            path: "Sources/CouchpadMac"
        )
    ]
)
