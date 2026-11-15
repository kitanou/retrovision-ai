// swift-tools-version:6.0
// RetroVisionKit — 設計 docs/design/00-architecture.md §2 のモジュール分割に対応する。
//
// 現在の状態（Phase 0）:
//   - FFmpeg / libdvdnav / libdvdread の C ターゲットは未作成。
//     導入形態が決まるまで置かない（docs/design/10-open-questions.md の OQ-01 / OQ-02）。
//     対応モジュール（RVDecode / RVMediaSources）はプロトコルと純粋ロジックのみを持つ。
//   - 製品のデプロイメント下限は未決（OQ-12）。CI の実行機に合わせるため、
//     ここでは macOS 15 を暫定下限とする。
import PackageDescription

let package = Package(
    name: "RetroVisionKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "RVMediaCore", targets: ["RVMediaCore"]),
        .library(name: "RVDiagnostics", targets: ["RVDiagnostics"]),
        .library(name: "RVMediaSources", targets: ["RVMediaSources"]),
        .library(name: "RVDecode", targets: ["RVDecode"]),
        .library(name: "RVVideoPipeline", targets: ["RVVideoPipeline"]),
        .library(name: "RVMLRuntime", targets: ["RVMLRuntime"]),
        .library(name: "RVEnhancement", targets: ["RVEnhancement"]),
        .library(name: "RVPlaybackEngine", targets: ["RVPlaybackEngine"]),
    ],
    targets: [
        // 値型のみ。Foundation / CoreMedia 以外の依存を持たない（00 §2）。
        .target(name: "RVMediaCore"),

        // メトリクスバスとベンチマーク出力（08）。
        .target(name: "RVDiagnostics", dependencies: ["RVMediaCore"]),

        // ソース抽象（03）。DVD / ISO の実装は C シムが決まってから追加する。
        .target(name: "RVMediaSources", dependencies: ["RVMediaCore"]),

        // デコード・同期契約（04）。
        .target(name: "RVDecode", dependencies: ["RVMediaCore"]),

        // 描画契約と、純粋ロジック部分（提示パ計画など）（05）。
        .target(name: "RVVideoPipeline", dependencies: ["RVMediaCore"]),

        // Core ML 実行層の契約とモデル manifest（06）。
        .target(name: "RVMLRuntime", dependencies: ["RVMediaCore"]),

        // 強調化ステージの契約（07）。
        .target(
            name: "RVEnhancement",
            dependencies: ["RVMediaCore", "RVVideoPipeline", "RVMLRuntime"]
        ),

        // PlayerEngine の実装と同期・適応制御（02、08）。
        .target(
            name: "RVPlaybackEngine",
            dependencies: [
                "RVMediaCore", "RVDiagnostics", "RVMediaSources", "RVDecode",
                "RVVideoPipeline", "RVEnhancement",
            ]
        ),

        // 境界の機械検査（00 §2 の禁止 import）。
        .testTarget(
            name: "ArchitectureTests",
            dependencies: ["RVMediaCore", "RVDiagnostics", "RVMediaSources", "RVDecode",
                           "RVVideoPipeline", "RVMLRuntime", "RVEnhancement", "RVPlaybackEngine"]
        ),

        .testTarget(name: "RVMediaCoreTests", dependencies: ["RVMediaCore"]),
        .testTarget(name: "RVDiagnosticsTests", dependencies: ["RVDiagnostics"]),
        .testTarget(name: "RVVideoPipelineTests", dependencies: ["RVVideoPipeline"]),
        .testTarget(name: "RVPlaybackEngineTests", dependencies: ["RVPlaybackEngine"]),
    ]
)
