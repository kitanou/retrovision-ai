import Foundation

// MARK: - タイトルの PGC の流れ（PRE → 再生 → POST → Link …）。B2 第 8 段
//
// 本編の PGC は、再生の前に PRE コマンド、終わったあとに POST コマンドを評価する。実盤 PICHI の作りは
//   POST: GPRM12 = 1; LinkPGCN（自分自身）→ 再び PRE: … if GPRM12 == GPRM15 CallSS（ルートメニュー）
// で、本編の終わりにメニューへ戻る。PGC の再生そのもの（セルの順）は VOB の連続再生が担うので、ここでは
// コマンドの流れだけを辿り、「次に何をするか」（`DVDFlowResult`）を返す。レジスタ（GPRM / SPRM）は
// メニュー・本編を通して 1 組を持ち回る（メニューの PRE が作った値を本編の PRE が読む）。
//
// 近似（実盤の作りで足りる範囲。未確認の挙動は決定ログに載せる）:
// - PGC 内の Link（セル・プログラム・チャプター先頭）は「その PGC を先頭から再生し直す」に倒す。
// - resume / goUp / tail は何もしない（stop）。
// - Link の連鎖は 8 回で打ち切る（PRE ↔ POST の無限ループ防止）。

/// PGC の流れを辿った結果。
public enum DVDFlowResult: Sendable, Hashable {
    /// PGC n（1 始まり）を先頭から再生する。
    case play(pgc: Int)
    /// 別の動作（タイトル / チャプターの再生・メニューへ・終了 …）。
    case action(DVDMenuAction)
    /// 何もしない（再生を止めたまま）。
    case stop
}

public enum DVDTitleFlow {
    private static let maxLinks = 8

    /// タイトル `ttn` の PGC 番号と中身。
    public static func pgc(of ttn: Int, in info: DVDTitleSetInfo) -> (number: Int, pgc: DVDPGC)? {
        guard let t = info.title(ttn), t.pgcNumber >= 1, t.pgcNumber <= info.titlePGCs.count else { return nil }
        return (t.pgcNumber, info.titlePGCs[t.pgcNumber - 1])
    }

    /// PGC `number` に入る: PRE を評価し、行き先が無ければその PGC を再生する。
    public static func enter(pgc number: Int, in info: DVDTitleSetInfo, registers: inout DVDRegisters) -> DVDFlowResult {
        follow(.enter(number), in: info, registers: &registers, budget: maxLinks)
    }

    /// PGC `number` の再生が終わったあと: POST を評価し、Link / Jump を辿る。行き先が無ければ stop。
    public static func afterPlayback(pgc number: Int, in info: DVDTitleSetInfo,
                                     registers: inout DVDRegisters) -> DVDFlowResult {
        follow(.finish(number), in: info, registers: &registers, budget: maxLinks)
    }

    private enum Step { case enter(Int), finish(Int) }

    private static func follow(_ start: Step, in info: DVDTitleSetInfo, registers: inout DVDRegisters,
                               budget: Int) -> DVDFlowResult {
        var step = start
        var remaining = budget
        while remaining > 0 {
            remaining -= 1
            let number: Int, commands: [[UInt8]], isEnter: Bool
            switch step {
            case .enter(let n):
                guard n >= 1, n <= info.titlePGCs.count else { return .stop }
                number = n; commands = info.titlePGCs[n - 1].preCommands; isEnter = true
            case .finish(let n):
                guard n >= 1, n <= info.titlePGCs.count else { return .stop }
                number = n; commands = info.titlePGCs[n - 1].postCommands; isEnter = false
            }
            switch DVDVM.run(commands, registers: &registers).outcome {
            case .finished:
                return isEnter ? .play(pgc: number) : .stop
            case .jump(let command):
                return .action(DVDMenuState.action(for: command))
            case .link(let target, _):
                let next: Int?
                switch target {
                case .pgc(let n): next = n
                case .topPGC: next = number
                case .nextPGC: next = number + 1
                case .prevPGC: next = number - 1
                case .topCell, .topProgram, .cell, .program, .chapter:
                    // PGC の中の飛び先は「その PGC の先頭から」に倒す（PRE は評価し直さない）。
                    return .play(pgc: number)
                case .nextCell, .prevCell, .nextProgram, .prevProgram, .goUpPGC, .tailPGC, .resume, .noLink:
                    return .stop
                }
                guard let n = next, n >= 1, n <= info.titlePGCs.count else { return .stop }
                step = .enter(n)
            }
        }
        return .stop   // 打ち切り（Link の輪）
    }
}
