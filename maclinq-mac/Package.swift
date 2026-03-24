// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "maclinq-mac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "maclinq-mac", targets: ["maclinq-mac"])
    ],
    targets: [
        .executableTarget(
            name: "maclinq-mac",
            path: "Sources/maclinq-mac"
        ),
        .testTarget(
            name: "maclinq-macTests",
            dependencies: ["maclinq-mac"],
            path: "Tests/maclinq-macTests"
        )
    ]
)
