// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GQuotaKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GQuotaKit", targets: ["GQuotaKit"]),
    ],
    targets: [
        .target(name: "GQuotaKit"),
        .testTarget(
            name: "GQuotaKitTests",
            dependencies: ["GQuotaKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
