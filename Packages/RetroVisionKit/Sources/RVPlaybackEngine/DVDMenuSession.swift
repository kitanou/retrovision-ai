import Foundation
import RVMediaCore
import RVMediaSources
import RVVideoPipeline

// MARK: - DVD メニューの操作（B2 第 6 段）

/// タイトルメニューの VOB と IFO の場所。
public struct DVDMenuAssets: Sendable {
    public let vobURL: URL
    public let ifoURL: URL?
    public let vtsNumber: Int
}

/// メニューの素材を出せる MediaSource（VIDEO_TS フォルダ・ISO）。
public protocol DVDMenuAssetProviding: Sendable {
    func menuAssets(for item: ItemID) async -> DVDMenuAssets?
}

/// メニューへの入力（UI → エンジン）。矢印・決定・ポインタ（view 内の位置）。
public enum MenuInput: Sendable {
    case up, down, left, right, activate
    /// view 内の位置（左上原点）と view の大きさ。`click` なら選んだうえで決定する。
    case pointer(x: Double, y: Double, viewWidth: Double, viewHeight: Double, click: Bool)
}

/// 1 つのメニュー画面（選択状態とオーバーレイ画）。
@MainActor
final class DVDMenuSession {
    let data: DVDMenuData
    let item: ItemID
    let vtsNumber: Int
    let codedWidth: Int, codedHeight: Int
    private(set) var state: DVDMenuState
    /// レジスタ（GPRM / SPRM）。メニュー・本編を通して持ち回る（engine が渡し、変わったら受け取る）。
    private(set) var registers: DVDRegisters

    init(data: DVDMenuData, item: ItemID, vtsNumber: Int, registers: DVDRegisters = .initial()) {
        self.registers = registers
        self.data = data; self.item = item; self.vtsNumber = vtsNumber
        self.codedWidth = data.canvasWidth; self.codedHeight = data.canvasHeight
        self.state = DVDMenuState(highlight: data.pci.highlight)
        // メニューの PRE コマンドを評価して、初期のボタン選択（SPRM 8）を決める。
        _ = DVDVM.run(data.preCommands, registers: &self.registers)
        state.select(button: self.registers.highlightedButton)
    }

    func render() -> OverlayImage { DVDMenuOverlayRenderer.render(data, state: state) }

    enum Outcome { case unchanged, redraw, action(DVDMenuAction) }

    func handle(_ input: MenuInput, aspect: AspectResolution?) -> Outcome {
        switch input {
        case .up: return state.move(.up) ? .redraw : .unchanged
        case .down: return state.move(.down) ? .redraw : .unchanged
        case .left: return state.move(.left) ? .redraw : .unchanged
        case .right: return state.move(.right) ? .redraw : .unchanged
        case .activate: return .action(state.activate(registers: &registers))
        case let .pointer(x, y, w, h, click):
            guard let aspect,
                  let p = OverlayMapping.canvasPoint(viewX: x, viewY: y, viewWidth: w, viewHeight: h, aspect: aspect,
                                                     codedWidth: codedWidth, codedHeight: codedHeight),
                  state.button(atX: p.x, y: p.y) != nil else { return .unchanged }
            let moved = state.select(atX: p.x, y: p.y)
            if click { return .action(state.activate(registers: &registers)) }
            return moved ? .redraw : .unchanged
        }
    }
}
