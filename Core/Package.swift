// swift-tools-version: 6.0
import PackageDescription

// Everything Obolo knows how to compute lives here, deliberately separate from the
// app target so it can be built and tested headlessly with `swift test` — no Xcode, no
// signing, no UI. The rule the whole package is built around: nothing derived is ever
// stored. Next payments, monthly equivalents, totals and attention states are computed
// from the document on every read, which is only affordable because it is all value
// types and pure functions.
let package = Package(
    name: "OboloCore",
    platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        .library(name: "OboloCore", targets: ["OboloCore"])
    ],
    targets: [
        .target(
            name: "OboloCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OboloCoreTests",
            dependencies: ["OboloCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
