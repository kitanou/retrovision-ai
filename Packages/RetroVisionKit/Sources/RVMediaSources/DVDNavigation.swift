import Foundation

// MARK: - DVD の NAV pack（PCI）: メニューのボタン情報（03 §5 の menu 増分。B2 の第 1 段）
//
// VOBU（約 0.4〜1 秒）ごとに先頭の NAV pack が 1 つある。2048 byte の sector で、
//   pack header（14 byte + stuffing）→ system header（0xBB）→ private_stream_2（0xBF）× 2
// の並び。1 つ目の 0xBF の substream 0x00 が PCI（979 byte）、2 つ目の substream 0x01 が DSI。
// PCI の hli（highlight information）が、メニューのボタンの位置・色グループ・上下左右の隣・
// 動作（8 byte の VM コマンド）を持つ。字幕（SPU）はボタンの「絵」で、PCI は「どこが押せるか」。
//
// 純 Foundation（RVMediaSources は RVDecode を import しない — 00 §2）。バイト列から読むだけで、
// ディスクの CSS・IFO には依存しない。実盤 PICHI の VTS_01_0.VOB（12 ボタン）で位置を画面と照合済み。

public struct DVDButton: Sendable, Hashable {
    /// ボタン番号（1 始まり。PCI の btnit の並び順 + btn_ofn）。
    public let number: Int
    /// 使う色グループ（0...2。`DVDHighlight.colorTables` の添字）。
    public let colorGroup: Int
    /// 表示範囲（画素。両端を含む）。x は 0...719、y は 0...479（NTSC）。
    public let xStart: Int, xEnd: Int, yStart: Int, yEnd: Int
    /// 選択しただけで実行する（auto action）か。
    public let autoAction: Bool
    /// 上下左右に動いたときの隣のボタン番号（0 = 動かない）。
    public let up: Int, down: Int, left: Int, right: Int
    /// 8 byte の VM コマンド（意味は `DVDCommand` が解釈する）。
    public let command: [UInt8]

    public var width: Int { xEnd - xStart + 1 }
    public var height: Int { yEnd - yStart + 1 }

    public func contains(x: Int, y: Int) -> Bool {
        x >= xStart && x <= xEnd && y >= yStart && y <= yEnd
    }
}

/// 色グループ 1 つ分の「選択（selection）」と「実行（action）」の色指定。各 32 bit は
/// 4 つの色（パレット添字 4 bit）と 4 つのコントラスト（4 bit）。上位 16 bit が色、下位 16 bit がコントラスト。
public struct DVDButtonColors: Sendable, Hashable {
    public let selection: UInt32
    public let action: UInt32

    /// SPU の画素値（0...3。background / pattern / emphasis1 / emphasis2）に対するパレット添字。
    public func paletteIndices(action: Bool) -> [Int] { Self.nibbles(action ? self.action : selection, shift: 16) }
    /// 同じ並びのコントラスト（0...15。15 = 不透明）。
    public func contrasts(action: Bool) -> [Int] { Self.nibbles(action ? self.action : selection, shift: 0) }

    // 16 bit は上位 nibble から emphasis2, emphasis1, pattern, background の順。画素値 0...3 の並びに直して返す。
    private static func nibbles(_ value: UInt32, shift: UInt32) -> [Int] {
        let v = (value >> shift) & 0xFFFF
        return [Int(v & 0xF), Int((v >> 4) & 0xF), Int((v >> 8) & 0xF), Int((v >> 12) & 0xF)]
    }
}

public struct DVDHighlight: Sendable, Hashable {
    /// 0 = ハイライト情報なし、1 = 全部新しい、2 = 前の VOBU から変更なし、3 = 一部変更。
    public let status: Int
    /// 表示開始・終了（90 kHz。終了が 0xFFFFFFFF なら「次の VOBU まで / 無期限」）。
    public let startPTM: UInt32, endPTM: UInt32
    public let buttonCount: Int
    /// 最初に選択されているボタン（強制選択）の番号。0 = 指定なし。
    public let forcedSelectButton: Int
    /// 最初に実行されるボタン（強制実行）の番号。0 = 指定なし。
    public let forcedActionButton: Int
    public let colorTables: [DVDButtonColors]
    public let buttons: [DVDButton]

    public func button(numbered n: Int) -> DVDButton? { buttons.first { $0.number == n } }
}

public struct DVDNavPCI: Sendable, Hashable {
    /// この VOBU の NAV pack の論理 sector（VOB 内）。
    public let navPackLBN: UInt32
    /// VOBU の表示開始・終了（90 kHz。VOB 内の時刻。シーク・セル ↔ 時間の対応に使う）。
    public let vobuStartPTM: UInt32, vobuEndPTM: UInt32
    /// UOP 制御（ユーザー操作の禁止ビット）。
    public let userOperationControl: UInt32
    public let highlight: DVDHighlight
}

public enum DVDNavigation {
    /// NAV pack の sector（2048 byte）から PCI を読む。NAV pack でなければ nil。
    public static func parseNavPackSector(_ sector: Data) -> DVDNavPCI? {
        guard sector.count >= 2048 else { return nil }
        let b = [UInt8](sector.prefix(2048))
        guard b[0] == 0, b[1] == 0, b[2] == 1, b[3] == 0xBA else { return nil }
        var i = 14 + Int(b[13] & 0x07)
        // system header（0xBB）があれば読み飛ばす。
        if i + 6 <= 2048, b[i] == 0, b[i + 1] == 0, b[i + 2] == 1, b[i + 3] == 0xBB {
            i += 6 + (Int(b[i + 4]) << 8 | Int(b[i + 5]))
        }
        // private_stream_2（0xBF）の substream 0x00 = PCI（979 byte）。
        guard i + 7 + 979 <= 2048, b[i] == 0, b[i + 1] == 0, b[i + 2] == 1, b[i + 3] == 0xBF,
              b[i + 6] == 0x00 else { return nil }
        return parsePCI(Array(b[(i + 7)..<(i + 7 + 979)]), sectorLBN: nil)
    }

    /// PCI（979 byte）本体を読む。
    public static func parsePCI(_ p: [UInt8], sectorLBN: UInt32?) -> DVDNavPCI? {
        guard p.count >= 979 else { return nil }
        func u16(_ o: Int) -> UInt32 { UInt32(p[o]) << 8 | UInt32(p[o + 1]) }
        func u32(_ o: Int) -> UInt32 { u16(o) << 16 | u16(o + 2) }
        // pci_gi（60 byte）: nv_pck_lbn(4) vobu_cat(2) zero(2) vobu_uop_ctl(4) vobu_s_ptm(4) vobu_e_ptm(4) …
        let lbn = u32(0)
        let uop = u32(8), sPTM = u32(12), ePTM = u32(16)
        // hli は pci_gi(60) + nsml_agli(36) の後ろ。hli_gi(22) + btn_colit(24) + btnit(36×18)。
        let h = 60 + 36
        let hliStatus = Int(u16(h))
        let hStart = u32(h + 2), hEnd = u32(h + 6)
        let buttonOffset = Int(p[h + 16])         // btn_ofn
        let buttonCount = Int(p[h + 17])          // btn_ns
        let forcedSelect = Int(p[h + 20]), forcedAction = Int(p[h + 21])

        var colors: [DVDButtonColors] = []
        for g in 0..<3 {
            let o = h + 22 + g * 8
            colors.append(DVDButtonColors(selection: u32(o), action: u32(o + 4)))
        }
        var buttons: [DVDButton] = []
        if hliStatus != 0 {
            for k in 0..<min(buttonCount, 36) {
                let o = h + 46 + k * 18
                let w1 = Int(p[o]) << 16 | Int(p[o + 1]) << 8 | Int(p[o + 2])
                let w2 = Int(p[o + 3]) << 16 | Int(p[o + 4]) << 8 | Int(p[o + 5])
                // 24 bit: btn_coln(2) x_start(10) zero(2) x_end(10) / auto_action(2) y_start(10) zero(2) y_end(10)
                let x0 = (w1 >> 12) & 0x3FF, x1 = w1 & 0x3FF
                let y0 = (w2 >> 12) & 0x3FF, y1 = w2 & 0x3FF
                guard x1 >= x0, y1 >= y0 else { continue }
                buttons.append(DVDButton(
                    // btn_coln は 1...3（色グループ番号）。0 は指定なしなので 0 番グループに寄せる。
                    number: buttonOffset + k + 1, colorGroup: max(((w1 >> 22) & 3) - 1, 0),
                    xStart: x0, xEnd: x1, yStart: y0, yEnd: y1, autoAction: ((w2 >> 22) & 3) == 1,
                    up: Int(p[o + 6] & 0x3F), down: Int(p[o + 7] & 0x3F),
                    left: Int(p[o + 8] & 0x3F), right: Int(p[o + 9] & 0x3F),
                    command: Array(p[(o + 10)..<(o + 18)])))
            }
        }
        let highlight = DVDHighlight(status: hliStatus, startPTM: hStart, endPTM: hEnd,
                                     buttonCount: buttonCount, forcedSelectButton: forcedSelect,
                                     forcedActionButton: forcedAction, colorTables: colors, buttons: buttons)
        return DVDNavPCI(navPackLBN: sectorLBN ?? lbn, vobuStartPTM: sPTM, vobuEndPTM: ePTM,
                         userOperationControl: uop, highlight: highlight)
    }

    /// VOB 全体を走査して、NAV pack ごとの PCI（sector 番号つき）を返す。
    public static func scanNavPacks(in vob: Data) -> [(sector: Int, pci: DVDNavPCI)] {
        var result: [(Int, DVDNavPCI)] = []
        let sectorCount = vob.count / 2048
        for s in 0..<sectorCount {
            let range = (vob.startIndex + s * 2048)..<(vob.startIndex + (s + 1) * 2048)
            // NAV pack は 0xBF を持つ。映像・音声の sector は 0xBB / 0xBF が先頭付近に無いので、先頭 64 byte だけ見て絞る。
            let head = vob[range].prefix(64)
            guard head.firstRange(of: [0x00, 0x00, 0x01, 0xBF]) != nil,
                  let pci = parseNavPackSector(vob[range]) else { continue }
            result.append((s, pci))
        }
        return result
    }
}
