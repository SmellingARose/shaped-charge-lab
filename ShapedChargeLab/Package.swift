// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShapedChargeLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ShapedChargeLab",
            path: "Sources/ShapedChargeLab",
            swiftSettings: [.unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"])]
        )
    ]
)
