import Foundation

// MARK: - DVD の VM（レジスタと、8 byte コマンドの評価。B2 第 7 段）
//
// 8 byte のコマンドを 64 bit の値として読み（bit 63 = byte0 の MSB）、種別（bit 63〜61）ごとに
// 条件（比較）・代入・リンク / ジャンプを評価する。ビット位置は libdvdnav の vmcmd.c の逆アセンブラ
// 側（vm_print_mnemonic）から読んだもので、実盤 PICHI のメニュー PGC のコマンド 30 個（ボタンの
// 初期選択を GPRM15 = ボタン番号 << 10 として組み立て、SetHL_BTNN で SPRM8 に写し、LinkCN のボタン欄で
// 選択を指定する作り）が、この読み方で意味どおりに読めることを確認している。
//
//   type 0: 特殊（Nop / Goto / Break / SetTmpPML）。条件 v1
//   type 1: bit 60 = 1 → Jump / Call（条件 v2）、0 → Link（条件 v1）。副命令 = bits 51〜48
//   type 2: システムレジスタの設定（SetSTN / SetNVTMR / SetMode / SetHL_BTNN）+ 付随のリンク。条件 v2
//   type 3: GPRM への代入（mov / swp / add / sub / mul / div / mod / rnd / and / or / xor）+ 付随のリンク。条件 v3
//   type 4〜6: 比較 + 代入 + リンクの複合形。**評価せず、`unsupported` として数える**（実盤で使われておらず、
//             比較と代入のビットの重なりを逆アセンブラ側だけでは決められないため）。
// 演算の飽和（add・mul は 0xFFFF、sub は 0 で止める）と 0 除算（何もしない）は、libdvdnav の挙動を
// 記憶から写した前提で、実盤では未確認（決定ログ）。

public struct DVDRegisters: Sendable, Hashable {
    /// GPRM 0〜15（16 bit）。
    public var gprm: [UInt16] = Array(repeating: 0, count: 16)
    /// SPRM 0〜23（16 bit）。8 = ハイライト中のボタン（ボタン番号 << 10）。
    public var sprm: [UInt16] = Array(repeating: 0, count: 24)

    public init() {}

    /// 再生開始時の既定（日本語メニュー、音声 1、字幕なし、アングル 1、タイトル / PGC / チャプター 1、ボタン 1）。
    public static func initial() -> DVDRegisters {
        var r = DVDRegisters()
        r.sprm[0] = 0x6A61   // "ja"
        r.sprm[1] = 0
        r.sprm[2] = 0x3E     // 字幕なし（62）
        r.sprm[3] = 1
        for i in 4...7 { r.sprm[i] = 1 }
        r.sprm[8] = 1 << 10
        r.sprm[13] = 15
        return r
    }

    /// SPRM 8 のボタン番号（0 = 未指定）。
    public var highlightedButton: Int { Int(sprm[8] >> 10) }
}

/// リンクの行き先（同じ PGC・タイトル内。PGC の再生側が解釈する）。
public enum DVDLinkTarget: Sendable, Hashable {
    case noLink
    case topCell, nextCell, prevCell
    case topProgram, nextProgram, prevProgram
    case topPGC, nextPGC, prevPGC, goUpPGC, tailPGC
    case resume
    case pgc(Int), chapter(Int), program(Int), cell(Int)
}

public enum DVDVMOutcome: Sendable, Hashable {
    /// コマンド表を最後まで（または Break で）終えた。
    case finished
    /// リンク。`button` は付随のボタン番号（0 = 無指定。指定があれば SPRM 8 に反映済み）。
    case link(DVDLinkTarget, button: Int)
    /// ジャンプ・呼び出し・終了（`DVDCommand` の jump / call / exit 系の case）。
    case jump(DVDCommand)
}

public struct DVDVMRun: Sendable {
    public var outcome: DVDVMOutcome
    /// 評価しなかったコマンド（type 4〜6、未知の副命令）。
    public var unsupported: [[UInt8]]
}

public enum DVDVM {
    /// コマンド列を、先頭（1 行目）から評価する。無限ループ防止に 1000 命令で打ち切る。
    public static func run(_ commands: [[UInt8]], registers r: inout DVDRegisters) -> DVDVMRun {
        var unsupported: [[UInt8]] = []
        var line = 0
        var steps = 0
        while line < commands.count, steps < 1000 {
            steps += 1
            let bytes = commands[line]
            guard bytes.count == 8 else { line += 1; continue }
            let c = Cmd(bytes)
            switch step(c, bytes, &r) {
            case .next: line += 1
            case .goto(let n): line = n - 1   // 行番号は 1 始まり
            case .done(let outcome): return DVDVMRun(outcome: outcome, unsupported: unsupported)
            case .unsupported: unsupported.append(bytes); line += 1
            }
        }
        return DVDVMRun(outcome: .finished, unsupported: unsupported)
    }

    // MARK: 1 命令

    private enum Step { case next, goto(Int), done(DVDVMOutcome), unsupported }

    private struct Cmd {
        let v: UInt64
        init(_ b: [UInt8]) { v = b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        /// bit `hi` から `lo` まで（両端を含む）。
        func f(_ hi: Int, _ lo: Int) -> Int { Int((v >> UInt64(lo)) & ((1 << UInt64(hi - lo + 1)) - 1)) }
        func bit(_ n: Int) -> Bool { (v >> UInt64(n)) & 1 == 1 }
    }

    private static func reg(_ byte: Int, _ r: DVDRegisters) -> UInt16 {
        byte & 0x80 != 0 ? r.sprm[(byte & 0x1F) % 24] : r.gprm[byte & 0x0F]
    }
    private static func operand(imm: Bool, immBits: Int, regByte: Int, _ r: DVDRegisters) -> UInt16 {
        imm ? UInt16(immBits & 0xFFFF) : reg(regByte, r)
    }

    private static func compare(_ op: Int, _ a: UInt16, _ b: UInt16) -> Bool {
        switch op {
        case 1: return a & b != 0
        case 2: return a == b
        case 3: return a != b
        case 4: return a >= b
        case 5: return a > b
        case 6: return a <= b
        case 7: return a < b
        default: return true
        }
    }

    /// 条件（比較演算 bits 54〜52。0 = 無条件）。
    private static func condition(_ c: Cmd, version: Int, _ r: DVDRegisters) -> Bool {
        let op = c.f(54, 52)
        guard op != 0 else { return true }
        let imm = c.bit(55)
        switch version {
        case 1: return compare(op, r.gprm[c.f(39, 32) & 0xF], operand(imm: imm, immBits: c.f(31, 16), regByte: c.f(23, 16), r))
        case 2: return compare(op, reg(c.f(15, 8), r), reg(c.f(7, 0), r))
        default: return compare(op, r.gprm[c.f(43, 40) & 0xF], operand(imm: imm, immBits: c.f(15, 0), regByte: c.f(7, 0), r))
        }
    }

    private static func step(_ c: Cmd, _ bytes: [UInt8], _ r: inout DVDRegisters) -> Step {
        switch c.f(63, 61) {
        case 0:
            guard condition(c, version: 1, r) else { return .next }
            switch c.f(51, 48) {
            case 0: return .next
            case 1: return .goto(c.f(7, 0))
            case 2: return .done(.finished)
            case 3: return .goto(c.f(7, 0))   // SetTmpPML（視聴制限の一時変更）は行き先だけ追う
            default: return .unsupported
            }
        case 1:
            if c.bit(60) {   // Jump / Call
                guard condition(c, version: 2, r) else { return .next }
                guard let jump = jump(c) else { return .unsupported }
                return .done(.jump(jump))
            }
            guard condition(c, version: 1, r) else { return .next }
            return link(c, &r).map { .done($0) } ?? .next
        case 2:
            guard condition(c, version: 2, r) else { return .next }
            guard setSystem(c, &r) else { return .unsupported }
            return link(c, &r).map { .done($0) } ?? .next
        case 3:
            guard condition(c, version: 3, r) else { return .next }
            setGeneral(c, &r)
            return link(c, &r).map { .done($0) } ?? .next
        default:
            return .unsupported
        }
    }

    // MARK: Jump / Call

    private static func jump(_ c: Cmd) -> DVDCommand? {
        let title = c.f(22, 16)
        switch c.f(51, 48) {
        case 1: return .exit
        case 2: return .jumpTitle(ttn: title)
        case 3: return .jumpVTSTitle(ttn: title)
        case 5: return .jumpVTSChapter(ttn: title, ptt: c.f(41, 32))
        case 6, 8:
            let space: DVDSystemSpace
            switch c.f(23, 22) {
            case 0: space = .firstPlay
            case 1: space = .vmgmMenu(c.f(19, 16))
            case 2: space = .vtsMenu(vts: c.f(30, 24), ttn: c.f(38, 32), menu: c.f(19, 16))
            default: space = .vmgmPGC(c.f(46, 32))
            }
            return c.f(51, 48) == 6 ? .jumpSystemSpace(space) : .callSystemSpace(space, resumeCell: c.f(31, 24))
        default: return nil
        }
    }

    // MARK: Link（type 1 の Link 形と、type 2・3 の付随のリンクが同じ配置）

    private static func link(_ c: Cmd, _ r: inout DVDRegisters) -> DVDVMOutcome? {
        let button = c.f(15, 10)
        let target: DVDLinkTarget
        switch c.f(51, 48) {
        case 0: return nil
        case 1:
            switch c.f(7, 0) {
            case 0: target = .noLink
            case 1: target = .topCell
            case 2: target = .nextCell
            case 3: target = .prevCell
            case 5: target = .topProgram
            case 6: target = .nextProgram
            case 7: target = .prevProgram
            case 9: target = .topPGC
            case 10: target = .nextPGC
            case 11: target = .prevPGC
            case 12: target = .goUpPGC
            case 13: target = .tailPGC
            case 16: target = .resume
            default: return nil
            }
        case 4: target = .pgc(c.f(14, 0)); return finishLink(target, button: 0, &r)
        case 5: target = .chapter(c.f(9, 0))
        case 6: target = .program(c.f(6, 0))
        case 7: target = .cell(c.f(7, 0))
        default: return nil
        }
        return finishLink(target, button: button, &r)
    }

    private static func finishLink(_ target: DVDLinkTarget, button: Int, _ r: inout DVDRegisters) -> DVDVMOutcome? {
        if case .noLink = target { return nil }
        if button != 0 { r.sprm[8] = UInt16(button) << 10 }
        return .link(target, button: button)
    }

    // MARK: Set

    /// type 2。評価できない副命令なら false。
    private static func setSystem(_ c: Cmd, _ r: inout DVDRegisters) -> Bool {
        let imm = c.bit(60)
        switch c.f(59, 56) {
        case 0: return true
        case 1:   // SetSTN: 音声（SPRM1）・字幕（SPRM2）・アングル（SPRM3）
            let enable = [39, 31, 23], immHi = [38, 30, 22], regHi = [35, 27, 19]
            for i in 0..<3 where c.bit(enable[i]) {
                let value = imm ? c.f(immHi[i], immHi[i] - 6) : Int(r.gprm[c.f(regHi[i], regHi[i] - 3) & 0xF])
                r.sprm[i + 1] = UInt16(value & 0xFFFF)
            }
            return true
        case 2:   // SetNVTMR
            r.sprm[9] = operand(imm: imm, immBits: c.f(47, 32), regByte: c.f(39, 32), r)
            return true
        case 3:   // SetMode（カウンタ / レジスタの別は持たず、値だけ入れる）
            r.gprm[c.f(19, 16) & 0xF] = operand(imm: imm, immBits: c.f(47, 32), regByte: c.f(39, 32), r)
            return true
        case 6:   // SetHL_BTNN
            r.sprm[8] = imm ? UInt16(c.f(31, 16)) : r.gprm[c.f(19, 16) & 0xF]
            return true
        default: return false
        }
    }

    /// type 3。
    private static func setGeneral(_ c: Cmd, _ r: inout DVDRegisters) {
        let op = c.f(59, 56)
        guard op != 0 else { return }
        let d = c.f(35, 32) & 0xF
        let srcByte = c.f(23, 16)
        let src = operand(imm: c.bit(60), immBits: c.f(31, 16), regByte: srcByte, r)
        let dst = r.gprm[d]
        switch op {
        case 1: r.gprm[d] = src
        case 2:   // swp: 転送元はレジスタのときだけ書き戻す
            r.gprm[d] = src
            if !c.bit(60) { if srcByte & 0x80 != 0 { r.sprm[(srcByte & 0x1F) % 24] = dst } else { r.gprm[srcByte & 0xF] = dst } }
        case 3: r.gprm[d] = UInt16(min(Int(dst) + Int(src), 0xFFFF))
        case 4: r.gprm[d] = UInt16(max(Int(dst) - Int(src), 0))
        case 5: r.gprm[d] = UInt16(min(Int(dst) * Int(src), 0xFFFF))
        case 6: if src != 0 { r.gprm[d] = dst / src }
        case 7: if src != 0 { r.gprm[d] = dst % src }
        case 8: if src != 0 { r.gprm[d] = UInt16.random(in: 1...src) }
        case 9: r.gprm[d] = dst & src
        case 10: r.gprm[d] = dst | src
        case 11: r.gprm[d] = dst ^ src
        default: break
        }
    }
}
