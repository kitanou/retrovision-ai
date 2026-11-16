import XCTest
@testable import RVMLRuntime

/// 06 §6 の障害分離（failure breaker）。5 中 3 失敗で open、10 分後に half-open で 1 本だけ試す。
final class ModelHealthTrackerTests: XCTestCase {
    func testThreeFailuresInFiveOpensTheBreaker() {
        var b = FailureBreaker()
        for success in [true, false, true, false] { b.record(success: success, atSeconds: 0) }
        XCTAssertEqual(b.state, .closed, "5 中 2 失敗ではまだ closed")
        b.record(success: false, atSeconds: 1)
        XCTAssertEqual(b.state, .open, "5 中 3 失敗で open")
        XCTAssertFalse(b.allowRequest(atSeconds: 2), "open 中は推論を投入しない（disabledByBreaker）")
    }

    func testOldFailuresFallOutOfTheWindow() {
        var b = FailureBreaker()
        b.record(success: false, atSeconds: 0)
        b.record(success: false, atSeconds: 0)
        for _ in 0..<5 { b.record(success: true, atSeconds: 0) }   // 窓の外へ押し出す
        b.record(success: false, atSeconds: 0)
        XCTAssertEqual(b.state, .closed, "窓から出た失敗は数えない")
    }

    func testHalfOpenAllowsExactlyOneTrialAndClosesOnSuccess() {
        var b = FailureBreaker(config: .init(openDurationSeconds: 600))
        for _ in 0..<3 { b.record(success: false, atSeconds: 100) }
        XCTAssertEqual(b.state, .open)
        XCTAssertFalse(b.allowRequest(atSeconds: 699), "10 分未満は open のまま")
        XCTAssertTrue(b.allowRequest(atSeconds: 700), "10 分後は half-open の試行を 1 本通す")
        XCTAssertEqual(b.state, .halfOpen)
        XCTAssertFalse(b.allowRequest(atSeconds: 701), "試行の結果が出るまで 2 本目は通さない")
        b.record(success: true, atSeconds: 702)
        XCTAssertEqual(b.state, .closed, "試行成功で closed")
        XCTAssertEqual(b.failureRatio, 0, "closed に戻ったら履歴は空")
        XCTAssertTrue(b.allowRequest(atSeconds: 703))
    }

    func testHalfOpenFailureReopensForAnotherFullPeriod() {
        var b = FailureBreaker(config: .init(openDurationSeconds: 600))
        for _ in 0..<3 { b.record(success: false, atSeconds: 0) }
        XCTAssertTrue(b.allowRequest(atSeconds: 600))
        b.record(success: false, atSeconds: 610)
        XCTAssertEqual(b.state, .open, "試行失敗で再び open")
        XCTAssertFalse(b.allowRequest(atSeconds: 1_000), "再 open は失敗時刻から 10 分")
        XCTAssertTrue(b.allowRequest(atSeconds: 1_210))
    }

    func testHealthReportsPercentilesAndBreakerState() {
        var t = ModelHealthTracker()
        for ms in 1...100 { t.recordSuccess(latencyMS: Double(ms), atSeconds: 0) }
        let h = t.health
        XCTAssertEqual(h.p50MS, 50, accuracy: 2)
        XCTAssertEqual(h.p95MS, 95, accuracy: 2)
        XCTAssertEqual(h.breakerState, .closed)
        for _ in 0..<3 { t.recordFailure(atSeconds: 1) }
        XCTAssertEqual(t.health.breakerState, .open)
    }
}
