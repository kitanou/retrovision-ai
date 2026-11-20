import Foundation

// MARK: - DVD の VM コマンド（8 byte。ボタン・PGC のコマンド表）の解釈（B2 第 3 段）
//
// ビット 63 が byte0 の MSB。上位 3 bit（byte0 >> 5）が種別、byte0 の bit4 が「直接 / レジスタ」の区別、
// byte1 の下位 4 bit が副命令。byte1 の bits 6〜4 は比較演算（0 = 無条件）。
//   type 0: Nop / Goto / Break      type 1: Jump・Call（bit4 = 1）/ Link（bit4 = 0）
//   type 3: Set（GPRM への代入）
// この最小の解釈は、メニューのボタンの典型（タイトル・チャプターへ飛ぶ、メニューへ戻る）に絞る。
// レジスタ（GPRM / SPRM）を評価する VM は持たないので、**条件つきの命令は実行できる形にしない**
// （`unsupported` 側に倒す）。レジスタ間接の引数、Set の複合演算、Link 系の細かい副命令も
// `unsupported`（推測で実行しない）。
// 根拠: 実盤 PICHI のボタン 12 個（`30 05 …` = JumpVTS_PTT、`30 03 …` = JumpVTS_TT。画面のボタンと
// 意味が一致）、libdvdnav vmcmd.c と dvdinfo の仕様（調査結果。ビット位置は実装からの読み取りで、
// JumpVTS_PTT / JumpVTS_TT は実盤で確認済み。他は合成データでの検査）。

public enum DVDCommand: Sendable, Hashable {
    case nop
    case `break`
    case goto(line: Int)
    case exit
    /// ディスク全体のタイトル番号（VMG のタイトル表経由）。
    case jumpTitle(ttn: Int)
    /// VTS 内でタイトル番号（ttn）の先頭から再生。
    case jumpVTSTitle(ttn: Int)
    case jumpVTSChapter(ttn: Int, ptt: Int)
    /// メニューなどへ。
    case jumpSystemSpace(DVDSystemSpace)
    case callSystemSpace(DVDSystemSpace, resumeCell: Int)
    case linkPGC(Int)
    case linkChapter(ptt: Int, button: Int)
    case linkProgram(Int, button: Int)
    case linkCell(Int, button: Int)
    /// Link の副命令（cmd[7] の下位 5 bit。1 = TopC、2 = NextC、3 = PrevC …）。
    case linkSubset(Int, button: Int)
    case setGPRM(register: Int, value: Int)
    /// 解釈しない命令（条件つき・レジスタ間接・未対応の副命令）。元の 8 byte を保持する。
    case unsupported([UInt8])

    /// 条件つき（比較演算が付いている）か。
    public static func isConditional(_ b: [UInt8]) -> Bool {
        b.count == 8 && ((b[0] >> 5) >= 4 || ((b[1] >> 4) & 0x7) != 0)
    }

    public static func parse(_ b: [UInt8]) -> DVDCommand {
        guard b.count == 8 else { return .unsupported(b) }
        let type = Int(b[0] >> 5)
        let direct = (b[0] >> 4) & 1 == 1
        let sub = Int(b[1] & 0x0F)
        let comparison = Int((b[1] >> 4) & 0x7)
        // 種別 4〜6 は「比較 + Set + Link/Jump」の複合形。比較つきはレジスタを評価できない。
        guard type <= 3, comparison == 0 else { return .unsupported(b) }

        switch type {
        case 0:
            switch sub {
            case 0: return .nop
            case 1: return .goto(line: Int(b[7]))
            case 2: return .break
            default: return .unsupported(b)
            }
        case 1:
            let ttn = Int(b[5] & 0x7F)
            if direct {   // Jump / Call
                switch sub {
                case 1: return .exit
                case 2: return .jumpTitle(ttn: ttn)
                case 3: return .jumpVTSTitle(ttn: ttn)
                case 5: return .jumpVTSChapter(ttn: ttn, ptt: Int(b[2] & 0x03) << 8 | Int(b[3]))
                case 6, 8:
                    let space: DVDSystemSpace
                    switch Int(b[5] >> 6) & 0x3 {
                    case 0: space = .firstPlay
                    case 1: space = .vmgmMenu(Int(b[5] & 0x0F))
                    case 2: space = .vtsMenu(vts: Int(b[4] & 0x7F), ttn: Int(b[3] & 0x7F), menu: Int(b[5] & 0x0F))
                    default: space = .vmgmPGC(Int(b[2] & 0x7F) << 8 | Int(b[3]))
                    }
                    return sub == 6 ? .jumpSystemSpace(space) : .callSystemSpace(space, resumeCell: Int(b[4]))
                default: return .unsupported(b)
                }
            } else {      // Link
                let button = Int(b[6] >> 2) & 0x3F
                switch sub {
                case 1: return .linkSubset(Int(b[7] & 0x1F), button: button)
                case 4: return .linkPGC(Int(b[6] & 0x7F) << 8 | Int(b[7]))
                case 5: return .linkChapter(ptt: Int(b[6] & 0x03) << 8 | Int(b[7]), button: button)
                case 6: return .linkProgram(Int(b[7] & 0x7F), button: button)
                case 7: return .linkCell(Int(b[7]), button: button)
                default: return .unsupported(b)
                }
            }
        case 3:
            // Set GPRM（即値）: 演算子 = byte0 下位 4 bit（1 = 代入）、先 GPRM = byte3 & 0x0F、値 = byte4:byte5。
            guard direct, b[0] & 0x0F == 1, sub == 0 else { return .unsupported(b) }
            return .setGPRM(register: Int(b[3] & 0x0F), value: Int(b[4]) << 8 | Int(b[5]))
        default:
            return .unsupported(b)
        }
    }
}

public enum DVDSystemSpace: Sendable, Hashable {
    case firstPlay
    case vmgmMenu(Int)
    case vtsMenu(vts: Int, ttn: Int, menu: Int)
    case vmgmPGC(Int)
}
