import RVMediaCore
import XCTest
@testable import RVVideoPipeline

/// 05 §5.1: 3:2 telecine は 5 frame 周期 [clean, clean, combed, combed, clean]。10 frame の完全一致で
/// ロックし、予測と 2 frame 連続で食い違ったら抜ける。
final class CadenceAnalyzerTests: XCTestCase {
    private let clean = 0.0, combed = 0.5

    private func telecine(frames: Int, startPhase: Int) -> [Double] {
        let pattern = [false, false, true, true, false]
        return (0..<frames).map { pattern[(startPhase + $0) % 5] ? combed : clean }
    }

    func testTelecineLocksAfterTenFramesForEveryPhase() {
        for startPhase in 0..<5 {
            var analyzer = CadenceAnalyzer()
            var last: CadenceDecision?
            var firstLockIndex: Int?
            for (i, score) in telecine(frames: 25, startPhase: startPhase).enumerated() {
                last = analyzer.ingest(combScore: score)
                if last?.cadence == .telecine32, firstLockIndex == nil { firstLockIndex = i }
            }
            XCTAssertEqual(firstLockIndex, 9, "位相\(startPhase): 10 frame 目（index 9）でロックする")
            XCTAssertEqual(last?.cadence, .telecine32)
            XCTAssertEqual(last?.telecinePhase, (startPhase + 24) % 5, "位相\(startPhase): 直近 frame の周期内位置が合う")
        }
    }

    func testAllCombedIsInterlacedAndAllCleanIsProgressive() {
        var interlaced = CadenceAnalyzer()
        var progressive = CadenceAnalyzer()
        var a: CadenceDecision?, b: CadenceDecision?
        for _ in 0..<12 {
            a = interlaced.ingest(combScore: combed)
            b = progressive.ingest(combScore: clean)
        }
        XCTAssertEqual(a?.cadence, .interlaced22)
        XCTAssertEqual(b?.cadence, .progressive)
    }

    func testDoesNotDeclareTelecineBeforeTheWindowIsFull() {
        var analyzer = CadenceAnalyzer()
        var decisions: [CadenceDecision] = []
        for score in telecine(frames: 9, startPhase: 0) { decisions.append(analyzer.ingest(combScore: score)) }
        XCTAssertTrue(decisions.allSatisfy { $0.cadence != .telecine32 }, "9 frame ではロックしない（確信度が足りない）")
    }

    func testOneMismatchKeepsLockButTwoConsecutiveLeavesIt() {
        var analyzer = CadenceAnalyzer()
        for score in telecine(frames: 10, startPhase: 0) { _ = analyzer.ingest(combScore: score) }
        // 次に来るのは位相 0（clean）。1 回だけ combed が来ても（静止場面の取りこぼし等）ロックは保つ。
        XCTAssertEqual(analyzer.ingest(combScore: combed).cadence, .telecine32, "1 frame の食い違いでは抜けない")
        // その次は位相 1（clean）の予測。ここでも食い違うと 2 連続 → 抜ける。
        XCTAssertNotEqual(analyzer.ingest(combScore: combed).cadence, .telecine32, "2 frame 連続の食い違いで抜ける")
    }

    func testLeavesTelecineWhenSourceBecomesAllCombedAndSettlesToInterlaced() {
        var analyzer = CadenceAnalyzer()
        for score in telecine(frames: 20, startPhase: 0) { _ = analyzer.ingest(combScore: score) }
        var last: CadenceDecision?
        for _ in 0..<12 { last = analyzer.ingest(combScore: combed) }
        XCTAssertEqual(last?.cadence, .interlaced22, "全 frame が縞ありになれば interlaced22 に落ち着く")
    }

    func testEvidenceIsStableAndDiffersForDifferentWindows() {
        var a = CadenceAnalyzer(), b = CadenceAnalyzer(), c = CadenceAnalyzer()
        var da: CadenceDecision?, db: CadenceDecision?, dc: CadenceDecision?
        for s in telecine(frames: 12, startPhase: 0) { da = a.ingest(combScore: s) }
        for s in telecine(frames: 12, startPhase: 0) { db = b.ingest(combScore: s) }
        for s in telecine(frames: 12, startPhase: 2) { dc = c.ingest(combScore: s) }
        XCTAssertEqual(da?.evidence, db?.evidence, "同じ入力は同じ根拠ハッシュ（再現性）")
        XCTAssertNotEqual(da?.evidence, dc?.evidence, "窓が違えば根拠も違う")
    }
}
