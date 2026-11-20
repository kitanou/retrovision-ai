import Foundation
import XCTest
@testable import RVMediaSources

/// VTS の IFO（タイトル・チャプター・セル・メニューのパレット）の解析。合成した IFO を、仕様の配置どおりに
/// 試験側で組み立てて検査する。実盤 PICHI（タイトル 4、チャプター 10 / 5 / 5 / 5、メニュー 1）は手元で一致を確認済み。
final class DVDIFOTests: XCTestCase {
    struct CellSpec { var first: UInt32, last: UInt32, time: [UInt8] }   // time = BCD 4 byte（時 分 秒 フレーム|rate）

    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// PGC 1 個: 先頭 0xEC byte のヘッダ + コマンド表 + プログラムマップ + セル再生情報。
    private func makePGC(programs: [Int], cells: [CellSpec], duration: [UInt8], palette: [UInt32] = [],
                         preCommands: [[UInt8]] = []) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 0xEC)
        h[2] = UInt8(programs.count); h[3] = UInt8(cells.count)
        h.replaceSubrange(4..<8, with: duration)
        for (i, p) in palette.prefix(16).enumerated() { h.replaceSubrange((0xA4 + i * 4)..<(0xA8 + i * 4), with: be32(Int(p))) }
        var cmd: [UInt8] = be16(preCommands.count) + be16(0) + be16(0) + be16(7 + preCommands.count * 8)
        for c in preCommands { cmd += c }
        var prog = programs.map { UInt8($0) }
        if prog.count % 2 == 1 { prog.append(0) }
        var cellPB: [UInt8] = []
        for c in cells {
            cellPB += be32(0x0200_0000) + c.time + be32(Int(c.first)) + be32(Int(c.first)) + be32(Int(c.last)) + be32(Int(c.last))
        }
        let cmdOffset = 0xEC, progOffset = cmdOffset + cmd.count, cellOffset = progOffset + prog.count
        h.replaceSubrange(0xE4..<0xE6, with: be16(cmdOffset))
        h.replaceSubrange(0xE6..<0xE8, with: be16(progOffset))
        h.replaceSubrange(0xE8..<0xEA, with: be16(cellOffset))
        h.replaceSubrange(0xEA..<0xEC, with: be16(cellOffset + cellPB.count))
        return h + cmd + prog + cellPB
    }

    /// pgcs は (entry_id, PGC バイト列)。PGCIT 1 個（lang unit の中身にも使う）。
    private func makePGCIT(_ pgcs: [(entry: UInt8, bytes: [UInt8])]) -> [UInt8] {
        var table = be16(pgcs.count) + be16(0) + be32(0)
        var body: [UInt8] = []
        let first = 8 + pgcs.count * 8
        for p in pgcs {
            table += [p.entry, 0] + be16(0) + be32(first + body.count)
            body += p.bytes
        }
        var out = table + body
        out.replaceSubrange(4..<8, with: be32(out.count - 1))
        return out
    }

    private func makePTT(_ titles: [[(pgc: Int, pgn: Int)]]) -> [UInt8] {
        let first = 8 + titles.count * 4
        var table = be16(titles.count) + be16(0) + be32(0)
        var body: [UInt8] = []
        for t in titles {
            table += be32(first + body.count)
            for e in t { body += be16(e.pgc) + be16(e.pgn) }
        }
        var out = table + body
        out.replaceSubrange(4..<8, with: be32(out.count - 1))
        return out
    }

    /// タイトル 2 つ（ttn1 = 通し: セル 3 つ、ttn2 = 後半のセル 1 つだけを共有）+ タイトルメニュー 1 つの IFO。
    private func makeIFO(menuPalette: [UInt32] = [0x00D8_8D2F, 0x008D_C381]) -> Data {
        let t30 = 0xC0 | 0x00       // frame rate bit: 0xC0 = 29.97（11）。frame は 0
        let c1 = CellSpec(first: 0, last: 999, time: [0x00, 0x01, 0x00, UInt8(t30)])          // 60 s
        let c2 = CellSpec(first: 1000, last: 2999, time: [0x00, 0x02, 0x00, UInt8(t30)])      // 120 s
        let c3 = CellSpec(first: 3000, last: 3499, time: [0x00, 0x00, 0x30, UInt8(t30)])      // 30 s
        let pgc1 = makePGC(programs: [1, 2, 3], cells: [c1, c2, c3], duration: [0x00, 0x03, 0x30, UInt8(t30)])
        let pgc2 = makePGC(programs: [1], cells: [c3], duration: [0x00, 0x00, 0x30, UInt8(t30)])
        let menu = makePGC(programs: [1], cells: [CellSpec(first: 0, last: 114, time: [0x00, 0x00, 0x00, 0xC0 | 0x15])],
                           duration: [0x00, 0x00, 0x00, 0xC0 | 0x15], palette: menuPalette,
                           preCommands: [[0x30, 0x05, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00]])

        let pgcit = makePGCIT([(0x81, pgc1), (0x82, pgc2)])
        let ptt = makePTT([[(1, 1), (1, 2), (1, 3)], [(2, 1)]])
        let lu = makePGCIT([(0x83, menu)])
        let ut = be16(1) + be16(0) + be32(0) + [0x6A, 0x61, 0, 0x80] + be32(16)   // 言語単位 ja。lang_start_byte = 16
        let utFull = ut + [UInt8](repeating: 0, count: 16 - ut.count) + lu

        var d = [UInt8](repeating: 0, count: 8 * 2048)
        d.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        d.replaceSubrange(0xC8..<0xCC, with: be32(1))      // VTS_PTT_SRPT: sector 1
        d.replaceSubrange(0xCC..<0xD0, with: be32(2))      // VTS_PGCIT: sector 2
        d.replaceSubrange(0xD0..<0xD4, with: be32(3))      // VTSM_PGCI_UT: sector 3
        d.replaceSubrange((1 * 2048)..<(1 * 2048 + ptt.count), with: ptt)
        d.replaceSubrange((2 * 2048)..<(2 * 2048 + pgcit.count), with: pgcit)
        d.replaceSubrange((3 * 2048)..<(3 * 2048 + utFull.count), with: utFull)
        return Data(d)
    }

    func testTitlesChaptersAndDurations() throws {
        let info = try XCTUnwrap(DVDIFO.parseTitleSet(makeIFO()))
        XCTAssertEqual(info.titles.map(\.number), [1, 2])
        XCTAssertEqual(info.titles[0].chapters.count, 3)
        XCTAssertEqual(info.titles[1].chapters.count, 1)
        XCTAssertEqual(info.titles[0].duration, 210, accuracy: 0.001, "3 分 30 秒")
        XCTAssertEqual(info.titles[0].chapters.map(\.cell.firstSector), [0, 1000, 3000])
        XCTAssertEqual(info.titles[0].chapters.map(\.programNumber), [1, 2, 3])
        XCTAssertEqual(info.titles[0].chapters[1].cell.lastSector, 2999)
        XCTAssertEqual(info.titles[0].chapters[1].cell.duration, 120, accuracy: 0.001)
    }

    func testChapterStartTimesAccumulateCellDurationsInSectorOrderAndSharedCellsCountOnce() throws {
        let info = try XCTUnwrap(DVDIFO.parseTitleSet(makeIFO()))
        XCTAssertEqual(try XCTUnwrap(info.startTime(title: 1, chapter: 1)), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.startTime(title: 1, chapter: 2)), 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.startTime(title: 1, chapter: 3)), 180, accuracy: 0.001)
        // ttn2 は ttn1 の第 3 セルと同じ範囲。同じセルは 1 度だけ数えるので、開始は 180 s のまま（210 ではない）。
        XCTAssertEqual(try XCTUnwrap(info.startTime(title: 2)), 180, accuracy: 0.001)
        XCTAssertEqual(info.timeline.totalDuration, 210, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(info.timeline.time(ofSector: 1500)), 60 + 60 * 500.0 / 2000.0 * 2, accuracy: 0.01,
                       "セルの途中は sector の比で補間する")
        XCTAssertNil(info.timeline.time(ofSector: 99_999), "どのセルにも属さない sector")
    }

    func testOutOfRangeTitleAndChapterReturnNil() throws {
        let info = try XCTUnwrap(DVDIFO.parseTitleSet(makeIFO()))
        XCTAssertNil(info.startTime(title: 3, chapter: 1))
        XCTAssertNil(info.startTime(title: 1, chapter: 4))
        XCTAssertNil(info.startTime(title: 1, chapter: 0))
        XCTAssertNil(info.title(0))
    }

    func testMenuPGCPaletteCellsAndCommands() throws {
        let info = try XCTUnwrap(DVDIFO.parseTitleSet(makeIFO()))
        let menu = try XCTUnwrap(info.menus.first)
        XCTAssertEqual(menu.entryID, 0x83)
        XCTAssertEqual(menu.menuType, 3)
        XCTAssertTrue(menu.isEntry)
        XCTAssertEqual(menu.languageCode, "ja")
        XCTAssertEqual(menu.pgc.palette.count, 16)
        XCTAssertEqual(menu.pgc.palette[0], 0x00D8_8D2F)
        XCTAssertEqual(menu.pgc.cells.count, 1)
        XCTAssertEqual(menu.pgc.cells[0].lastSector, 114)
        XCTAssertEqual(menu.pgc.duration, 15.0 / (30000.0 / 1001.0), accuracy: 0.001, "15 frame（29.97 fps）")
        XCTAssertEqual(menu.pgc.preCommands, [[0x30, 0x05, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00]])
    }

    func testPaletteConvertsYCrCbToRGB() {
        // 実盤 PICHI のメニュー: 0x00D88D2F = 黄色、0x008DC381 = ピンク。
        let yellow = DVDPalette.rgb(0x00D8_8D2F), pink = DVDPalette.rgb(0x008D_C381)
        XCTAssertGreaterThan(Int(yellow.r), 240); XCTAssertGreaterThan(Int(yellow.g), 240); XCTAssertLessThan(Int(yellow.b), 100)
        XCTAssertGreaterThan(Int(pink.r), 230); XCTAssertLessThan(Int(pink.g), 120); XCTAssertGreaterThan(Int(pink.b), 120)
        let black = DVDPalette.rgb(0x0010_8080)
        XCTAssertEqual([black.r, black.g, black.b], [0, 0, 0], "Y=16, Cr=Cb=128 は黒")
        let white = DVDPalette.rgb(0x00EB_8080)
        XCTAssertGreaterThan(Int(white.r), 250)
    }

    func testBCDTimeUsesTheFrameRateBits() {
        XCTAssertEqual(DVDIFO.bcdTime([0x01, 0x02, 0x03, 0xC0 | 0x15]), 3600 + 120 + 3 + 15 / (30000.0 / 1001.0), accuracy: 1e-6)
        XCTAssertEqual(DVDIFO.bcdTime([0x00, 0x00, 0x10, 0x40 | 0x12]), 10 + 12 / 25.0, accuracy: 1e-6, "01 = 25 fps")
        XCTAssertEqual(DVDIFO.bcdTime([0x00, 0x01, 0x00, 0x00]), 60, accuracy: 1e-6, "rate 不明の frame は数えない")
    }

    func testNotAnIFOOrTruncatedInputsReturnNilOrEmptyWithoutCrashing() {
        XCTAssertNil(DVDIFO.parseTitleSet(Data()))
        XCTAssertNil(DVDIFO.parseTitleSet(Data(count: 4096)), "署名が無い")
        var vmg = [UInt8](repeating: 0, count: 4096); vmg.replaceSubrange(0..<12, with: Array("DVDVIDEO-VMG".utf8))
        XCTAssertNil(DVDIFO.parseTitleSet(Data(vmg)), "VMG（VIDEO_TS.IFO）はこの関数の対象ではない")
        // 表の位置が範囲外を指す壊れた IFO は、空の結果で返る（落ちない）。
        var broken = [UInt8](repeating: 0, count: 0x200); broken.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        broken.replaceSubrange(0xC8..<0xCC, with: be32(9_999)); broken.replaceSubrange(0xCC..<0xD0, with: be32(9_999))
        broken.replaceSubrange(0xD0..<0xD4, with: be32(9_999))
        let info = DVDIFO.parseTitleSet(Data(broken))
        XCTAssertEqual(info?.titles.count, 0)
        XCTAssertEqual(info?.menus.count, 0)
    }
}
