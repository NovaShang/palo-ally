// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaloAllyKit",
    platforms: [.iOS(.v26), .macOS(.v26), .macCatalyst(.v26)],
    products: [
        .library(name: "PaloAllyKit", targets: ["PaloAllyKit"]),
        .library(name: "PaloAllyVoice", targets: ["PaloAllyVoice"]),
        .library(name: "PaloAllyFilePreview", targets: ["PaloAllyFilePreview"]),
    ],
    targets: [
        .target(name: "PaloAllyKit"),
        // Voice input ported from bento's BentoVoiceKit; built in the Swift 5
        // language mode it was written for.
        .target(name: "PaloAllyVoice", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PaloAllyVoiceTests", dependencies: ["PaloAllyVoice"]),
        // Markdown preview ported from bento's BentoFilePreviewKit (markdown-it
        // + highlight.js in a WKWebView, all bundled), same language mode.
        .target(
            name: "PaloAllyFilePreview",
            resources: [.copy("Resources/FilePreview")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "PaloAllyFilePreviewTests", dependencies: ["PaloAllyFilePreview"]),
        .testTarget(
            name: "PaloAllyKitTests",
            dependencies: ["PaloAllyKit"],
            exclude: ["Fixtures"]
        ),
    ]
)
