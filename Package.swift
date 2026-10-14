// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cornetta",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Cornetta", targets: ["Cornetta"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CornettaCore"),
        .executableTarget(
            name: "Cornetta",
            dependencies: ["CornettaCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "CornettaCoreTests", dependencies: ["CornettaCore"]),
    ]
)
