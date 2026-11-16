import Foundation
import XCTest

/// 依存方向の機械検査（00 §2・INV-8: UI は実装モジュールを import しない）。
/// パッケージ側の ImportBoundaryTests とは別系統（アプリの source ツリーを見る）。
final class ImportBoundaryAppTests: XCTestCase {
    /// 語彙層（RVMediaCore / RVMediaSources）と実行系入口（RVPlaybackEngine）だけを許す。
    private let forbidden = ["RVDecode", "RVVideoPipeline", "RVMLRuntime",
                            "RVEnhancement", "RVDiagnostics"]

    func testAppSourcesDoNotImportImplementationModules() throws {
        // Tests/RetroVisionAppUITests/ ← App/RetroVisionApp/ ← sources
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RetroVisionAppUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionApp
            .appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: here,
                                                             includingPropertiesForKeys: nil) else {
            return XCTFail("アプリの source ツリーが見つからない（レイアウトが変わった可能性）")
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        let packageManifest = here.deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        files.append(packageManifest)   // products/targets の依存宣言も同じ規則で見る

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for module in forbidden {
                XCTAssertFalse(text.contains("import \(module)"),
                               "\(file.lastPathComponent) が import \(module) を持つ（INV-8）")
                XCTAssertFalse(text.contains("name: \"\(module)\""),
                               "\(file.lastPathComponent) が product \(module) への依存を持つ（INV-8）")
            }
        }
    }
}
