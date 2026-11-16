import CoreMedia
import Foundation
import XCTest
@testable import RVDecode
import RVMediaCore

// MARK: - seek 再開路（#13・OQ-23）
//
// 方針（09 §2）: fixture が無い場合は失敗（silent skip で環境差を隠さない）。
// OQ-23 の検証点:
//   1. seek 再開直後にも 0 長 buffer（F5 の -12902 回避）が混入するか — 間引きが効いていること。
//   2. 再生位置が実際に進むこと（reader が seek 位置から組み直されること）。
//   3. 着地は target の keyframe 側であること（実測値をここに記録し、設計値は後で決める）。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-fixtures.sh で生成する）"
    }
}

final class SeekPathTests: XCTestCase {
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

    private func videoTrack(of stream: ProbedStream) throws -> TrackInfo {
        guard let track = stream.tracks.first(where: { $0.kind == .video }) else {
            throw MissingFixture(path: "video track not found")
        }
        return track
    }

    /// seek 再開直後の sample 列: 0 長 buffer が間引かれた形で届くこと（decode 段が
    /// -12902 を受けない契約）と、reader が seek 位置から組み直されることを固定する。
    func testSeekResumeDeliversOnlySamplesWithData() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let probed = try await demuxer.probe()
        let track = try videoTrack(of: probed)

        // 1. cold read の 0 長混入数を基準として取る（EXP-001 F5 の実測が土台）。
        var coldCount = 0
        for try await sample in await demuxer.samples(for: track.id) {
            XCTAssertTrue(sample.hasSampleData,
                          "cold read で 0 長 sample が間引きを抜けた（F5 ゲートの後退）")
            coldCount += 1
        }
        XCTAssertEqual(coldCount, 180, "fixture の宣言（180 sample）")
        let coldGated = await demuxer.gatedEmptySampleCount

        // 2. seek 後の読み直し。実測の着地は 2.502 s（GOP 15 帧 = 0.5 s の境界 2.535 s の
        // 1 帧手前。AVFoundation の key frame index が実 bitstream より手前に寄る）。
        let target = CMTime(seconds: 3.0, preferredTimescale: 1_000_000)
        let effect = try await demuxer.seek(to: target, tolerance: .previousKeyframe)
        XCTAssertEqual(effect.landedAt.seconds, 3.0, accuracy: 0.0001,
                       "SeekEffect.landedAt は要求位置を返す（実際の着地は sample PTS で確認する契約）")

        var delivered = 0
        var firstPTS: Double?
        var lastPTS = 0.0
        var seenPTS: [Double] = []
        for try await sample in await demuxer.samples(for: track.id) {
            // OQ-23 の本命: seek 再開直後にも同じ条件で 0 長が混入しうるが、decode 段に
            // 届いてはならない（-12902 の原因になる）。
            XCTAssertTrue(sample.hasSampleData,
                          "seek 再開で 0 長 sample が間引きを抜けた（OQ-23 の契約後退）")
            let pts = sample.pts.seconds
            if firstPTS == nil { firstPTS = pts }
            lastPTS = max(lastPTS, pts)
            seenPTS.append(pts)
            delivered += 1
        }
        let gatedAfter = await demuxer.gatedEmptySampleCount

        // 契約: target 以上の sample はすべて届く（再生側は target 以上だけを提示する）。
        // 実測では着地直後の GOP 領域（frame 76〜88）の 9 sample を reader 側が届けないが、
        // それはすべて target 前 = 破棄側なので提示完全性には影響しない（下の断言で固定）。
        let frameIndex = { (seconds: Double) in Int((seconds * 30_000 / 1_001).rounded()) }
        let atOrAfterTarget = Set(seenPTS.filter { $0 >= target.seconds - 0.001 }.map(frameIndex))
        let needed = (90...179).filter { !atOrAfterTarget.contains($0) }
        XCTAssertEqual(needed, [], "target 以上の sample が届いていない（提示完全性の欠損）")
        let beforeTarget = Set(seenPTS.filter { $0 < target.seconds - 0.001 }.map(frameIndex))
        let missingBefore = (75...89).filter { !beforeTarget.contains($0) && !atOrAfterTarget.contains($0) }
        print("OQ-23 実測: cold read \(coldCount) sample / gated \(coldGated)"
            + " — seek(3.0s) 後 \(delivered) sample / gated \(gatedAfter - coldGated)"
            + " / 着地 PTS \(String(format: "%.3f", firstPTS ?? -1))"
            + " / 末尾 PTS \(String(format: "%.3f", lastPTS))"
            + " / target 前の欠番 frame \(missingBefore)")

        XCTAssertGreaterThan(delivered, 0, "seek 後に sample が届かない（reader が組み直されていない）")
        XCTAssertLessThanOrEqual((firstPTS ?? 0), target.seconds + 0.05,
                                 "target を大きく越して着いた（keyframe 側へ寄る設計が壊れた）")
        XCTAssertGreaterThan(firstPTS ?? 0, 1.0,
                             "seek が効かず先頭から読んでいる（reader 位置が引き継がれていない）")
        XCTAssertGreaterThan(lastPTS, 5.5, "最後まで読めていない（seek 後の終了条件が壊れた)")
    }
}
