import XCTest
@testable import RVVideoPipeline

/// 確信してロックしている間だけ field matching を指示し、PTS が連続でなければ判定と前 frame を捨てる。
final class TelecineMatcherTests: XCTestCase {
    private let frameDuration = 1001.0 / 30000.0
    private func scores(_ count: Int, startPhase: Int = 0) -> [Double] {
        let pattern = [false, false, true, true, false]
        return (0..<count).map { pattern[($0 + startPhase) % 5] ? 0.045 : 0.008 }
    }

    func testNoRequestBeforeLockThenWeaveOnCombedPhasesOnly() {
        var matcher = TelecineMatcher()
        var results: [TelecineMatcher.Result] = []
        for (i, s) in scores(40).enumerated() {
            results.append(matcher.match(score: s, pts: Double(i) * frameDuration, duration: frameDuration))
        }
        let lock = results.firstIndex { $0.decision.cadence == .telecine32 }
        XCTAssertNotNil(lock)
        XCTAssertTrue(results.prefix(lock ?? 0).allSatisfy { $0.request == .none }, "ロック前は何も指示しない")
        for (i, r) in results.enumerated().dropFirst(lock ?? 0) {
            let expected: RenderFrameInput.FieldMatchRequest = (i % 5 == 2 || i % 5 == 3) ? .weaveWithPrevious : .keepWoven
            XCTAssertEqual(r.request, expected, "frame \(i)（周期内位置 \(i % 5)）の指示が違う")
            XCTAssertTrue(r.previousIsContinuous)
        }
    }

    func testDiscontinuityDropsTheLockAndThePreviousFrame() {
        var matcher = TelecineMatcher()
        var pts = 0.0
        for s in scores(30) { _ = matcher.match(score: s, pts: pts, duration: frameDuration); pts += frameDuration }
        // seek: PTS が飛ぶ。この frame は連続でない → 前 frame を渡さず、指示もしない。
        let afterSeek = matcher.match(score: 0.045, pts: pts + 60, duration: frameDuration)
        XCTAssertFalse(afterSeek.previousIsContinuous, "PTS が飛んだのに前 frame を連続と見なした")
        XCTAssertEqual(afterSeek.request, .none)
        // seek 直後の数 frame はロックし直すまで何も指示しない（誤った weave を避ける）。
        var p = pts + 60 + frameDuration
        var requests: [RenderFrameInput.FieldMatchRequest] = []
        for s in scores(8, startPhase: 4) { requests.append(matcher.match(score: s, pts: p, duration: frameDuration).request); p += frameDuration }
        XCTAssertTrue(requests.allSatisfy { $0 == .none }, "ロックし直す前に weave を指示した")
    }

    func testDroppedFrameBreaksContinuity() {
        var matcher = TelecineMatcher()
        var pts = 0.0
        for s in scores(30) { _ = matcher.match(score: s, pts: pts, duration: frameDuration); pts += frameDuration }
        let r = matcher.match(score: 0.008, pts: pts + frameDuration, duration: frameDuration)   // 1 frame 飛ばし
        XCTAssertFalse(r.previousIsContinuous)
        XCTAssertEqual(r.request, .none)
    }

    func testNonTelecineSourceNeverGetsARequest() {
        var matcher = TelecineMatcher()
        var any = false
        for i in 0..<120 {
            let r = matcher.match(score: 0.0065 + 0.0003 * Double(i % 3), pts: Double(i) * frameDuration, duration: frameDuration)
            if r.request != .none { any = true }
        }
        XCTAssertFalse(any, "周期のない素材に field matching を指示した")
    }
}
