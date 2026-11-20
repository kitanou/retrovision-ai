import XCTest

@testable import RVMediaSources

final class DVDTitleFlowTests: XCTestCase {
    private func cmd(_ s: String) -> [UInt8] {
        (0..<s.count / 2).map { UInt8(s[s.index(s.startIndex, offsetBy: $0 * 2)...][..<s.index(s.startIndex, offsetBy: $0 * 2 + 2)], radix: 16)! }
    }
    private func pgc(pre: [String] = [], post: [String] = []) -> DVDPGC {
        DVDPGC(programCount: 1, programMap: [1], cells: [], duration: 0, palette: [],
               preCommands: pre.map(cmd), postCommands: post.map(cmd), cellCommands: [])
    }
    private func info(_ pgcs: [DVDPGC]) -> DVDTitleSetInfo {
        DVDTitleSetInfo(titles: pgcs.indices.map { DVDTitle(number: $0 + 1, pgcNumber: $0 + 1, duration: 0, chapters: []) },
                        titlePGCs: pgcs, menus: [], timeline: DVDSectorTimeline(cells: []))
    }

    /// 実盤の作り: PRE で GPRM15 = 1、GPRM12 == GPRM15 ならメニューを呼ぶ。POST で GPRM12 = 1 して自分へ Link。
    private let pichi = (pre: ["7100000f00010000", "3028000001830c0f"], post: ["7100000c00010000", "2004000000000001"])

    func testFirstEntryPlaysAndTheEndLinksBackToTheMenu() {
        let i = info([pgc(pre: pichi.pre, post: pichi.post)])
        var r = DVDRegisters.initial()
        XCTAssertEqual(DVDTitleFlow.enter(pgc: 1, in: i, registers: &r), .play(pgc: 1), "GPRM12 = 0 の間はメニューを呼ばない")
        XCTAssertEqual(r.gprm[15], 1)
        XCTAssertEqual(DVDTitleFlow.afterPlayback(pgc: 1, in: i, registers: &r), .action(.showMenu),
                       "POST の GPRM12 = 1 → 自分へ Link → PRE の条件が成立してメニュー")
        XCTAssertEqual(r.gprm[12], 1, "レジスタは持ち回る")
    }

    func testRegistersCarryOverFromTheMenuToTheTitle() {
        // メニュー側が GPRM12 = 1 のままなら、入った直後にメニューへ戻る（レジスタの持ち回りが効いている証拠）。
        let i = info([pgc(pre: pichi.pre, post: pichi.post)])
        var r = DVDRegisters.initial()
        r.gprm[12] = 1
        XCTAssertEqual(DVDTitleFlow.enter(pgc: 1, in: i, registers: &r), .action(.showMenu))
    }

    func testNoPostCommandsStops() {
        var r = DVDRegisters.initial()
        XCTAssertEqual(DVDTitleFlow.afterPlayback(pgc: 1, in: info([pgc()]), registers: &r), .stop)
    }

    func testDirectCallInPost() {
        var r = DVDRegisters.initial()
        XCTAssertEqual(DVDTitleFlow.afterPlayback(pgc: 1, in: info([pgc(post: ["3008000001830000"])]), registers: &r),
                       .action(.showMenu))
    }

    func testLinkToTheNextPGCPlaysItAfterItsPre() {
        // PGC 1 の POST は LinkPGCN 2。PGC 2 の PRE に行き先が無ければ PGC 2 を再生する。
        var r = DVDRegisters.initial()
        let i = info([pgc(post: ["2004000000000002"]), pgc()])
        XCTAssertEqual(DVDTitleFlow.afterPlayback(pgc: 1, in: i, registers: &r), .play(pgc: 2))
    }

    func testSelfLinkWithoutARedirectReplaysThePGC() {
        var r = DVDRegisters.initial()
        XCTAssertEqual(DVDTitleFlow.afterPlayback(pgc: 1, in: info([pgc(post: ["2004000000000001"])]), registers: &r),
                       .play(pgc: 1), "自分への Link で PRE に行き先が無ければ再生し直し")
    }

    func testAnEndlessPreLinkLoopIsCut() {
        // PRE が自分へ Link し続ける形（PGC 1 の PRE = LinkPGCN 1）は 8 回で打ち切って stop。
        var r = DVDRegisters.initial()
        XCTAssertEqual(DVDTitleFlow.enter(pgc: 1, in: info([pgc(pre: ["2004000000000001"])]), registers: &r), .stop)
    }
}
