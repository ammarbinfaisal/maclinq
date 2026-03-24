// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "keyb-mac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "keyb-mac", targets: ["keyb-mac"])
    ],
    targets: [
        .executableTarget(
            name: "keyb-mac",
            path: "Sources/keyb-mac"
        ),
        .testTarget(
            name: "keyb-macTests",
            dependencies: ["keyb-mac"],
            path: "Tests/keyb-macTests"
        )
    ]
)
