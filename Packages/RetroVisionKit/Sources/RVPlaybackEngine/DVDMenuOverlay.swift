import Foundation
import RVDecode
import RVMediaCore
import RVMediaSources
import RVVideoPipeline

// MARK: - DVD メニューのデータの読み込みと、オーバーレイ画の合成（B2 第 5 段）
//
// 読み込み: タイトルメニューの VOB（VTS_nn_0.VOB）から、ボタンのある最初の NAV pack（PCI）と、字幕（SPU）の
// 最初の 1 個を取り出し、IFO（VTS_nn_0.IFO）からパレット（メニュー PGC の CLUT）とタイトル / チャプターの表を読む。
// 合成: SPU の画素（0〜3 の 4 値）に、色（パレット添字）とコントラストを当てて、premultiplied の BGRA にする。
//   - 選択中のボタンの矩形の中は、PCI の btn_colit（そのボタンの色グループ）の「選択」の色（決定の最中は「実行」の色）で
//     SPU の自身の色を置き換える。画素値 0〜3 のそれぞれに、パレット添字とコントラストが指定される。
//   - それ以外は SPU 自身の SET_COLOR / SET_CONTR を使う（メニューの SPU は普通コントラスト 0 = 透明で、
//     ボタンを選んだときだけ btn_colit で見えるようになる — 実盤 PICHI のハート形カーソルがこの作り）。
// コントラスト（0…15）は 15 で不透明、0 で透明（alpha = contrast / 15）。

struct DVDMenuData: Sendable {
    let pci: DVDNavPCI
    let subpicture: Subpicture
    let titleSet: DVDTitleSetInfo
    /// メニューの PGC のコマンド表（PRE = 表示前に評価して、ボタンの初期選択などを決める）。
    let preCommands: [[UInt8]]
    /// メニューのパレット 16 色（0x00 Y Cr Cb）。
    let palette: [UInt32]
    /// 映像の coded frame の寸法（オーバーレイ画の寸法。DVD は 720x480 / 720x576）。
    let canvasWidth: Int, canvasHeight: Int

    /// タイトルメニューの VOB と IFO から読む。ボタンも字幕も無いメニュー（静止画だけ）は nil
    /// （呼び出し側は操作できないメニューとして静止画の表示にとどめる）。
    static func load(vobURL: URL, ifoURL: URL?, canvasWidth: Int, canvasHeight: Int) -> DVDMenuData? {
        guard let vob = try? Data(contentsOf: vobURL, options: .mappedIfSafe) else { return nil }
        // ボタンのある最初の NAV pack。
        guard let pci = DVDNavigation.scanNavPacks(in: vob).map(\.pci).first(where: { !$0.highlight.buttons.isEmpty }),
              let spuData = SubpictureDecoder.firstUnit(fromProgramStream: vob),
              let subpicture = SubpictureDecoder.decode(spuData) else { return nil }
        let titleSet = ifoURL.flatMap { try? Data(contentsOf: $0) }.flatMap(DVDIFO.parseTitleSet)
            ?? DVDTitleSetInfo.empty
        // メニューのパレット: ルートメニュー（種別 3）、無ければ最初のメニュー PGC。無ければ灰色の階調。
        let menu = titleSet.menus.first { $0.menuType == 3 } ?? titleSet.menus.first
        let palette = menu.map(\.pgc.palette).flatMap { $0.count == 16 ? $0 : nil }
            ?? (0..<16).map { UInt32(0x00_00_80_80) | UInt32(16 + $0 * 14) << 16 }
        return DVDMenuData(pci: pci, subpicture: subpicture, titleSet: titleSet,
                           preCommands: menu?.pgc.preCommands ?? [], palette: palette,
                           canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }
}

enum DVDMenuOverlayRenderer {
    /// 現在の選択状態のオーバーレイ画（映像の coded frame の寸法）。
    static func render(_ data: DVDMenuData, state: DVDMenuState) -> OverlayImage {
        let w = data.canvasWidth, h = data.canvasHeight
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let sp = data.subpicture
        let highlight = data.pci.highlight
        let selected = state.selected

        // 画素値 0〜3 → (b, g, r, alpha) の表を、SPU 自身用と、選択ボタン用（選択 / 実行）で作る。
        func table(palette indices: [Int], contrasts: [Int]) -> [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] {
            (0..<4).map { v in
                let alpha = max(0, min(15, contrasts[v]))
                guard alpha > 0 else { return (0, 0, 0, 0) }
                let entry = data.palette[max(0, min(15, indices[v]))]
                let c = DVDPalette.rgb(entry)
                let a = Double(alpha) / 15.0
                func premul(_ x: UInt8) -> UInt8 { UInt8((Double(x) * a).rounded()) }
                return (premul(c.b), premul(c.g), premul(c.r), UInt8((a * 255).rounded()))
            }
        }
        let own = table(palette: sp.paletteIndices, contrasts: sp.contrasts)
        var highlighted = own
        if let selected, selected.colorGroup < highlight.colorTables.count {
            let colors = highlight.colorTables[selected.colorGroup]
            highlighted = table(palette: colors.paletteIndices(action: state.isActivated),
                                contrasts: colors.contrasts(action: state.isActivated))
        }

        for sy in 0..<sp.height {
            let y = sp.y + sy
            guard y >= 0, y < h else { continue }
            for sx in 0..<sp.width {
                let x = sp.x + sx
                guard x >= 0, x < w else { continue }
                let v = Int(sp.pixels[sy * sp.width + sx])
                let useHighlight = selected?.contains(x: x, y: y) == true
                let p = (useHighlight ? highlighted : own)[v]
                guard p.a > 0 else { continue }
                let o = (y * w + x) * 4
                bgra[o] = p.b; bgra[o + 1] = p.g; bgra[o + 2] = p.r; bgra[o + 3] = p.a
            }
        }
        return OverlayImage(width: w, height: h, bgra: bgra)
    }
}
