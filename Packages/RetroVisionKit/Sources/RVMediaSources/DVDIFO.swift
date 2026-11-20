import Foundation

// MARK: - VTS の IFO（VTS_nn_0.IFO）: メニューのパレット・タイトル / チャプター / セル（B2 第 2 段）
//
// 2048 byte の sector 単位のオフセットで表が並ぶ（libdvdread の vtsi_mat の定義と、実盤 PICHI で一致を確認）:
//   0xC8 VTS_PTT_SRPT（タイトル → チャプター = (PGC 番号, プログラム番号) の表）
//   0xCC VTS_PGCIT   （タイトルの PGC 群。entry_id の下位 7 bit がタイトル番号）
//   0xD0 VTSM_PGCI_UT（メニューの PGC 群。言語単位の入れ子。entry_id の下位 4 bit がメニュー種別）
// PGC（再生手順）は、プログラム数・セル数・再生時間（BCD）・パレット 16 色（0xA4）・
// コマンド表・プログラムマップ・セルの再生情報（24 byte）・セルの位置を持つ。
// セルの first / last sector は VTS の VOB 群の先頭からの論理 sector で、時間の対応は
// 「セルの再生時間を sector 順に足し込む」ことで得る（`DVDSectorTimeline`）。
//
// 純 Foundation。バイト列から読むだけ（CSS・ディスクの読み出しには依存しない）。

/// セル 1 つ（PGC のセル再生情報 24 byte）。
public struct DVDCell: Sendable, Hashable {
    /// 先頭・最後の論理 sector（両端を含む。VTS の VOB 群の先頭から）。
    public let firstSector: UInt32, lastSector: UInt32
    /// 再生時間（秒）。BCD の時分秒 + フレーム（frame rate の flag つき）から。
    public let duration: Double
    /// セルの種別などの bit（そのまま保持）。
    public let category: UInt32
}

public struct DVDPGC: Sendable, Hashable {
    public let programCount: Int
    /// プログラム n（1 始まり）の入口のセル番号（1 始まり）。
    public let programMap: [Int]
    public let cells: [DVDCell]
    public let duration: Double
    /// パレット 16 色。各 32 bit は 0x00 Y Cr Cb。
    public let palette: [UInt32]
    /// コマンド表（8 byte ずつ。意味は VM の解釈が決める）。
    public let preCommands: [[UInt8]], postCommands: [[UInt8]], cellCommands: [[UInt8]]

    /// プログラム n（= チャプターの単位）の入口セル。
    public func entryCell(ofProgram n: Int) -> DVDCell? {
        guard n >= 1, n <= programMap.count else { return nil }
        let cellNumber = programMap[n - 1]
        guard cellNumber >= 1, cellNumber <= cells.count else { return nil }
        return cells[cellNumber - 1]
    }
}

/// メニュー用の PGC（VTSM_PGCI_UT）。entry_id から種別が分かる（3 = タイトルメニュー、2 = ルート …）。
public struct DVDMenuPGC: Sendable, Hashable {
    public let entryID: UInt8
    public let languageCode: String
    public let pgc: DVDPGC
    /// 下位 4 bit: 2 = タイトルメニュー（VMGM の場合）/ 3 = ルートメニュー（VTSM の場合）/ 4 = 字幕 / 5 = 音声 / 6 = アングル / 7 = チャプター。
    public var menuType: Int { Int(entryID & 0x0F) }
    public var isEntry: Bool { entryID & 0x80 != 0 }
}

public struct DVDChapter: Sendable, Hashable {
    public let programNumber: Int
    public let cell: DVDCell
}

public struct DVDTitle: Sendable, Hashable {
    /// VTS 内のタイトル番号（1 始まり。JumpVTS_TT / JumpVTS_PTT の引数）。
    public let number: Int
    public let pgcNumber: Int
    public let duration: Double
    public let chapters: [DVDChapter]
}

public struct DVDTitleSetInfo: Sendable {
    public let titles: [DVDTitle]
    public let titlePGCs: [DVDPGC]
    public let menus: [DVDMenuPGC]
    public let timeline: DVDSectorTimeline

    /// IFO が無い・読めないときの空の情報（タイトルもメニューも持たない）。
    public static let empty = DVDTitleSetInfo(titles: [], titlePGCs: [], menus: [], timeline: DVDSectorTimeline(cells: []))

    public func title(_ number: Int) -> DVDTitle? { titles.first { $0.number == number } }
    /// タイトル number のチャプター ptt（どちらも 1 始まり）の開始時刻（VTS の VOB 群の先頭からの秒）。
    public func startTime(title number: Int, chapter ptt: Int) -> Double? {
        guard let t = title(number), ptt >= 1, ptt <= t.chapters.count else { return nil }
        return timeline.time(ofSector: t.chapters[ptt - 1].cell.firstSector)
    }
    /// タイトル number の先頭の開始時刻。
    public func startTime(title number: Int) -> Double? { startTime(title: number, chapter: 1) }
}

/// セルの再生時間を sector 順に足し込み、論理 sector → 時間（VOB 群の先頭から）を引く。
/// 複数のタイトルが同じセルを共有していても、同じ範囲は 1 度だけ数える。
public struct DVDSectorTimeline: Sendable {
    private struct Entry { var first: UInt32, last: UInt32, start: Double, duration: Double }
    private let entries: [Entry]

    init(cells: [DVDCell]) {
        var unique: [UInt32: DVDCell] = [:]
        for c in cells where c.lastSector >= c.firstSector { unique[c.firstSector] = c }
        var t = 0.0
        var list: [Entry] = []
        for c in unique.values.sorted(by: { $0.firstSector < $1.firstSector }) {
            list.append(Entry(first: c.firstSector, last: c.lastSector, start: t, duration: c.duration))
            t += c.duration
        }
        entries = list
    }

    public var totalDuration: Double { entries.last.map { $0.start + $0.duration } ?? 0 }

    public func time(ofSector sector: UInt32) -> Double? {
        guard let e = entries.first(where: { sector >= $0.first && sector <= $0.last }) else { return nil }
        let span = Double(e.last - e.first + 1)
        return e.start + Double(sector - e.first) / span * e.duration
    }
}

public enum DVDIFO {
    public static func parseTitleSet(_ data: Data) -> DVDTitleSetInfo? {
        let d = [UInt8](data)
        guard d.count >= 0xE8, String(bytes: d[0..<12], encoding: .ascii) == "DVDVIDEO-VTS" else { return nil }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? u16(o) << 16 | u16(o + 2) : 0 }

        // タイトルの PGC 群（VTS_PGCIT）。
        var titlePGCs: [DVDPGC] = []
        var titleEntryIDs: [UInt8] = []
        let pgcitBase = u32(0xCC) * 2048
        if pgcitBase > 0, pgcitBase + 8 <= d.count {
            let n = u16(pgcitBase)
            for j in 0..<min(n, 1000) {
                let srp = pgcitBase + 8 + j * 8
                guard srp + 8 <= d.count else { break }
                let off = u32(srp + 4)
                guard let pgc = parsePGC(d, at: pgcitBase + off) else { titlePGCs.append(.empty); titleEntryIDs.append(d[srp]); continue }
                titlePGCs.append(pgc); titleEntryIDs.append(d[srp])
            }
        }

        // タイトル → チャプター（VTS_PTT_SRPT）。
        var titles: [DVDTitle] = []
        let pttBase = u32(0xC8) * 2048
        if pttBase > 0, pttBase + 8 <= d.count {
            let n = u16(pttBase)
            let lastByte = u32(pttBase + 4)
            for t in 0..<min(n, 99) {
                let start = pttBase + u32(pttBase + 8 + t * 4)
                let end = pttBase + (t + 1 < n ? u32(pttBase + 8 + (t + 1) * 4) : lastByte + 1)
                guard start < end, end <= d.count else { continue }
                var chapters: [DVDChapter] = []
                var firstPGCNumber = 0
                var o = start
                while o + 4 <= end {
                    let pgcn = u16(o), pgn = u16(o + 2)
                    o += 4
                    if firstPGCNumber == 0 { firstPGCNumber = pgcn }
                    guard pgcn >= 1, pgcn <= titlePGCs.count, let cell = titlePGCs[pgcn - 1].entryCell(ofProgram: pgn) else { continue }
                    chapters.append(DVDChapter(programNumber: pgn, cell: cell))
                }
                let duration = firstPGCNumber >= 1 && firstPGCNumber <= titlePGCs.count ? titlePGCs[firstPGCNumber - 1].duration : 0
                titles.append(DVDTitle(number: t + 1, pgcNumber: firstPGCNumber, duration: duration, chapters: chapters))
            }
        }

        // メニューの PGC 群（VTSM_PGCI_UT。言語単位の入れ子）。
        var menus: [DVDMenuPGC] = []
        let utBase = u32(0xD0) * 2048
        if utBase > 0, utBase + 8 <= d.count {
            let languageUnits = u16(utBase)
            for k in 0..<min(languageUnits, 32) {
                let lu = utBase + 8 + k * 8
                guard lu + 8 <= d.count else { break }
                let lang = String(bytes: d[lu..<(lu + 2)], encoding: .ascii) ?? "??"
                let luBase = utBase + u32(lu + 4)
                guard luBase + 8 <= d.count else { continue }
                let n = u16(luBase)
                for j in 0..<min(n, 1000) {
                    let srp = luBase + 8 + j * 8
                    guard srp + 8 <= d.count else { break }
                    if let pgc = parsePGC(d, at: luBase + u32(srp + 4)) {
                        menus.append(DVDMenuPGC(entryID: d[srp], languageCode: lang, pgc: pgc))
                    }
                }
            }
        }
        return DVDTitleSetInfo(titles: titles, titlePGCs: titlePGCs, menus: menus,
                               timeline: DVDSectorTimeline(cells: titlePGCs.flatMap(\.cells)))
    }

    /// PGC 1 個（pgc は IFO 内の先頭バイトのオフセット）。
    static func parsePGC(_ d: [UInt8], at pgc: Int) -> DVDPGC? {
        guard pgc >= 0, pgc + 0xEC <= d.count else { return nil }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) << 8 | Int(d[o + 1]) : 0 }
        func u32(_ o: Int) -> UInt32 { o + 4 <= d.count ? UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) : 0 }
        let programCount = Int(d[pgc + 2]), cellCount = Int(d[pgc + 3])
        let duration = bcdTime(Array(d[(pgc + 4)..<(pgc + 8)]))
        let palette = (0..<16).map { u32(pgc + 0xA4 + $0 * 4) }
        let cmdOffset = u16(pgc + 0xE4), programOffset = u16(pgc + 0xE6), cellOffset = u16(pgc + 0xE8)

        var programMap: [Int] = []
        if programOffset > 0, pgc + programOffset + programCount <= d.count {
            programMap = (0..<programCount).map { Int(d[pgc + programOffset + $0]) }
        }
        var cells: [DVDCell] = []
        if cellOffset > 0 {
            for c in 0..<cellCount {
                let o = pgc + cellOffset + c * 24
                guard o + 24 <= d.count else { break }
                cells.append(DVDCell(firstSector: u32(o + 8), lastSector: u32(o + 20),
                                     duration: bcdTime(Array(d[(o + 4)..<(o + 8)])), category: u32(o)))
            }
        }
        var pre: [[UInt8]] = [], post: [[UInt8]] = [], cell: [[UInt8]] = []
        if cmdOffset > 0, pgc + cmdOffset + 8 <= d.count {
            let base = pgc + cmdOffset
            let nPre = u16(base), nPost = u16(base + 2), nCell = u16(base + 4)
            func command(_ i: Int) -> [UInt8]? {
                let o = base + 8 + i * 8
                return o + 8 <= d.count ? Array(d[o..<(o + 8)]) : nil
            }
            pre = (0..<nPre).compactMap(command)
            post = (0..<nPost).compactMap { command(nPre + $0) }
            cell = (0..<nCell).compactMap { command(nPre + nPost + $0) }
        }
        return DVDPGC(programCount: programCount, programMap: programMap, cells: cells, duration: duration,
                      palette: palette, preCommands: pre, postCommands: post, cellCommands: cell)
    }

    /// 4 byte の BCD 再生時間: 時・分・秒、4 byte 目の上位 2 bit が frame rate（01 = 25、11 = 29.97）、下位 6 bit が frame の BCD。
    static func bcdTime(_ b: [UInt8]) -> Double {
        func bcd(_ x: UInt8) -> Double { Double((x >> 4) * 10 + (x & 0x0F)) }
        let rate: Double
        switch b[3] >> 6 {
        case 1: rate = 25
        case 3: rate = 30000.0 / 1001.0
        default: rate = 0
        }
        let frames = rate > 0 ? bcd(b[3] & 0x3F) / rate : 0
        return bcd(b[0]) * 3600 + bcd(b[1]) * 60 + bcd(b[2]) + frames
    }
}

extension DVDPGC {
    static let empty = DVDPGC(programCount: 0, programMap: [], cells: [], duration: 0, palette: [],
                              preCommands: [], postCommands: [], cellCommands: [])
}

/// パレット（0x00 Y Cr Cb）を RGB（0...255。BT.601 の video range）へ。字幕の色づけに使う。
public enum DVDPalette {
    public static func rgb(_ entry: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
        let y = Double((entry >> 16) & 0xFF), cr = Double((entry >> 8) & 0xFF), cb = Double(entry & 0xFF)
        let yy = (y - 16) * 1.164
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (clamp(yy + 1.596 * (cr - 128)),
                clamp(yy - 0.813 * (cr - 128) - 0.391 * (cb - 128)),
                clamp(yy + 2.018 * (cb - 128)))
    }
}
