import XCTest
@testable import RVMediaSources

/// メニューのボタン選択と入力の状態機械。実盤 PICHI のボタン配置（左右 2 列 + 上の 2 つ）を模した合成のハイライトで検査する。
final class DVDMenuTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
    }

    private func button(_ n: Int, x: Int, y: Int, up: Int, down: Int, left: Int, right: Int, cmd: String) -> DVDButton {
        DVDButton(number: n, colorGroup: 0, xStart: x, xEnd: x + 57, yStart: y, yEnd: y + 47, autoAction: false,
                  up: up, down: down, left: left, right: right, command: hex(cmd))
    }

    /// 1 = 左上の「つづけてみる」、2 = 左の列の 1 つ目、3 = 左の列の 2 つ目、4 = 右上の「TVCM 集」、5 = 右の列。
    private func highlight(forcedSelect: Int = 0) -> DVDHighlight {
        let buttons = [
            button(1, x: 75, y: 47, up: 0, down: 2, left: 1, right: 4, cmd: "3005000100010000"),
            button(2, x: 69, y: 288, up: 1, down: 3, left: 2, right: 5, cmd: "3005000100020000"),
            button(3, x: 83, y: 341, up: 2, down: 0, left: 3, right: 5, cmd: "3005000200020000"),
            button(4, x: 498, y: 50, up: 0, down: 5, left: 1, right: 4, cmd: "3003000000040000"),
            button(5, x: 494, y: 287, up: 4, down: 5, left: 2, right: 5, cmd: "3005000100030000"),
        ]
        return DVDHighlight(status: 1, startPTM: 0, endPTM: 0xFFFF_FFFF, buttonCount: 5, forcedSelectButton: forcedSelect,
                            forcedActionButton: 0, colorTables: [], buttons: buttons)
    }

    func testInitialSelectionIsTheForcedButtonOtherwiseTheFirstOne() {
        XCTAssertEqual(DVDMenuState(highlight: highlight()).selectedButton, 1)
        XCTAssertEqual(DVDMenuState(highlight: highlight(forcedSelect: 3)).selectedButton, 3)
        XCTAssertEqual(DVDMenuState(highlight: highlight(forcedSelect: 9)).selectedButton, 1, "存在しないボタンの強制選択は無視して 1 番へ")
    }

    func testArrowKeysFollowTheNeighborTableAndStayWhenThereIsNone() {
        var s = DVDMenuState(highlight: highlight())
        XCTAssertFalse(s.move(.up), "1 番の上は無い")
        XCTAssertTrue(s.move(.down)); XCTAssertEqual(s.selectedButton, 2)
        XCTAssertTrue(s.move(.down)); XCTAssertEqual(s.selectedButton, 3)
        XCTAssertFalse(s.move(.down), "3 番の下は無い（0）")
        XCTAssertEqual(s.selectedButton, 3)
        XCTAssertTrue(s.move(.right)); XCTAssertEqual(s.selectedButton, 5, "左の列から右の列へ")
        XCTAssertTrue(s.move(.up)); XCTAssertEqual(s.selectedButton, 4)
        XCTAssertFalse(s.move(.right), "自分自身を指す隣は動かない")
        XCTAssertTrue(s.move(.left)); XCTAssertEqual(s.selectedButton, 1)
    }

    func testPointerSelectsTheButtonUnderIt() {
        var s = DVDMenuState(highlight: highlight())
        XCTAssertEqual(s.button(atX: 100, y: 300)?.number, 2)
        XCTAssertTrue(s.select(atX: 100, y: 300)); XCTAssertEqual(s.selectedButton, 2)
        XCTAssertFalse(s.select(atX: 100, y: 300), "すでに選択中なら変化なし")
        XCTAssertFalse(s.select(atX: 300, y: 200), "ボタンの外では選択を変えない")
        XCTAssertEqual(s.selectedButton, 2)
        XCTAssertNil(s.button(atX: 0, y: 0))
        XCTAssertEqual(s.button(atX: 69, y: 288)?.number, 2, "矩形の角も含む")
        XCTAssertEqual(s.button(atX: 126, y: 335)?.number, 2)
        XCTAssertNil(s.button(atX: 127, y: 335))
    }

    func testActivatingTheSelectedButtonReturnsTheActionOfItsCommand() {
        var s = DVDMenuState(highlight: highlight())
        XCTAssertEqual(s.activate(), .playChapter(title: 1, chapter: 1), "「つづけてみる」")
        XCTAssertTrue(s.isActivated, "決定の最中は実行の色にする")
        s.clearActivation(); XCTAssertFalse(s.isActivated)
        s.move(.down); s.move(.down)
        XCTAssertEqual(s.activate(), .playChapter(title: 2, chapter: 2))
        s.select(atX: 510, y: 60)
        XCTAssertEqual(s.selectedButton, 4)
        XCTAssertEqual(s.activate(), .playTitle(4), "「TVCM 集」")
        XCTAssertTrue({ s.move(.down) }(), "矢印で動くと実行の色は解ける")
        XCTAssertFalse(s.isActivated)
    }

    func testCommandsMapToActions() {
        XCTAssertEqual(DVDMenuState.action(for: .jumpVTSChapter(ttn: 3, ptt: 4)), .playChapter(title: 3, chapter: 4))
        XCTAssertEqual(DVDMenuState.action(for: .jumpVTSTitle(ttn: 2)), .playTitle(2))
        XCTAssertEqual(DVDMenuState.action(for: .jumpTitle(ttn: 5)), .playTitle(5))
        XCTAssertEqual(DVDMenuState.action(for: .jumpSystemSpace(.vmgmMenu(2))), .showMenu)
        XCTAssertEqual(DVDMenuState.action(for: .callSystemSpace(.firstPlay, resumeCell: 1)), .showMenu)
        XCTAssertEqual(DVDMenuState.action(for: .exit), .exit)
        XCTAssertEqual(DVDMenuState.action(for: .nop), .none)
        XCTAssertEqual(DVDMenuState.action(for: .break), .none)
        let raw: [UInt8] = hex("3015000100020000")
        XCTAssertEqual(DVDMenuState.action(for: DVDCommand.parse(raw)), .unsupported(raw), "条件つきは実行しない")
        if case .unsupported = DVDMenuState.action(for: .linkPGC(3)) {} else { XCTFail("PGC 内の Link は未対応として返すはず") }
    }

    func testEmptyHighlightHasNoSelectionAndDoesNothing() {
        var s = DVDMenuState(highlight: DVDHighlight(status: 0, startPTM: 0, endPTM: 0, buttonCount: 0, forcedSelectButton: 0,
                                                     forcedActionButton: 0, colorTables: [], buttons: []))
        XCTAssertNil(s.selectedButton)
        XCTAssertFalse(s.move(.down))
        XCTAssertFalse(s.select(atX: 10, y: 10))
        XCTAssertEqual(s.activate(), .none)
    }
}
