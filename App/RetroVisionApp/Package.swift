// swift-tools-version:6.0
// RetroVisionApp — 00 §2 のアプリターゲット（SwiftUI）。エンジン実装ではなくプロトコルに依存する。
//
// 依存規則（INV-8・00 §2 の禁止事項）:
//   - RVDecode / RVVideoPipeline / RVMLRuntime / RVEnhancement を import しない。
//   - 語彙層（RVMediaCore / RVMediaSources）と実行系入口（RVPlaybackEngine）だけを import する。
//     この境界は Tests/ImportBoundaryAppTests で機械検査する。
import PackageDescription

let package = Package(
    name: "RetroVisionApp",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "../../Packages/RetroVisionKit"),
    ],
    targets: [
        // UI の本体（view・view model・暫定サーフェス）。実行可能ターゲットはここを呼ぶだけで、
        // テスト（@testable）从这里引けるようにする。
        .target(
            name: "RetroVisionAppUI",
            dependencies: [
                .product(name: "RVMediaCore", package: "RetroVisionKit"),
                .product(name: "RVMediaSources", package: "RetroVisionKit"),
                .product(name: "RVPlaybackEngine", package: "RetroVisionKit"),
            ]
        ),
        .executableTarget(
            name: "RetroVisionApp",
            dependencies: ["RetroVisionAppUI"]
        ),
        .testTarget(
            name: "RetroVisionAppUITests",
            dependencies: ["RetroVisionAppUI"]
        ),
    ]
)
