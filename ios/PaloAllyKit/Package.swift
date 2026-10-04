// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaloAllyKit",
    platforms: [.iOS(.v26), .macOS(.v26), .macCatalyst(.v26)],
    products: [
        .library(name: "PaloAllyKit", targets: ["PaloAllyKit"]),
    ],
    targets: [
        .target(name: "PaloAllyKit"),
        .testTarget(
            name: "PaloAllyKitTests",
            dependencies: ["PaloAllyKit"],
            exclude: ["Fixtures"]
        ),
    ]
)
