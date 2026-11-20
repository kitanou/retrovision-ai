import Foundation

// MARK: - DVD の字幕（SPU: sub-picture unit。メニューのボタンの絵）のデコード（04 §7、B2 の第 1 段）
//
// SPU は private_stream_1（0xBD）の substream 0x20〜0x3F で、複数の PES に分かれて届く。つなぐと:
//   [0..1] SPU 全体のサイズ、[2..3] 制御列（SP_DCSQT）の先頭へのオフセット、
//   その後ろ（[4..]）に 2 bit 画素の RLE データ、最後に制御列。
// 制御列は「遅延時間（1/100 秒 × 1024）+ 次の制御列へのオフセット + コマンド列」の連なり。
//   00 FSTA_DSP  強制表示   01 STA_DSP  表示開始   02 STP_DSP  表示終了
//   03 SET_COLOR (2 byte)  画素値 3,2,1,0 に対するパレット添字（4 bit ずつ。上位 nibble が画素値 3）
//   04 SET_CONTR (2 byte)  同じ並びのコントラスト（0 = 透明 … 15 = 不透明）
//   05 SET_DAREA (6 byte)  表示領域 x1 x2 y1 y2（各 12 bit。両端を含む）
//   06 SET_DSPXA (4 byte)  RLE の先頭オフセット（top field, bottom field。SPU の先頭から）
//   07 CHG_COLCON          途中で色を変える（行ごとの変更。サイズつきで読み飛ばす）
//   FF CMD_END
// 画素は 1 行ずつ field を交互に（top = 0,2,4…、bottom = 1,3,5…）符号化されている。

public struct Subpicture: Sendable {
    /// 表示領域の左上と寸法（画素）。
    public let x: Int, y: Int, width: Int, height: Int
    /// 画素値（0...3。background / pattern / emphasis1 / emphasis2）。行優先、width × height。
    public let pixels: [UInt8]
    /// 画素値 0...3 に対するパレット添字（0...15）と、コントラスト（0...15。0 = 透明、15 = 不透明）。
    public let paletteIndices: [Int]
    public let contrasts: [Int]
    /// 表示開始の遅延（90 kHz）。強制表示の指定があったか。
    public let startDelay: Int
    public let forcedDisplay: Bool
}

public enum SubpictureDecoder {
    /// private_stream_1 の PES payload（substream id の後ろ）を順につないだ SPU 1 個分から画を作る。
    /// 壊れた SPU は nil（呼び出し側は表示しない）。
    public static func decode(_ spu: Data) -> Subpicture? {
        let d = [UInt8](spu)
        guard d.count >= 6 else { return nil }
        let total = Int(d[0]) << 8 | Int(d[1])
        var offset = Int(d[2]) << 8 | Int(d[3])
        guard total >= 6, total <= d.count + 1, offset >= 4, offset < d.count else { return nil }

        var palette = [0, 0, 0, 0], contrast = [0, 0, 0, 0]
        var area: (x1: Int, x2: Int, y1: Int, y2: Int)?
        var topOffset = 0, bottomOffset = 0
        var startDelay = 0
        var forced = false
        var visited = Set<Int>()
        while offset + 4 <= d.count, visited.insert(offset).inserted {
            let delay = Int(d[offset]) << 8 | Int(d[offset + 1])
            let next = Int(d[offset + 2]) << 8 | Int(d[offset + 3])
            var p = offset + 4
            commands: while p < d.count {
                switch d[p] {
                case 0x00: forced = true; startDelay = delay * 1024; p += 1
                case 0x01: startDelay = delay * 1024; p += 1
                case 0x02: p += 1
                case 0x03:
                    guard p + 3 <= d.count else { return nil }
                    // 2 byte: 上位 nibble から 画素値 3, 2, 1, 0 のパレット添字。
                    palette = [Int(d[p + 2] & 0xF), Int(d[p + 2] >> 4), Int(d[p + 1] & 0xF), Int(d[p + 1] >> 4)]
                    p += 3
                case 0x04:
                    guard p + 3 <= d.count else { return nil }
                    contrast = [Int(d[p + 2] & 0xF), Int(d[p + 2] >> 4), Int(d[p + 1] & 0xF), Int(d[p + 1] >> 4)]
                    p += 3
                case 0x05:
                    guard p + 7 <= d.count else { return nil }
                    let x1 = Int(d[p + 1]) << 4 | Int(d[p + 2] >> 4)
                    let x2 = Int(d[p + 2] & 0xF) << 8 | Int(d[p + 3])
                    let y1 = Int(d[p + 4]) << 4 | Int(d[p + 5] >> 4)
                    let y2 = Int(d[p + 5] & 0xF) << 8 | Int(d[p + 6])
                    area = (x1, x2, y1, y2)
                    p += 7
                case 0x06:
                    guard p + 5 <= d.count else { return nil }
                    topOffset = Int(d[p + 1]) << 8 | Int(d[p + 2])
                    bottomOffset = Int(d[p + 3]) << 8 | Int(d[p + 4])
                    p += 5
                case 0x07:
                    // CHG_COLCON: 2 byte のサイズ（自身を含む）の後に行ごとの色変更。読み飛ばす。
                    guard p + 3 <= d.count else { return nil }
                    p += 1 + (Int(d[p + 1]) << 8 | Int(d[p + 2]))
                case 0xFF: break commands
                default: return nil   // 未知のコマンド（長さが分からない）は読み進めない
                }
            }
            if next == offset || next < offset { break }   // 最後の制御列は自分自身を指す
            offset = next
        }
        guard let area, area.x2 >= area.x1, area.y2 >= area.y1 else { return nil }
        let width = area.x2 - area.x1 + 1, height = area.y2 - area.y1 + 1
        guard width <= 1024, height <= 1024, topOffset >= 4, bottomOffset >= 4 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        decodeField(d, start: topOffset, limit: total > 0 ? min(total, d.count) : d.count,
                    firstLine: 0, width: width, height: height, into: &pixels)
        decodeField(d, start: bottomOffset, limit: total > 0 ? min(total, d.count) : d.count,
                    firstLine: 1, width: width, height: height, into: &pixels)
        return Subpicture(x: area.x1, y: area.y1, width: width, height: height, pixels: pixels,
                          paletteIndices: palette, contrasts: contrast, startDelay: startDelay, forcedDisplay: forced)
    }

    /// 1 つの field（行 firstLine, firstLine+2, …）を RLE から復号する。
    /// 符号は nibble 単位: 1〜4 nibble で (長さ, 画素値)。長さ 0 は「その行の残りすべて」。行末で byte 境界へ寄せる。
    private static func decodeField(_ d: [UInt8], start: Int, limit: Int, firstLine: Int,
                                    width: Int, height: Int, into pixels: inout [UInt8]) {
        var nibblePos = start * 2
        let nibbleLimit = limit * 2
        func nextNibble() -> Int? {
            guard nibblePos < nibbleLimit else { return nil }
            let byte = d[nibblePos >> 1]
            let n = (nibblePos & 1) == 0 ? Int(byte >> 4) : Int(byte & 0xF)
            nibblePos += 1
            return n
        }
        var line = firstLine
        while line < height {
            var x = 0
            while x < width {
                guard var v = nextNibble() else { return }
                if v < 0x4 {
                    guard let n2 = nextNibble() else { return }
                    v = v << 4 | n2
                    if v < 0x10 {
                        guard let n3 = nextNibble() else { return }
                        v = v << 4 | n3
                        if v < 0x40 {
                            guard let n4 = nextNibble() else { return }
                            v = v << 4 | n4
                        }
                    }
                }
                var length = v >> 2
                let color = UInt8(v & 0x3)
                if length == 0 || x + length > width { length = width - x }   // 0 = 行末まで（はみ出しも行末で切る）
                let base = line * width
                for i in 0..<length { pixels[base + x + i] = color }
                x += length
            }
            if nibblePos & 1 == 1 { nibblePos += 1 }   // 行末は byte 境界へ
            line += 2
        }
    }
}
