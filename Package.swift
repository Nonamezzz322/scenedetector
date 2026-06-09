// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SceneShot",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SceneShot",
            path: "Sources/SceneShot",
            swiftSettings: [
                // @main in an executable target requires library parsing (no implicit top-level main).
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
