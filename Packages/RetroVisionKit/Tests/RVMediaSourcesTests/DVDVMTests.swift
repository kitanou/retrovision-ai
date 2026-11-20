import XCTest

@testable import RVMediaSources

/// VM の評価。コマンドは仕様のビット位置どおりに組み立てた合成データ
/// （実盤のメニュー PGC のコマンドの形 = GPRM15 に ボタン << 10 を組み立てて SetHL_BTNN する、と同じ構造）。
final class DVDVMTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { UInt8(s[s.index(s.startIndex, offsetBy: $0)...][..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)! }
    }
    private func run(_ cmds: [String], _ r: inout DVDRegisters) -> DVDVMRun { DVDVM.run(cmds.map(hex), registers: &r) }

    func testSetImmediateAndRegisterCopy() {
        var r = DVDRegisters.initial()
        _ = run(["710000" + "0a" + "000100" + "00",      // GPRM10 = 1
                 "6100000200870000"], &r)                // GPRM2 = SPRM7（PTTN）
        XCTAssertEqual(r.gprm[10], 1)
        XCTAssertEqual(r.gprm[2], r.sprm[7])
    }

    func testButtonPreselectionLikeARealMenuPGC() {
        var r = DVDRegisters.initial()
        let out = run(["7100000f00030000",   // GPRM15 = 3
                       "7500000f04000000",   // GPRM15 *= 1024
                       "46000000000f0000"],  // SetHL_BTNN（GPRM15）
                      &r)
        XCTAssertEqual(out.outcome, .finished)
        XCTAssertEqual(r.highlightedButton, 3)
        XCTAssertTrue(out.unsupported.isEmpty)
    }

    func testConditionalGotoAndLinkWithButton() {
        var r = DVDRegisters.initial()
        r.gprm[1] = 4
        // 1: if GPRM1 == 4 goto 3   2: JumpTT 9（飛ばされる）   3: if GPRM1 == 4 LinkCN 1 button 12
        let out = run(["00a1000100040003", "3002000000090000", "20a7000100043001"], &r)
        XCTAssertEqual(out.outcome, .link(.cell(1), button: 12))
        XCTAssertEqual(r.highlightedButton, 12, "リンクのボタン欄が SPRM8 に入る")
    }

    func testFalseConditionFallsThrough() {
        var r = DVDRegisters.initial()
        r.gprm[1] = 5
        let out = run(["20a7000100043001"], &r)
        XCTAssertEqual(out.outcome, .finished)
    }

    func testJumpVTSPTTAndSystemSpace() {
        var r = DVDRegisters.initial()
        XCTAssertEqual(run(["3005000200010000"], &r).outcome, .jump(.jumpVTSChapter(ttn: 1, ptt: 2)))
        XCTAssertEqual(run(["3006000001830000"], &r).outcome, .jump(.jumpSystemSpace(.vtsMenu(vts: 1, ttn: 0, menu: 3))))
    }

    func testBreakEndsTheTable() {
        var r = DVDRegisters.initial()
        XCTAssertEqual(run(["0002000000000000", "3002000000090000"], &r).outcome, .finished)
    }

    func testArithmeticSaturatesAndGuardsDivideByZero() {
        var r = DVDRegisters.initial()
        r.gprm[0] = 0xFFF0
        _ = run(["7300000000200000"], &r)       // += 0x20 → 飽和
        XCTAssertEqual(r.gprm[0], 0xFFFF)
        _ = run(["7400000000000000"], &r)       // GPRM0 -= 0
        _ = run(["7600000000000000"], &r)       // /= 0 → 何もしない
        XCTAssertEqual(r.gprm[0], 0xFFFF)
        r.gprm[0] = 3
        _ = run(["7400000000050000"], &r)       // -= 5 → 0
        XCTAssertEqual(r.gprm[0], 0)
    }

    func testType4To6AreCountedNotExecuted() {
        var r = DVDRegisters.initial()
        let out = run(["8000000000000000", "3002000000090000"], &r)
        XCTAssertEqual(out.unsupported.count, 1)
        XCTAssertEqual(out.outcome, .jump(.jumpTitle(ttn: 9)), "未対応の命令は飛ばして続ける")
    }

    func testRunawayLoopIsCut() {
        var r = DVDRegisters.initial()
        XCTAssertEqual(run(["0001000000000001"], &r).outcome, .finished)   // goto 1（自分自身）
    }
}
