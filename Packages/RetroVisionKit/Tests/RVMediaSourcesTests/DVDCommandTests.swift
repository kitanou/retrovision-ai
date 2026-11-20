import XCTest
@testable import RVMediaSources

/// ボタンの VM コマンド（8 byte）の解釈。実盤 PICHI のコマンドと、仕様のビット配置どおりの合成データで検査する。
final class DVDCommandTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
    }

    func testRealDiscButtonCommandsJumpToTheTitlesAndChaptersTheMenuShows() {
        // 実盤 PICHI の 12 ボタン: 左の列 = タイトル 2（第 1 話）の各チャプター、右の列 = タイトル 3（第 2 話）。
        XCTAssertEqual(DVDCommand.parse(hex("3005000100020000")), .jumpVTSChapter(ttn: 2, ptt: 1))
        XCTAssertEqual(DVDCommand.parse(hex("3005000500020000")), .jumpVTSChapter(ttn: 2, ptt: 5))
        XCTAssertEqual(DVDCommand.parse(hex("3005000200030000")), .jumpVTSChapter(ttn: 3, ptt: 2))
        XCTAssertEqual(DVDCommand.parse(hex("3005000100010000")), .jumpVTSChapter(ttn: 1, ptt: 1), "「つづけてみる」= 通しの先頭")
        XCTAssertEqual(DVDCommand.parse(hex("3003000000040000")), .jumpVTSTitle(ttn: 4), "「TVCM 集」= タイトル 4")
    }

    func testJumpAndCallToTitlesAndMenus() {
        XCTAssertEqual(DVDCommand.parse(hex("3001000000000000")), .exit)
        XCTAssertEqual(DVDCommand.parse(hex("3002000000030000")), .jumpTitle(ttn: 3))
        XCTAssertEqual(DVDCommand.parse(hex("3006000000000000")), .jumpSystemSpace(.firstPlay))
        XCTAssertEqual(DVDCommand.parse(hex("3006000000420000")), .jumpSystemSpace(.vmgmMenu(2)))
        XCTAssertEqual(DVDCommand.parse(hex("3006000301830000")), .jumpSystemSpace(.vtsMenu(vts: 1, ttn: 3, menu: 3)))
        XCTAssertEqual(DVDCommand.parse(hex("3006012C00C00000")), .jumpSystemSpace(.vmgmPGC(300)))
        XCTAssertEqual(DVDCommand.parse(hex("3008000007410000")), .callSystemSpace(.vmgmMenu(1), resumeCell: 7))
    }

    func testLinksAndSimpleControlFlow() {
        XCTAssertEqual(DVDCommand.parse(hex("0000000000000000")), .nop)
        XCTAssertEqual(DVDCommand.parse(hex("0001000000000005")), .goto(line: 5))
        XCTAssertEqual(DVDCommand.parse(hex("0002000000000000")), .break)
        XCTAssertEqual(DVDCommand.parse(hex("2004000000000003")), .linkPGC(3))
        // ptt 258（0x102）+ ボタン 5: byte6 = (5 << 2) | (ptt >> 8) = 0x15、byte7 = 0x02。
        XCTAssertEqual(DVDCommand.parse(hex("2005000000001502")), .linkChapter(ptt: 258, button: 5))
        XCTAssertEqual(DVDCommand.parse(hex("2006000000000007")), .linkProgram(7, button: 0))
        XCTAssertEqual(DVDCommand.parse(hex("2007000000000009")), .linkCell(9, button: 0))
        XCTAssertEqual(DVDCommand.parse(hex("2001000000000002")), .linkSubset(2, button: 0), "NextC")
    }

    func testSetGPRMWithAnImmediateValue() {
        // 仕様の例: SetGPRM g3 = 2 → 71 00 00 03 00 02 00 00。
        XCTAssertEqual(DVDCommand.parse(hex("7100000300020000")), .setGPRM(register: 3, value: 2))
        XCTAssertEqual(DVDCommand.parse(hex("7100000101FF0000")), .setGPRM(register: 1, value: 0x01FF))
    }

    func testConditionalAndUnsupportedFormsAreNotExecutable() {
        // 比較演算つき（byte1 の bits 6-4 != 0）は、レジスタを評価できないので実行できる形にしない。
        let conditional = hex("3015000100020000")
        XCTAssertTrue(DVDCommand.isConditional(conditional))
        XCTAssertEqual(DVDCommand.parse(conditional), .unsupported(conditional))
        // 種別 4〜6（比較 + Set + Link の複合）も解釈しない。
        for first in ["80", "A0", "C0"] {
            let b = hex(first + "05000100020000")
            XCTAssertEqual(DVDCommand.parse(b), .unsupported(b))
        }
        // 実盤メニューの PGC の先頭コマンド（比較つきの Goto。レジスタの値が要る）は解釈せず、そのまま保持する。
        let register = hex("00a100000000001d")
        XCTAssertEqual(DVDCommand.parse(register), .unsupported(register))
        XCTAssertTrue(DVDCommand.isConditional(register))
        // 長さが 8 byte でない。
        XCTAssertEqual(DVDCommand.parse([0x30, 0x05]), .unsupported([0x30, 0x05]))
        // 副命令が未知の Jump。
        let unknownJump = hex("3009000000000000")
        XCTAssertEqual(DVDCommand.parse(unknownJump), .unsupported(unknownJump))
        // Set の演算子が代入でない（加算など）はレジスタが要るので実行しない。
        let add = hex("7200000300020000")
        XCTAssertEqual(DVDCommand.parse(add), .unsupported(add))
    }

    func testUnconditionalButtonCommandsAreNotFlaggedConditional() {
        XCTAssertFalse(DVDCommand.isConditional(hex("3005000100020000")))
        XCTAssertFalse(DVDCommand.isConditional(hex("7100000300020000")))
    }
}
