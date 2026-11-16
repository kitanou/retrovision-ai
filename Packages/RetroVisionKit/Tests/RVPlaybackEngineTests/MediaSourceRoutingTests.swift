import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources

// MARK: - URL → source 型の割り当て検査（#3。App の「一つの入口」の根元）

final class MediaSourceRoutingTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDirectoryRoutesToVideoTs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = MediaSourceRouting.makeSource(for: dir)
        XCTAssertTrue(source is VideoTsMediaSource, "ディレクトリが VideoTsMediaSource に届かない")
    }

    func testISOImageRoutesToDiscImage() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("disc.iso")
        FileManager.default.createFile(atPath: iso.path, contents: Data())
        XCTAssertTrue(MediaSourceRouting.isDiskImageURL(iso), "UTI 判定で .iso が diskImage でない")
        let source = MediaSourceRouting.makeSource(for: iso)
        XCTAssertTrue(source is DiscImageMediaSource, ".iso が DiscImageMediaSource に届かない")
    }

    func testPlainFileRoutesToFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("movie.mpg")
        FileManager.default.createFile(atPath: movie.path, contents: Data())
        let source = MediaSourceRouting.makeSource(for: movie)
        XCTAssertTrue(source is FileMediaSource, "通常ファイルが FileMediaSource に届かない")
        XCTAssertFalse(MediaSourceRouting.isDiskImageURL(movie))
    }

    /// 安全網の順序検査: .iso を「ファイル」として開こうとすると FileMediaSource の
    /// 事前ゲートが構造化エラーを出す（ルーティングを外れた入口の実測メッセージ）。
    func testFileMediaSourcePreGateStillGuards() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("disc.iso")
        FileManager.default.createFile(atPath: iso.path, contents: Data())
        do {
            _ = try await FileMediaSource(url: iso).open()
            XCTFail("事前ゲートが素通過した")
        } catch let error as PlaybackError {
            guard case .source(let kind) = error.kind else {
                return XCTFail("kind が source でない: \(error.kind)")
            }
            XCTAssertEqual(kind, .unsupportedStructure)
        }
    }
}
