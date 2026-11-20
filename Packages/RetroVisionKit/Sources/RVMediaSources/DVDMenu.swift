import Foundation

// MARK: - メニューのボタン選択と入力の状態機械（B2 第 4 段。画面・再生に依存しない純粋なロジック）
//
// PCI のハイライト（ボタンの位置・上下左右の隣・コマンド）に対して、選択中のボタンを持ち、
// 入力（矢印・クリック・決定）を受けて、選択の移動か「再生側が実行する動作」を返す。
// ボタンのコマンドは `DVDCommand` が解釈し、ここで「どのタイトル / チャプターを再生するか」などの
// 動作（`DVDMenuAction`）に直す。実行できない命令（条件つき・レジスタ間接など）は `.unsupported` を返す。

public enum DVDMenuDirection: Sendable { case up, down, left, right }

/// 再生側が実行する動作。タイトル番号・チャプター番号はどちらも 1 始まり。
public enum DVDMenuAction: Sendable, Hashable {
    /// VTS 内のタイトル ttn の先頭から再生する。
    case playTitle(Int)
    /// VTS 内のタイトル ttn のチャプター ptt から再生する。
    case playChapter(title: Int, chapter: Int)
    /// メニュー（先頭の入口・VMGM・VTSM）へ戻る / 移る。
    case showMenu
    case exit
    /// 何もしない（Nop・Break など）。
    case none
    /// 実行できない命令（条件つき・レジスタ間接・未対応の副命令）。再生側は何もせず、ユーザーに伝えてよい。
    case unsupported([UInt8])
}

public struct DVDMenuState: Sendable {
    public let highlight: DVDHighlight
    /// 選択中のボタン番号（ハイライトにボタンが無ければ nil）。
    public private(set) var selectedButton: Int?
    /// 決定（action）の最中か。ハイライトの色が選択色から実行色に変わる（押した瞬間の見た目）。
    public private(set) var isActivated = false

    public init(highlight: DVDHighlight) {
        self.highlight = highlight
        // 最初に選ぶボタン: PCI の強制選択（fosl_btnn）があればそれ、無ければ最小の番号（= 1 番）。
        // 実盤のメニューの PGC の先頭コマンド（レジスタで決める）は評価できないのでこの規則に倒す。
        if highlight.forcedSelectButton != 0, highlight.button(numbered: highlight.forcedSelectButton) != nil {
            selectedButton = highlight.forcedSelectButton
        } else {
            selectedButton = highlight.buttons.map(\.number).min()
        }
    }

    /// ボタン番号で選ぶ（VM の SPRM 8 = 初期選択・リンクのボタン欄）。存在しない番号・0 は無視。変わったら true。
    @discardableResult
    public mutating func select(button number: Int) -> Bool {
        guard number != 0, number != selectedButton, highlight.button(numbered: number) != nil else { return false }
        selectedButton = number
        isActivated = false
        return true
    }

    public var selected: DVDButton? { selectedButton.flatMap { highlight.button(numbered: $0) } }

    /// 矢印キー。隣が無い（0）・存在しないボタンなら動かない。動いたら true。
    @discardableResult
    public mutating func move(_ direction: DVDMenuDirection) -> Bool {
        guard let current = selected else { return false }
        let next: Int
        switch direction {
        case .up: next = current.up
        case .down: next = current.down
        case .left: next = current.left
        case .right: next = current.right
        }
        guard next != 0, next != current.number, highlight.button(numbered: next) != nil else { return false }
        selectedButton = next
        isActivated = false
        return true
    }

    /// 座標（画面の 720x480 の座標系）にあるボタン。重なっていれば番号の小さい方。
    public func button(atX x: Int, y: Int) -> DVDButton? {
        highlight.buttons.filter { $0.contains(x: x, y: y) }.min { $0.number < $1.number }
    }

    /// マウスの移動・クリック: ボタンの上なら選択を移す（変わったら true）。ボタンの外なら何もしない。
    @discardableResult
    public mutating func select(atX x: Int, y: Int) -> Bool {
        guard let b = button(atX: x, y: y), b.number != selectedButton else { return false }
        selectedButton = b.number
        isActivated = false
        return true
    }

    /// 決定。選択中のボタンのコマンドを動作に直して返す（選択が無ければ `.none`）。
    public mutating func activate() -> DVDMenuAction {
        guard let b = selected else { return .none }
        isActivated = true
        return Self.action(for: DVDCommand.parse(b.command))
    }

    /// 選択中のボタンの「見た目の状態」を戻す（実行の色から選択の色へ）。
    public mutating func clearActivation() { isActivated = false }

    /// 決定（VM 版）。ボタンのコマンドをレジスタつきで評価する（条件つき・Set・Link を含む）。
    /// リンクのボタン欄（SPRM 8）が変わっていれば、選択もそれに移す。
    public mutating func activate(registers: inout DVDRegisters) -> DVDMenuAction {
        guard let b = selected else { return .none }
        isActivated = true
        let run = DVDVM.run([b.command], registers: &registers)
        select(button: registers.highlightedButton)
        isActivated = true
        switch run.outcome {
        case .jump(let command): return Self.action(for: command)
        case .link, .finished: return run.unsupported.isEmpty ? .none : .unsupported(b.command)
        }
    }

    public static func action(for command: DVDCommand) -> DVDMenuAction {
        switch command {
        case .jumpVTSChapter(let ttn, let ptt): return .playChapter(title: ttn, chapter: ptt)
        case .jumpVTSTitle(let ttn), .jumpTitle(let ttn): return .playTitle(ttn)
        case .jumpSystemSpace, .callSystemSpace: return .showMenu
        case .exit: return .exit
        case .nop, .break: return .none
        case .goto, .linkPGC, .linkChapter, .linkProgram, .linkCell, .linkSubset, .setGPRM:
            // PGC の中の飛び先（コマンド表の行・PGC 内のプログラム・セルへ）は PGC の再生が要る。
            // Set は後続のコマンドとセットで意味を持つ（レジスタの評価が要る）。未対応として返す
            // （元の 8 byte は `DVDMenuState.activate()` が持つボタンのコマンドから分かる）。
            return .unsupported([])
        case .unsupported(let bytes): return .unsupported(bytes)
        }
    }
}
