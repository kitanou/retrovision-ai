import AVFoundation
import CoreMedia
import XCTest
@testable import RVDecode
import RVMediaCore

// MARK: - 多重 VOB 連結 demux の検査（03 §4、#3。このファイルが兼実測）
//
// 方針（09 §2）: fixture が無い場合は失敗（silent skip しない）。
// 素材は Scripts/gen-dvd-fixture.sh が生成する（ntsc480i-ac3-01.mpg を pack 境界で
// 2 分割した VTS_01_1/2.VOB — 連結すると母素材とバイト一致）。
//
// 実装の契約（ConcatPSDemuxer の実測根拠に対応）: 連結後の列は「母素材を単一ファイルと
// して読んだ列」と一致すること。バイト一致の素材では逐語一致で検査できる。実 DVD の
// 多重 VOB（母素材が存在しない）ではこの検査は「境界で途切れない」側の意味を持つ。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-dvd-fixture.sh で生成する）"
    }
}

final class ConcatPSDemuxerTests: XCTestCase {
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

    private func vobURL(_ name: String) throws -> URL {
        let url = fixturesDir.appendingPathComponent("dvd-video-ts-01/VIDEO_TS").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFixture(path: url.path)
        }
        return url
    }

    private func singleURL(_ name: String) throws -> URL {
        let url = fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFixture(path: url.path)
        }
        return url
    }

    private func videoTrack(of stream: ProbedStream) throws -> TrackInfo {
        guard let track = stream.tracks.first(where: { $0.kind == .video }) else {
            throw MissingFixture(path: "video track not found")
        }
        return track
    }

    private func audioTrack(of stream: ProbedStream) throws -> TrackInfo {
        guard let track = stream.tracks.first(where: { $0.kind == .audio }) else {
            throw MissingFixture(path: "audio track not found")
        }
        return track
    }

    /// 圧縮 sample 列の有効 PTS 列（F5 ゲート相当で data 無し marker を除く）。
    private func validVideoPTS(from demuxer: some Demuxer, track: TrackID) async throws -> [Double] {
        var pts: [Double] = []
        var iterator = (await demuxer.samples(for: track)).makeAsyncIterator()
        while let sample = try await iterator.next() {
            guard sample.hasSampleData, sample.pts.seconds.isFinite else { continue }
            pts.append(sample.pts.seconds)
        }
        return pts
    }

    // MARK: - 1. 連結 probe は単一ファイルの probe と同じ構造を返す

    func testConcatProbeMatchesSingleFileProbe() async throws {
        let concat = ConcatPSDemuxer(partURLs: [try vobURL("VTS_01_1.VOB"),
                                                try vobURL("VTS_01_2.VOB")])
        let probed = try await concat.probe()
        XCTAssertFalse(probed.tracks.isEmpty, "連結後のトラック表が空")

        let single = AVFoundationDemuxer(url: try singleURL("ntsc480i-ac3-01.mpg"))
        let expected = try await single.probe()

        // fixture の連結は母素材とバイト一致（gen-dvd-fixture.sh の byte-slice 分割）。
        // トラック表の形（種別ごとの本数）は一致すること。
        XCTAssertEqual(probed.tracks.filter { $0.kind == .video }.count,
                       expected.tracks.filter { $0.kind == .video }.count,
                       "映像トラックの列挙が単一ファイルと違う（03 §4）")
        XCTAssertEqual(probed.tracks.filter { $0.kind == .audio }.count,
                       expected.tracks.filter { $0.kind == .audio }.count,
                       "音声トラックの列挙が単一ファイルと違う")
        guard let total = probed.programDuration, let expectedTotal = expected.programDuration else {
            return XCTFail("programDuration が揃わない（concat=\(String(describing: probed.programDuration)) single=\(String(describing: expected.programDuration)))）")
        }
        // 実測: バイト一致なので declared 長も一致する（tolerance は同一実装の揺らぎ用）。
        XCTAssertLessThan(abs(total.seconds - expectedTotal.seconds), 0.05,
                          "連結後の総時間が単一ファイルと違う: \(total.seconds) vs \(expectedTotal.seconds)")
    }

    // MARK: - 2. sample 連続性: 連結後の列は単一ファイルの列と一致する

    func testConcatVideoStreamMatchesSingleFileStream() async throws {
        let single = AVFoundationDemuxer(url: try singleURL("ntsc480i-ac3-01.mpg"))
        let singleProbed = try await single.probe()
        let singlePTS = try await validVideoPTS(from: single, track: try videoTrack(of: singleProbed).id)

        let concat = ConcatPSDemuxer(partURLs: [try vobURL("VTS_01_1.VOB"),
                                                try vobURL("VTS_01_2.VOB")])
        let concatProbed = try await concat.probe()
        let concatPTS = try await validVideoPTS(from: concat, track: try videoTrack(of: concatProbed).id)

        // 兼実測: 母素材（180 frame の bitstream。#11/#12 で AVF 経由の実数を記録済み）の
        // 列と連結後の列が同数・逐語一致であることを検証する。
        XCTAssertFalse(singlePTS.isEmpty, "単一ファイルの列が取れない（fixture の退行）")
        XCTAssertEqual(concatPTS.count, singlePTS.count,
                       "連結後の有効 sample 数が単一ファイルと違う（母素材はバイト一致）")
        for (a, e) in zip(concatPTS, singlePTS) {
            XCTAssertLessThan(abs(a - e), 1e-6, "sample PTS がずれている: \(a) vs \(e)")
        }
        // 境界近傍（連結 offset ≈ part1 実長）に sample が存在すること = 途切れ無し。
        let part1End = try await Self.part1TrackEnd()
        let aroundBoundary = concatPTS.filter { $0 > part1End - 0.5 && $0 < part1End + 0.5 }
        XCTAssertGreaterThanOrEqual(aroundBoundary.count, 8,
                                   "境界窓の sample が足りない: \(aroundBoundary.count)（境界で落ちている）")
    }

    /// VTS_01_1.VOB の track 終端（生成タイムラインの実測値。境界位置の目安）。
    private static func part1TrackEnd() async throws -> Double {
        let url = dvdFixturesDir().appendingPathComponent("VIDEO_TS/VTS_01_1.VOB")
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let range = try await track?.load(.timeRange)
        return range?.duration.seconds ?? 0
    }

    private static func dvdFixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVDecodeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("fixtures/generated/dvd-video-ts-01")
    }

    // MARK: - 3. 音声の連続性: 境界を跨いで PCM が単調 PTS で届く（単一ファイルと同長）

    func testAudioPCMSpansBoundaryWithMonotonicPTS() async throws {
        let concat = ConcatPSDemuxer(partURLs: [try vobURL("VTS_01_1.VOB"),
                                                try vobURL("VTS_01_2.VOB")])
        let probed = try await concat.probe()
        let track = try audioTrack(of: probed)

        var chunks: Int = 0
        var lastEnd: Double = -1
        var totalSeconds: Double = 0
        var pcmIterator = (await concat.pcmSamples(for: track.id,
                                                   target: PCMTargetSettings(sampleRate: 48_000,
                                                                            channelCount: 2))).makeAsyncIterator()
        while let chunk = try await pcmIterator.next() {
            let start = CMSampleBufferGetPresentationTimeStamp(chunk.buffer).seconds
            let frames = CMSampleBufferGetNumSamples(chunk.buffer)
            guard frames > 0, start.isFinite else { continue }
            XCTAssertGreaterThanOrEqual(start, lastEnd - 0.05,
                                       "PCM 逆行・大きな飛び at chunk \(chunks): \(start) vs \(lastEnd)")
            lastEnd = start + Double(frames) / 48_000.0
            totalSeconds = lastEnd
            chunks += 1
        }
        XCTAssertGreaterThan(chunks, 5, "PCM chunk が届かない（\(chunks)）")

        // 対照: 単一ファイル（母素材）の PCM 総長。連結後は同じ量が届くこと。
        let single = AVFoundationDemuxer(url: try singleURL("ntsc480i-ac3-01.mpg"))
        let singleProbed = try await single.probe()
        let singleTrack = try audioTrack(of: singleProbed)
        var singleTotal: Double = 0
        var singleIterator = (await single.pcmSamples(for: singleTrack.id,
                                                      target: PCMTargetSettings(sampleRate: 48_000,
                                                                               channelCount: 2))).makeAsyncIterator()
        while let chunk = try await singleIterator.next() {
            let start = CMSampleBufferGetPresentationTimeStamp(chunk.buffer).seconds
            let frames = CMSampleBufferGetNumSamples(chunk.buffer)
            guard frames > 0, start.isFinite else { continue }
            singleTotal = max(singleTotal, start + Double(frames) / 48_000.0)
        }
        XCTAssertGreaterThan(singleTotal, 5.0, "単一ファイル側の PCM が足りない（fixture の退行）: \(singleTotal)")
        XCTAssertGreaterThan(totalSeconds, singleTotal - 0.3,
                             "音声の総長が単一ファイルより足りない: \(totalSeconds)s vs \(singleTotal)s（境界で欠落）")
    }

    // MARK: - 4. チェーン終端付近の seek: 意味論は単一ファイルと同じ

    func testSeekNearChainEndStillYieldsSamples() async throws {
        let concat = ConcatPSDemuxer(partURLs: [try vobURL("VTS_01_1.VOB"),
                                                try vobURL("VTS_01_2.VOB")])
        let probed = try await concat.probe()
        let track = try videoTrack(of: probed)
        guard let total = probed.programDuration else { return XCTFail("programDuration 無し") }
        // 実測（#13 の単一ファイル seek 契約の続測）: AVAssetReader は target 位置の境界
        // buffer を 1 本添え、復号順のう回（GOP 内の前 frame）を返しながら続く。
        // 連結後は「終端 1.0s 手前」が part2 の側にある — 境界 cross 後の seek が成立すること。
        let target = CMTimeSubtract(total, CMTime(seconds: 1.0, preferredTimescale: 600))
        _ = try await concat.seek(to: target, tolerance: .near(CMTime(seconds: 0.5, preferredTimescale: 600)))

        var count = 0
        var first: Double = -1
        var maxPTS: Double = 0
        var seekIterator = (await concat.samples(for: track.id)).makeAsyncIterator()
        while let sample = try await seekIterator.next() {
            guard sample.hasSampleData, sample.pts.seconds.isFinite else { continue }
            if first < 0 { first = sample.pts.seconds }
            maxPTS = max(maxPTS, sample.pts.seconds)
            count += 1
        }
        XCTAssertGreaterThan(count, 5, "終端 1.0s 手前から読めなかった（\(count)）")
        XCTAssertLessThan(first, target.seconds + 1.0,
                          "seek 着地が遅すぎる/何も届かない: first=\(first) count=\(count)")
        XCTAssertGreaterThan(maxPTS, total.seconds - 0.7,
                             "終端まで届かない: max=\(maxPTS) total=\(total.seconds)")
    }

    // MARK: - 5. 単一 part は素のファイル demux と同一（退行防止・一時コピーなし経路）

    func testSinglePartMatchesPlainFileDemux() async throws {
        let single = AVFoundationDemuxer(url: try singleURL("ntsc480i-ac3-01.mpg"))
        let singleProbed = try await single.probe()
        let singlePTS = try await validVideoPTS(from: single, track: try videoTrack(of: singleProbed).id)

        let concat = ConcatPSDemuxer(partURLs: [try singleURL("ntsc480i-ac3-01.mpg")])
        let concatProbed = try await concat.probe()
        let concatPTS = try await validVideoPTS(from: concat, track: try videoTrack(of: concatProbed).id)

        XCTAssertEqual(concatPTS.count, singlePTS.count, "単一 part の sample 数が素の経路と違う")
        for (a, e) in zip(concatPTS, singlePTS) {
            XCTAssertLessThan(abs(a - e), 1e-6, "sample PTS がずれている: \(a) vs \(e)")
        }
    }
}
