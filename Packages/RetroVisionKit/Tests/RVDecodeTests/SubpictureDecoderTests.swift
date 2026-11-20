import XCTest
@testable import RVDecode

/// DVD の字幕（SPU）のデコード。合成した SPU（RLE の符号化も試験側で書く）で、符号の長さ別（1〜4 nibble）・
/// 行末まで（長さ 0）・field 交互・制御列を検査する。実盤 PICHI のメニュー（12 個のハート形カーソル）は
/// 手元で復号して目で確認済み（コミットしない）。
final class SubpictureDecoderTests: XCTestCase {
    // MARK: 試験用の符号化器（復号器とは独立に、仕様の定義どおりに書く）

    /// 1 つの run の nibble 列。長さ 1〜3 → 1 nibble、4〜15 → 2、16〜63 → 3、64〜 → 4。
    private func runNibbles(length: Int, color: Int) -> [UInt8] {
        let v = (length << 2) | color
        func n(_ x: Int) -> UInt8 { UInt8(x & 0xF) }
        switch length {
        case 1...3: return [n(v)]
        case 4...15: return [n(v >> 4), n(v)]
        case 16...63: return [0, n(v >> 4), n(v)]
        default:
            let x = v >> 4
            return [0, n(x >> 4), n(x), n(v)]
        }
    }

    /// 行 1 本を run 列へ。行末まで同じ色で終わる run は、長さ 0 の符号（0 0 0 c）にできる。
    private func lineBytes(_ row: [UInt8], useEndOfLineCode: Bool) -> [UInt8] {
        var nibbles: [UInt8] = []
        var i = 0
        while i < row.count {
            var j = i
            while j < row.count, row[j] == row[i] { j += 1 }
            if useEndOfLineCode, j == row.count, j - i > 63 { nibbles += [0, 0, 0, row[i]] }
            else { nibbles += runNibbles(length: j - i, color: Int(row[i])) }
            i = j
        }
        if nibbles.count % 2 == 1 { nibbles.append(0) }   // 行末は byte 境界へ
        return stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] }
    }

    private func makeSPU(pixels: [[UInt8]], x: Int, y: Int, palette: [Int], contrast: [Int],
                         forced: Bool = true, endOfLineCode: Bool = false) -> Data {
        let height = pixels.count, width = pixels[0].count
        var top: [UInt8] = [], bottom: [UInt8] = []
        for (r, row) in pixels.enumerated() {
            if r % 2 == 0 { top += lineBytes(row, useEndOfLineCode: endOfLineCode) }
            else { bottom += lineBytes(row, useEndOfLineCode: endOfLineCode) }
        }
        let topOffset = 4, bottomOffset = 4 + top.count
        let dcsqOffset = 4 + top.count + bottom.count
        var cmds: [UInt8] = [forced ? 0x00 : 0x01]
        cmds += [0x03, UInt8(palette[3] << 4 | palette[2]), UInt8(palette[1] << 4 | palette[0])]
        cmds += [0x04, UInt8(contrast[3] << 4 | contrast[2]), UInt8(contrast[1] << 4 | contrast[0])]
        let x2 = x + width - 1, y2 = y + height - 1
        cmds += [0x05, UInt8(x >> 4), UInt8((x & 0xF) << 4 | x2 >> 8), UInt8(x2 & 0xFF),
                 UInt8(y >> 4), UInt8((y & 0xF) << 4 | y2 >> 8), UInt8(y2 & 0xFF)]
        cmds += [0x06, UInt8(topOffset >> 8), UInt8(topOffset & 0xFF), UInt8(bottomOffset >> 8), UInt8(bottomOffset & 0xFF)]
        cmds += [0xFF]
        var unit: [UInt8] = [0, 0, UInt8(dcsqOffset >> 8), UInt8(dcsqOffset & 0xFF)]
        unit += top + bottom
        unit += [0, 0, UInt8(dcsqOffset >> 8), UInt8(dcsqOffset & 0xFF)] + cmds   // 遅延 0、次は自分自身
        unit[0] = UInt8(unit.count >> 8); unit[1] = UInt8(unit.count & 0xFF)
        return Data(unit)
    }

    private func expect(_ sp: Subpicture?, _ pixels: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        guard let sp else { return XCTFail("復号できない", file: file, line: line) }
        XCTAssertEqual(sp.width, pixels[0].count, file: file, line: line)
        XCTAssertEqual(sp.height, pixels.count, file: file, line: line)
        for (r, row) in pixels.enumerated() {
            XCTAssertEqual(Array(sp.pixels[(r * sp.width)..<((r + 1) * sp.width)]), row, "行 \(r) が違う", file: file, line: line)
        }
    }

    // MARK: 検査

    func testShortAndMediumRunsRoundTripAcrossBothFields() {
        // 長さ 1〜3（1 nibble）、4〜15（2）、16〜63（3）の run を含む 12 行。field（偶数行 / 奇数行）が交互に符号化される。
        var rows: [[UInt8]] = []
        for r in 0..<12 {
            var row: [UInt8] = []
            row += [UInt8](repeating: UInt8(r % 4), count: 2)                       // 長さ 2
            row += [UInt8](repeating: UInt8((r + 1) % 4), count: 7)                 // 長さ 7
            row += [UInt8](repeating: UInt8((r + 2) % 4), count: 33)                // 長さ 33
            row += [UInt8](repeating: UInt8((r + 3) % 4), count: 1)                 // 長さ 1
            rows.append(row)
        }
        let spu = makeSPU(pixels: rows, x: 100, y: 200, palette: [3, 5, 7, 9], contrast: [0, 15, 8, 4])
        let sp = SubpictureDecoder.decode(spu)
        expect(sp, rows)
        XCTAssertEqual(sp?.x, 100); XCTAssertEqual(sp?.y, 200)
        XCTAssertEqual(sp?.paletteIndices, [3, 5, 7, 9], "画素値 0,1,2,3 に対するパレット添字")
        XCTAssertEqual(sp?.contrasts, [0, 15, 8, 4])
        XCTAssertEqual(sp?.forcedDisplay, true)
    }

    func testLongRunsUseTheFourNibbleCodeAndEndOfLineCode() {
        // 幅 300 の行。長さ 100（4 nibble）と、行末まで（長さ 0 の符号）の run。
        var rows: [[UInt8]] = []
        for r in 0..<6 {
            rows.append([UInt8](repeating: 1, count: 100) + [UInt8](repeating: UInt8(2 + r % 2), count: 200))
        }
        let sp = SubpictureDecoder.decode(makeSPU(pixels: rows, x: 0, y: 0, palette: [0, 1, 2, 3],
                                                  contrast: [0, 0, 0, 0], endOfLineCode: true))
        expect(sp, rows)
    }

    func testAllOneColorRowUsesTheEndOfLineCode() {
        let rows = [[UInt8]](repeating: [UInt8](repeating: 0, count: 200), count: 4)
        expect(SubpictureDecoder.decode(makeSPU(pixels: rows, x: 10, y: 20, palette: [0, 0, 0, 0],
                                                contrast: [0, 0, 0, 0], endOfLineCode: true)), rows)
    }

    func testNonForcedDisplayIsReported() {
        let rows: [[UInt8]] = [[0, 1, 2, 3], [3, 2, 1, 0]]
        let sp = SubpictureDecoder.decode(makeSPU(pixels: rows, x: 0, y: 0, palette: [0, 1, 2, 3],
                                                  contrast: [15, 15, 15, 15], forced: false))
        XCTAssertEqual(sp?.forcedDisplay, false)
        expect(sp, rows)
    }

    func testBrokenUnitsAreRejectedWithoutCrashing() {
        XCTAssertNil(SubpictureDecoder.decode(Data()))
        XCTAssertNil(SubpictureDecoder.decode(Data([0, 6, 0, 4, 0, 0])), "制御列が空（表示領域なし）")
        var spu = [UInt8](makeSPU(pixels: [[0, 1], [1, 0]], x: 0, y: 0, palette: [0, 1, 2, 3], contrast: [15, 15, 15, 15]))
        spu[2] = 0xFF; spu[3] = 0xFF          // 制御列のオフセットが範囲外
        XCTAssertNil(SubpictureDecoder.decode(Data(spu)))
        // RLE が途中で切れても落ちない（読めた分までで、残りは背景 0）。
        let rows = [[UInt8]](repeating: [UInt8](repeating: 1, count: 50), count: 8)
        var full = [UInt8](makeSPU(pixels: rows, x: 0, y: 0, palette: [0, 1, 2, 3], contrast: [0, 0, 0, 0]))
        full.removeSubrange(6..<8)             // データの一部を欠かす（サイズは宣言のまま）
        _ = SubpictureDecoder.decode(Data(full))
    }

    func testUnknownCommandStopsTheParseInsteadOfGuessing() {
        var spu = [UInt8](makeSPU(pixels: [[0, 1], [1, 0]], x: 0, y: 0, palette: [0, 1, 2, 3], contrast: [15, 15, 15, 15]))
        // 制御列の先頭コマンド（forced = 0x00）を未知の 0x42 に書き換える。長さが分からないので読み進めない。
        let dcsq = Int(spu[2]) << 8 | Int(spu[3])
        spu[dcsq + 4] = 0x42
        XCTAssertNil(SubpictureDecoder.decode(Data(spu)))
    }

    // MARK: program stream からの取り出し

    /// pack header + 指定の PES 1 個（payload = 先頭の substream id + data）の sector。残りは 0 で埋める（読み飛ばされる）。
    private func sector(id: UInt8, headerData: Int = 0, substream: UInt8, payload: [UInt8]) -> Data {
        var s = [UInt8](repeating: 0, count: 2048)
        s.replaceSubrange(0..<14, with: [0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])
        let length = 3 + headerData + 1 + payload.count
        var pes: [UInt8] = [0, 0, 1, id, UInt8(length >> 8), UInt8(length & 0xFF), 0x81, 0x00, UInt8(headerData)]
        pes += [UInt8](repeating: 0xFF, count: headerData) + [substream] + payload
        s.replaceSubrange(14..<(14 + pes.count), with: pes)
        return Data(s)
    }

    func testFirstUnitJoinsPayloadsAcrossSectorsAndStopsAtTheDeclaredSize() throws {
        let rows: [[UInt8]] = (0..<10).map { r in (0..<30).map { UInt8(($0 + r) % 4) } }
        let spu = [UInt8](makeSPU(pixels: rows, x: 5, y: 7, palette: [0, 1, 2, 3], contrast: [15, 15, 15, 15]))
        let cut = spu.count / 2
        var vob = Data()
        vob.append(sector(id: 0xE0, substream: 0, payload: []).prefix(0))     // 映像の sector は混ぜない（読み飛ばし）
        vob.append(sector(id: 0xE0, headerData: 0, substream: 0xAA, payload: [1, 2, 3]))
        vob.append(sector(id: 0xBD, headerData: 5, substream: 0x20, payload: Array(spu[0..<cut])))
        vob.append(sector(id: 0xBD, substream: 0x20, payload: Array(spu[cut...]) + [0xEE, 0xEE, 0xEE]))   // 次の SPU の頭（切り捨てる）
        let unit = try XCTUnwrap(SubpictureDecoder.firstUnit(fromProgramStream: vob))
        XCTAssertEqual([UInt8](unit), spu, "複数の PES に分かれた SPU を、宣言サイズちょうどでつなげる")
        let decoded = try XCTUnwrap(SubpictureDecoder.decode(unit))
        XCTAssertEqual(decoded.width, 30); XCTAssertEqual(decoded.height, 10)
        XCTAssertEqual(decoded.x, 5); XCTAssertEqual(decoded.y, 7)
    }

    func testFirstUnitCanBeRestrictedToASubstreamAndReturnsNilWhenThereIsNone() {
        let spu = [UInt8](makeSPU(pixels: [[0, 1], [1, 0]], x: 0, y: 0, palette: [0, 1, 2, 3], contrast: [15, 15, 15, 15]))
        var vob = Data()
        vob.append(sector(id: 0xBD, substream: 0x21, payload: spu))
        XCTAssertNotNil(SubpictureDecoder.firstUnit(fromProgramStream: vob))
        XCTAssertNotNil(SubpictureDecoder.firstUnit(fromProgramStream: vob, substream: 0x21))
        XCTAssertNil(SubpictureDecoder.firstUnit(fromProgramStream: vob, substream: 0x20), "指定した substream が無い")
        XCTAssertNil(SubpictureDecoder.firstUnit(fromProgramStream: Data(count: 2048 * 3)), "字幕が無い")
        XCTAssertNil(SubpictureDecoder.firstUnit(fromProgramStream: Data()))
    }
}

