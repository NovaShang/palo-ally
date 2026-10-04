// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaloAllyKit",
    platforms: [.iOS(.v26), .macOS(.v26), .macCatalyst(.v26)],
    products: [
        .library(name: "PaloAllyKit", targets: ["PaloAllyKit"]),
        .library(name: "PaloAllyVoice", targets: ["PaloAllyVoice"]),
    ],
    targets: [
        .target(name: "PaloAllyKit"),
        // Voice input ported from bento's BentoVoiceKit; built in the Swift 5
        // language mode it was written for.
        .target(name: "PaloAllyVoice", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "PaloAllyKitTests",
            dependencies: ["PaloAllyKit"],
            exclude: ["Fixtures"]
        ),
    ]
)
