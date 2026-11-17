import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import RVDecode
import RVMediaCore

/// DVD のタイトルメニュー（VTS_nn_0.VOB）= 静止画 1 枚だけの program stream。
/// AVFoundation はこの形から sample を渡さない（実測）ので、StillPSDemuxer が映像 ES を自前で取り出す。
final class StillPSDemuxerTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/generated/menu-still-01.vob")
    }

    // MARK: program stream の解析（純粋関数）

    /// pack header（14 byte）+ 指定の PES を並べた合成 PS。
    private func pack(_ pes: [(id: UInt8, payload: [UInt8], headerData: Int)]) -> Data {
        var d = Data([0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])   // stuffing 0
        for p in pes {
            let pesHeaderData = [UInt8](repeating: 0xFF, count: p.headerData)
            let length = 3 + p.headerData + p.payload.count
            d.append(contentsOf: [0, 0, 1, p.id, UInt8(length >> 8), UInt8(length & 0xFF), 0x81, 0x00, UInt8(p.headerData)])
            d.append(contentsOf: pesHeaderData)
            d.append(contentsOf: p.payload)
        }
        return d
    }

    func testExtractsOnlyVideoPESPayloadsInOrderAndSkipsHeaderData() {
        let ps = pack([(0xE0, [1, 2, 3], 5),           // 映像（header data 5 byte）
                       (0xBD, [9, 9, 9, 9], 0),         // private stream 1（字幕・音声）は無視
                       (0xBF, [8, 8], 0),               // private stream 2（NAV）は無視
                       (0xE0, [4, 5], 0)])              // 映像の続き
        XCTAssertEqual([UInt8](StillPSDemuxer.extractVideoES(from: ps)), [1, 2, 3, 4, 5])
    }

    func testTruncatedPacketKeepsWhatWasReadAndNeverCrashes() {
        var ps = pack([(0xE0, [1, 2, 3], 0)])
        ps.append(contentsOf: [0, 0, 1, 0xE0, 0x07, 0xD0, 0x81, 0, 0])   // 長さ 2000 だが、データが無い（途中で切れた）
        XCTAssertEqual([UInt8](StillPSDemuxer.extractVideoES(from: ps)), [1, 2, 3], "切れた packet より前は取り出せる")
        XCTAssertTrue(StillPSDemuxer.extractVideoES(from: Data()).isEmpty)
        XCTAssertTrue(StillPSDemuxer.extractVideoES(from: Data([0, 0, 1])).isEmpty)
    }

    // MARK: 実際の素材（AVFoundation が読めない 1 枚だけの VOB）

    func testAVFoundationCannotReadTheFixtureWhichIsWhyTheDemuxerExists() async throws {
        let asset = AVURLAsset(url: fixture)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        // 前提の固定: AVFoundation は映像 track を見つけられない（長さも不定）。ここが変われば不要になるかも。
        XCTAssertTrue(tracks.isEmpty, "AVFoundation が読めるようになった — StillPSDemuxer が不要か再検討する")
    }

    func testProbeReportsOneFrameWithTheSequenceHeaderSignals() async throws {
        let demuxer = StillPSDemuxer(url: fixture)
        let stream = try await demuxer.probe()
        let video = try XCTUnwrap(stream.tracks.first { $0.kind == .video })
        guard case let .video(format) = video.format else { return XCTFail("映像の format が無い") }
        XCTAssertEqual(format.codedSize, PixelSize(width: 720, height: 480))
        XCTAssertEqual(format.frameRate, .ntsc)
        XCTAssertEqual(format.aspectSignals.mpegAspectInformation, .dar4x3)
        XCTAssertEqual(format.sampleAspect, .bt601NTSCSample)
        XCTAssertFalse(format.interlace.isInterlaced, "静止画のメニューは progressive として扱う（deinterlace で解像度を落とさない）")
        XCTAssertEqual(try XCTUnwrap(stream.programDuration).seconds, 1001.0 / 30000.0, accuracy: 1e-6)
    }

    func testDecodesExactlyOneFrameThroughVideoToolbox() async throws {
        let demuxer = StillPSDemuxer(url: fixture)
        let stream = try await demuxer.probe()
        let track = try XCTUnwrap(stream.tracks.first { $0.kind == .video })
        guard case let .video(format) = track.format else { return XCTFail("映像の format が無い") }
        let decoder = VideoToolboxDecoder()
        try await decoder.configure(format, policy: DecodePolicy(), formatDescriptionHint: nil)
        var frames: [DecodedVideoFrame] = []
        for try await sample in await demuxer.samples(for: track.id) {
            if let f = try await decoder.decode(sample) { frames.append(f) }
        }
        frames.append(contentsOf: await decoder.flush())
        XCTAssertEqual(frames.count, 1, "静止画 1 枚から復号できた frame 数")
        let pb = try XCTUnwrap(frames.first).pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 720)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 480)
        // 中身がある（真っ黒・真っ平らではない）: 輝度の最大と最小が離れている。
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var lo = 255, hi = 0
        for row in 0..<480 { for x in stride(from: 0, to: 720, by: 8) { let v = Int(y[row * rowBytes + x]); lo = min(lo, v); hi = max(hi, v) } }
        XCTAssertGreaterThan(hi - lo, 80, "復号した画が平らすぎる（輝度の範囲 \(lo)〜\(hi)）")
    }

    func testSeekAlwaysLandsOnTheOnlyPicture() async throws {
        let demuxer = StillPSDemuxer(url: fixture)
        _ = try await demuxer.probe()
        let effect = try await demuxer.seek(to: MediaTime(seconds: 5, preferredTimescale: 600), tolerance: .exact)
        XCTAssertEqual(effect.landedAt, .zero)
    }

    func testMissingFileIsATypedError() async {
        let demuxer = StillPSDemuxer(url: URL(fileURLWithPath: "/nonexistent/VTS_01_0.VOB"))
        do { _ = try await demuxer.probe(); XCTFail("存在しないファイルは失敗するはず") }
        catch let error as PlaybackError { XCTAssertEqual(error.kind, .source(.unreadable)) }
        catch { XCTFail("型付きのエラーが期待: \(error)") }
    }
}
