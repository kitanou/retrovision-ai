import Foundation
import XCTest

/// 依存方向の機械検査（00 §2）。import 図はドキュメントではなく CI で守る。
final class ImportBoundaryTests: XCTestCase {
    private let forbidden: [String: [String]] = [
        // 段・実行系がデコーダを知らないこと（フレームは RVMediaCore の型で受け渡す）。
        "RVVideoPipeline": ["RVDecode", "RVMediaSources", "RVPlaybackEngine"],
        "RVMLRuntime": ["RVDecode", "RVVideoPipeline", "RVPlaybackEngine"],
        "RVEnhancement": ["RVDecode", "RVPlaybackEngine"],
        "RVMediaCore": ["RVDiagnostics", "RVMediaSources", "RVDecode", "RVVideoPipeline",
                        "RVMLRuntime", "RVEnhancement", "RVPlaybackEngine"],
        "RVMediaSources": ["RVDecode", "RVVideoPipeline", "RVPlaybackEngine"],
        "RVDecode": ["RVVideoPipeline", "RVPlaybackEngine", "RVMediaSources"],
        "RVDiagnostics": ["RVMediaSources", "RVDecode", "RVVideoPipeline", "RVPlaybackEngine"],
    ]

    func testNoForbiddenImports() throws {
        let sources = try sourceFiles()
        XCTAssertFalse(sources.isEmpty, "Sources を見つけられない（パッケージ構造が変わった可能性）")
        for (module, forbiddenModules) in forbidden {
            guard let files = sources[module] else { continue }
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for forbiddenModule in forbiddenModules {
                    let pattern = "import \(forbiddenModule)"
                    XCTAssertFalse(text.contains(pattern),
                                   "\(file.path) が \(pattern) を持つ（00 §2 の依存規則に反する）")
                }
            }
        }
    }

    /// C API がシムモジュールの外に漏れていないことの確認（00 §2）。
    func testNoRawCAPIOutsideShims() throws {
        let sources = try sourceFiles()
        let forbiddenSymbols = ["AVCodecContext", "AVFrame", "AVPacket", "dvd_read", "dvdnav_"]
        for (module, files) in sources where !module.hasPrefix("C") {
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for symbol in forbiddenSymbols {
                    XCTAssertFalse(text.contains(symbol),
                                   "\(file.path) が C API の \(symbol) を直接参照している")
                }
            }
        }
    }

    /// 診断 ID を文字列リテラルで書かない規約（00 §8）。
    func testStageIDsAreNotWrittenAsBareLiterals() throws {
        let sources = try sourceFiles()
        for (module, files) in sources where module != "RVMediaCore" {
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for stage in Self.stageLiteralForms {
                    XCTAssertFalse(text.contains(stage),
                                   "\(file.path) が StageID を文字列リテラル \("\(stage)") で書いている")
                }
            }
        }
    }

    private static let stageLiteralForms = [
        "\"deinterlace\"", "\"superResolution\"", "\"videoDecode\"", "\"present\"", "\"mlInference\"",
    ]

    private func sourceFiles() throws -> [String: [FileURL]] {
        // テスト実行時のカレントは .build の配下になりうるので、Package.swift を手がかりに辿る。
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        var packageRoot: URL?
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                packageRoot = dir
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard let root = packageRoot else { return [:] }
        let sourcesRoot = root.appendingPathComponent("Sources")
        var result: [String: [FileURL]] = [:]
        guard let modules = try? fm.contentsOfDirectory(atPath: sourcesRoot.path) else { return [:] }
        for module in modules {
            var collected: [FileURL] = []
            collectSwiftFiles(in: sourcesRoot.appendingPathComponent(module), into: &collected)
            result[module] = collected
        }
        return result
    }

    private func collectSwiftFiles(in url: URL, into out: inout [FileURL]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { return }
        for entry in entries {
            let child = url.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                collectSwiftFiles(in: child, into: &out)
            } else if entry.hasSuffix(".swift") {
                out.append(child)
            }
        }
    }

    private typealias FileURL = URL
}
