import Foundation
import XCTest

@testable import RVDecode
import RVMediaCore

/// 実盤から自己抽出した素材（fixtures/local。非同梱）での実測の固定。素材が無い環境では skip する
/// （合成素材の「無ければ失敗」とは別扱い — 決定ログ #15）。
final class RealDiscFixtureTests: XCTestCase {
    private func clip() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/local/animation-480i-01.vob")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("実盤の自己抽出素材が無い（Scripts/extract-real-fixture.py）")
        }
        return url
    }

    /// 実盤（PICHI）は top-first・フレーム符号化の 4:3（合成素材は bottom-first）。
    func testRealDiscIsTopFirstInterlacedFourThree() async throws {
        let stream = try await AVFoundationDemuxer(url: try clip()).probe()
        let track = try XCTUnwrap(stream.tracks.first { $0.kind == .video })
        guard case let .video(format) = track.format else { return XCTFail("video format") }
        XCTAssertEqual(format.codedSize, PixelSize(width: 720, height: 480))
        XCTAssertEqual(format.frameRate, .ntsc)
        XCTAssertEqual(format.interlace.fieldCount, 2)
        XCTAssertEqual(format.interlace.fieldOrder, .topFirst, "実盤の順序は PCE の top_field_first")
        let aspect = AspectResolver.resolve(codedSize: format.codedSize, signals: format.aspectSignals,
                                            policy: .followSource)
        XCTAssertEqual(aspect.targetDAR.value, 4.0 / 3.0, accuracy: 0.01)
    }
}
