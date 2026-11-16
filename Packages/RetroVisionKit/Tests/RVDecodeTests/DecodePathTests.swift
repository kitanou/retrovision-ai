import AVFoundation
import CoreVideo
import Foundation
import XCTest

@testable import RVDecode
import RVMediaCore

/// 実ファイルを使う統合テスト（docs/experiments/EXP-001 の実測値を回帰で固定する）。
///
/// 方針（docs/design/09 §2）:
///   - fixture が無い場合は**失敗**（silent skip で環境差を隠さない）。
///   - 能力が無いため通せないテストは明示的な skip にする（本ファイルでは現在なし）。
/// 素材は Scripts/gen-fixtures.sh の生成物。CI は `make gen-fixtures` を先に走らせる。
final class DecodePathTests: XCTestCase {
    private struct MissingFixture: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "fixture が存在しない: \(path)（sh Scripts/gen-fixtures.sh で生成する）"
        }
    }

    private var fixturesDir: URL {
        // Tests/RVDecodeTests/ ← Packages/RetroVisionKit/ ← リポジトリルート
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVDecodeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("fixtures/generated")
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let url = fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFixture(path: url.path)
        }
        return url
    }

    private func videoTrack(of stream: ProbedStream) throws -> (TrackInfo, VideoFormatDescription) {
        guard let track = stream.tracks.first(where: { $0.kind == .video }),
              case let .video(format) = track.format else {
            throw MissingFixture(path: "video track not found")
        }
        return (track, format)
    }

    /// MPEG-2 program stream（NTSC DVD 想定）。format 信号が実測どおりに解決すること。
    func testNTSCProgramStreamResolvesFullFormatSignals() async throws {
        let demuxer = AVFoundationDemuxer(url: try fixtureURL("ntsc480i-22-01.mpg"))
        let stream = try await demuxer.probe()
        let (_, format) = try videoTrack(of: stream)

        XCTAssertEqual(FourCC.string(format.rawFormatType), "mp2v")
        XCTAssertEqual(format.codedSize, PixelSize(width: 720, height: 480))
        // 実測: container hint または bitstream / PTS 列から 30000/1001 に解決（F7/F9）。
        XCTAssertEqual(format.frameRate, .ntsc)
        // 実測: MPEG-PS の CVPixelAspectRatio は 10:11 を渡す（F4）。
        XCTAssertEqual(format.sampleAspect, .bt601NTSCSample)
        // 実測: field 数は container が渡る。順序は picture_coding_extension が補う（F5/F6）。
        XCTAssertEqual(format.interlace.fieldCount, 2)
        XCTAssertEqual(format.interlace.fieldOrder, .bottomFirst)   // ffprobe field_order=bb
        XCTAssertEqual(format.interlace.fieldSource, .formatDescription)
        // bitstream の aspect_ratio_information（4:3）も別枠で保持（05 §6 の優先順位入力）。
        XCTAssertEqual(format.aspectSignals.mpegAspectInformation, .dar4x3)
    }

    /// OQ-17（#14）: MP4 mux の MPEG-2 が container に残す CVFieldDetail の実値を固定する。
    /// 値は temporal ではなく空間順の SpatialFirstLineLate で、PCE（bottom-first）と
    /// 方向が整合する。順序の源は PCE のまま（detail は読むだけ。fieldOrder に写像しない）。
    func testMP4MuxedMPEG2ContainerFieldDetailIsSpatialLateAndAgreesWithPCE() async throws {
        let url = try fixtureURL("ntsc480i-22-01-in-mp4.mp4")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descs = try await track.load(.formatDescriptions)
        let desc = try XCTUnwrap(descs.first)
        let detail = CMFormatDescriptionGetExtension(desc, extensionKey: kCVImageBufferFieldDetailKey) as? String
        XCTAssertEqual(detail, MediaAttachmentValue.fieldDetailSpatialFirstLineLate,
                       "container の CVFieldDetail が実測（SpatialFirstLineLate）と異なる")
        // temporal 値ではないので、現行の写像では順序に使われない（PCE が源）。
        XCTAssertNotEqual(detail, MediaAttachmentValue.fieldDetailTopFirst)
        XCTAssertNotEqual(detail, MediaAttachmentValue.fieldDetailBottomFirst)

        let stream = try await AVFoundationDemuxer(url: url).probe()
        let (_, format) = try videoTrack(of: stream)
        XCTAssertEqual(format.interlace.fieldOrder, .bottomFirst, "PCE 由来の順序（bottom-first）")
        // Late（最初の行が後の field）= bottom field が先、で PCE と整合する。
    }

    func testPALProgramStreamResolves25And576() async throws {
        let demuxer = AVFoundationDemuxer(url: try fixtureURL("pal576i-22-01.mpg"))
        let stream = try await demuxer.probe()
        let (_, format) = try videoTrack(of: stream)

        XCTAssertEqual(FourCC.string(format.rawFormatType), "mp2v")
        XCTAssertEqual(format.codedSize, PixelSize(width: 720, height: 576))
        XCTAssertEqual(format.frameRate, .pal)
        XCTAssertEqual(format.interlace.fieldCount, 2)
    }

    /// 24/1 の素材は progressive のまま（field 符号化に倒さない）。
    /// bitstream の progressive_sequence=1 が container の fieldCount=0 と矛盾しないこと（F6・F9）。
    func testFilm24pStaysProgressive() async throws {
        let demuxer = AVFoundationDemuxer(url: try fixtureURL("film24p-01.mpg"))
        let stream = try await demuxer.probe()
        let (_, format) = try videoTrack(of: stream)

        XCTAssertEqual(format.frameRate, .film24)
        XCTAssertFalse(format.interlace.isInterlaced,
                       "progressive_sequence=1 の素材を field 符号化に倒してはいけない")
    }

    /// demux した sample 数と復号帧数が一致すること（零長 sample の間引き込み）。
    /// 出力は video-range 4:2:0・coded 寸法（F12）。presentation 順に揃うこと（04 §3 の再整列）。
    func testDemuxDecodeCountsMatchAndOutputIsStableFormat() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)
        let seed = try await demuxer.seedFormatDescription(for: track.id)

        let decoder = VideoToolboxDecoder()
        try await decoder.configure(format, policy: DecodePolicy(), formatDescriptionHint: seed)

        var received = 0
        var decoded: [DecodedVideoFrame] = []
        for try await sample in await demuxer.samples(for: track.id) {
            received += 1
            if let frame = try await decoder.decode(sample) { decoded.append(frame) }
        }
        decoded.append(contentsOf: await decoder.flush())

        // 実測: 6 秒 29.97 のこの素材は 180 sample / 180 帧（EXP-001 §4）。
        XCTAssertEqual(received, 180)
        XCTAssertEqual(decoded.count, received,
                       "受け取った sample 数と復号帧数が一致すること（間引きは demux 段まで）")

        var previousPTS: MediaTime?
        for frame in decoded {
            if let previous = previousPTS {
                XCTAssertGreaterThanOrEqual(frame.pts, previous, "復号出力は presentation 順でなければならない")
            }
            previousPTS = frame.pts
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 720)
            XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), 480)
        }

        let path = await decoder.pathInfo
        XCTAssertEqual(path.path, .videoToolbox)   // OQ-02: 直行経路で足りる（この環境では）

        // スループットの一応の下限（実測 p50 0.5 ms に対して 100 倍以上の余裕。
        // 環境負荷で flaky にならない程度の緩さを選ぶ。厳密な予算判定はベンチの役目）。
        let elapsed = Date().timeIntervalSince(testStart)
        XCTAssertLessThan(elapsed, 20.0, "180 帧の復号が 20 s を超えるのは異常")
    }

    private var testStart = Date()
    override func setUp() { testStart = Date() }

    /// 既知の喪失（EXP-001 F11）を回帰で固定する: field 符号化の H.264 は
    /// この環境の VideoToolbox では progressive として扱われ、field 信号が format に残らない。
    /// 将来 HW / OS で残るようになったらこのテストが失敗し、OQ-08 の前提を見直す合図になる。
    func testInterlacedH264FieldSignalsAreLostByDecoderOnThisMachine() async throws {
        let demuxer = AVFoundationDemuxer(url: try fixtureURL("ntsc480i-h264-01.mp4"))
        let stream = try await demuxer.probe()
        let (_, format) = try videoTrack(of: stream)

        XCTAssertEqual(format.frameRate, .ntsc)
        XCTAssertFalse(format.interlace.isInterlaced,
                       "実測（EXP-001 F11）では tff 素材でも field 信号が復号器を通過しない。"
                       + "変わった場合は OQ-08 の判定を見直すこと")
    }

    /// 破損素材: 途中で終端しても error にならない（sample 列の正常終了）こと。
    func testTruncatedStreamEndsWithoutError() async throws {
        let demuxer = AVFoundationDemuxer(url: try fixtureURL("truncated-01-cut.mpg"))
        let stream = try await demuxer.probe()
        let (track, _) = try videoTrack(of: stream)

        var count = 0
        for try await _ in await demuxer.samples(for: track.id) { count += 1 }
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 60, "400 KB 切断の素材で 60 sample を読むことはない（実測 12）")
    }
}
