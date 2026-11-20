import Foundation
import XCTest
@testable import RVMediaSources

/// NAV pack の PCI（979 byte）から、メニューのボタン情報を読む。合成した PCI を、仕様のビット配置どおり
/// 試験側で組み立てて検査する。実盤 PICHI の VTS_01_0.VOB（12 ボタン。位置を画面のボタンと照合済み）は手元で確認済み。
final class DVDNavigationTests: XCTestCase {
    struct B {
        var coln = 1, x0 = 0, x1 = 0, y0 = 0, y1 = 0, auto = 0
        var up = 0, down = 0, left = 0, right = 0
        var command: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
    }

    private func put32(_ v: UInt32, into a: inout [UInt8], at o: Int) {
        a[o] = UInt8(v >> 24); a[o + 1] = UInt8((v >> 16) & 0xFF); a[o + 2] = UInt8((v >> 8) & 0xFF); a[o + 3] = UInt8(v & 0xFF)
    }

    /// PCI 979 byte を組み立てる（pci_gi 60 + nsml_agli 36 + hli_gi 22 + btn_colit 24 + btnit 36×18 + 記録情報 189）。
    private func makePCI(buttons: [B], hliStatus: Int = 1, startPTM: UInt32 = 45_045, endPTM: UInt32 = 0xFFFF_FFFF,
                         buttonOffset: Int = 0, forcedSelect: Int = 0, forcedAction: Int = 0,
                         colors: [(UInt32, UInt32)] = [(0x0107_0BB0, 0x1017_0BB0), (0, 0), (0, 0)],
                         lbn: UInt32 = 0, vobuStart: UInt32 = 45_045, vobuEnd: UInt32 = 90_090, uop: UInt32 = 0x18C_03E0) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 979)
        put32(lbn, into: &p, at: 0)
        put32(uop, into: &p, at: 8); put32(vobuStart, into: &p, at: 12); put32(vobuEnd, into: &p, at: 16)
        let h = 60 + 36
        p[h] = UInt8(hliStatus >> 8); p[h + 1] = UInt8(hliStatus & 0xFF)
        put32(startPTM, into: &p, at: h + 2); put32(endPTM, into: &p, at: h + 6)
        p[h + 16] = UInt8(buttonOffset); p[h + 17] = UInt8(buttons.count)
        p[h + 20] = UInt8(forcedSelect); p[h + 21] = UInt8(forcedAction)
        for (g, c) in colors.enumerated() { put32(c.0, into: &p, at: h + 22 + g * 8); put32(c.1, into: &p, at: h + 26 + g * 8) }
        for (k, b) in buttons.enumerated() {
            let o = h + 46 + k * 18
            let w1 = (b.coln << 22) | (b.x0 << 12) | b.x1
            let w2 = (b.auto << 22) | (b.y0 << 12) | b.y1
            p[o] = UInt8(w1 >> 16); p[o + 1] = UInt8((w1 >> 8) & 0xFF); p[o + 2] = UInt8(w1 & 0xFF)
            p[o + 3] = UInt8(w2 >> 16); p[o + 4] = UInt8((w2 >> 8) & 0xFF); p[o + 5] = UInt8(w2 & 0xFF)
            p[o + 6] = UInt8(b.up); p[o + 7] = UInt8(b.down); p[o + 8] = UInt8(b.left); p[o + 9] = UInt8(b.right)
            for (i, c) in b.command.enumerated() { p[o + 10 + i] = c }
        }
        return p
    }

    /// NAV pack の sector: pack header（stuffing 0）→ system header（0xBB、長さ 18）→ 0xBF（PCI）→ 0xBF（DSI）。
    private func navSector(pci: [UInt8]) -> Data {
        var s = [UInt8](repeating: 0, count: 2048)
        s.replaceSubrange(0..<14, with: [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])
        var i = 14
        s.replaceSubrange(i..<(i + 6), with: [0, 0, 1, 0xBB, 0, 18]); i += 24
        s.replaceSubrange(i..<(i + 7), with: [0, 0, 1, 0xBF, 0x03, 0xD4, 0x00])     // 長さ 980 = substream 1 + PCI 979
        s.replaceSubrange((i + 7)..<(i + 7 + 979), with: pci); i += 6 + 980
        s.replaceSubrange(i..<(i + 7), with: [0, 0, 1, 0xBF, 0x03, 0xFA, 0x01])     // DSI（読まない）
        return Data(s)
    }

    func testParsesButtonsGeometryNeighborsColorsAndCommands() throws {
        let buttons = [
            B(coln: 1, x0: 69, x1: 126, y0: 288, y1: 335, up: 3, down: 2, left: 1, right: 2,
              command: [0x30, 0x05, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00]),
            B(coln: 2, x0: 494, x1: 719, y0: 0, y1: 479, auto: 1, up: 1, down: 3, left: 1, right: 2,
              command: [0x30, 0x03, 0, 0, 0, 0x04, 0, 0]),
            B(coln: 3, x0: 75, x1: 217, y0: 47, y1: 111, up: 2, down: 1, left: 3, right: 3),
        ]
        let pci = try XCTUnwrap(DVDNavigation.parseNavPackSector(navSector(pci: makePCI(
            buttons: buttons, forcedSelect: 3, forcedAction: 0, lbn: 0, vobuStart: 45_045, vobuEnd: 90_090))))
        XCTAssertEqual(pci.vobuStartPTM, 45_045)
        XCTAssertEqual(pci.vobuEndPTM, 90_090)
        XCTAssertEqual(pci.userOperationControl, 0x18C_03E0)
        let h = pci.highlight
        XCTAssertEqual(h.status, 1)
        XCTAssertEqual(h.startPTM, 45_045)
        XCTAssertEqual(h.endPTM, 0xFFFF_FFFF, "終了が 0xFFFFFFFF = 無期限")
        XCTAssertEqual(h.buttonCount, 3)
        XCTAssertEqual(h.forcedSelectButton, 3)
        XCTAssertEqual(h.buttons.count, 3)

        let b1 = try XCTUnwrap(h.button(numbered: 1))
        XCTAssertEqual([b1.xStart, b1.xEnd, b1.yStart, b1.yEnd], [69, 126, 288, 335])
        XCTAssertEqual(b1.width, 58); XCTAssertEqual(b1.height, 48)
        XCTAssertEqual([b1.up, b1.down, b1.left, b1.right], [3, 2, 1, 2])
        XCTAssertEqual(b1.command, [0x30, 0x05, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00])
        XCTAssertEqual(b1.colorGroup, 0, "btn_coln 1 は 0 番グループ")
        XCTAssertFalse(b1.autoAction)
        XCTAssertTrue(b1.contains(x: 69, y: 288)); XCTAssertTrue(b1.contains(x: 126, y: 335))
        XCTAssertFalse(b1.contains(x: 127, y: 300)); XCTAssertFalse(b1.contains(x: 100, y: 336))

        let b2 = try XCTUnwrap(h.button(numbered: 2))
        XCTAssertEqual([b2.xStart, b2.xEnd, b2.yStart, b2.yEnd], [494, 719, 0, 479], "10 bit の上限に近い座標")
        XCTAssertTrue(b2.autoAction)
        XCTAssertEqual(b2.colorGroup, 1)
        XCTAssertEqual(try XCTUnwrap(h.button(numbered: 3)).colorGroup, 2)

        // 色: 選択の色グループ 0 = 0x01070BB0 → 画素値 0,1,2,3 のパレット添字 [7,0,1,0]、コントラスト [0,11,11,0]。
        XCTAssertEqual(h.colorTables[0].paletteIndices(action: false), [7, 0, 1, 0])
        XCTAssertEqual(h.colorTables[0].contrasts(action: false), [0, 11, 11, 0])
        XCTAssertEqual(h.colorTables[0].paletteIndices(action: true), [7, 1, 0, 1], "実行の色は 0x10170BB0（上位 16 bit 0x1017 を下位の nibble から並べる）")
    }

    func testButtonNumbersFollowTheButtonOffset() throws {
        // btn_ofn（ボタン群の開始番号）が 6 なら、btnit の先頭は 7 番ボタン。
        let pci = try XCTUnwrap(DVDNavigation.parseNavPackSector(navSector(pci: makePCI(
            buttons: [B(x0: 0, x1: 9, y0: 0, y1: 9), B(x0: 10, x1: 19, y0: 0, y1: 9)], buttonOffset: 6))))
        XCTAssertEqual(pci.highlight.buttons.map(\.number), [7, 8])
    }

    func testNoHighlightInformationMeansNoButtons() throws {
        let pci = try XCTUnwrap(DVDNavigation.parseNavPackSector(navSector(pci: makePCI(
            buttons: [B(x0: 0, x1: 9, y0: 0, y1: 9)], hliStatus: 0))))
        XCTAssertEqual(pci.highlight.status, 0)
        XCTAssertTrue(pci.highlight.buttons.isEmpty, "hli_ss が 0 のときは btnit を読まない")
    }

    func testDegenerateButtonRectanglesAreSkipped() throws {
        let pci = try XCTUnwrap(DVDNavigation.parseNavPackSector(navSector(pci: makePCI(
            buttons: [B(x0: 50, x1: 10, y0: 0, y1: 9),      // x が逆
                      B(x0: 0, x1: 9, y0: 30, y1: 20),      // y が逆
                      B(x0: 0, x1: 9, y0: 0, y1: 9)]))))
        XCTAssertEqual(pci.highlight.buttons.map(\.number), [3], "矩形が壊れたボタンは捨て、番号は btnit の位置のまま")
    }

    func testNonNavSectorsReturnNil() {
        XCTAssertNil(DVDNavigation.parseNavPackSector(Data(count: 2048)), "全部 0")
        XCTAssertNil(DVDNavigation.parseNavPackSector(Data(count: 100)), "短い")
        var video = [UInt8](repeating: 0, count: 2048)
        video.replaceSubrange(0..<14, with: [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])
        video.replaceSubrange(14..<20, with: [0, 0, 1, 0xE0, 0x07, 0xE4])     // 映像の PES
        XCTAssertNil(DVDNavigation.parseNavPackSector(Data(video)))
    }

    func testScanFindsEveryNavPackWithItsSectorNumber() throws {
        var vob = Data()
        let pcis = [makePCI(buttons: [B(x0: 0, x1: 9, y0: 0, y1: 9)], vobuStart: 0, vobuEnd: 45_000),
                    makePCI(buttons: [B(x0: 0, x1: 9, y0: 0, y1: 9)], vobuStart: 45_000, vobuEnd: 90_000)]
        vob.append(navSector(pci: pcis[0]))
        vob.append(Data(count: 2048 * 3))                         // 映像の代わりの 3 sector
        vob.append(navSector(pci: pcis[1]))
        let found = DVDNavigation.scanNavPacks(in: vob)
        XCTAssertEqual(found.map(\.sector), [0, 4])
        XCTAssertEqual(found.map(\.pci.vobuStartPTM), [0, 45_000], "VOBU ごとの開始時刻（シーク・セルと時間の対応の原料）")
    }
}
