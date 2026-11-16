import Foundation
import RVMediaCore

// MARK: - YCbCr→RGB 変換行列（05 §3）
//
// fragment shader の constant buffer に載せる値を作る（PSO の張り替えを避ける）。
// 領域: 纹理サンプルは 8bit 正規化 [0,1] のまま（SR 段のために linearize しない — 05 §3 の
// 既定方針。行列だけが範囲・マトリクスを扱う）。
//
// rgb = M · [Y, Cb, Cr] + b   （Cb/Cr は符号無しの保存値そのまま。b が 128 中心化を吸収する）
//
// 設計の要点:
// - video range（studio swing: Y 16..235、Cb/Cr 16..240）は展開を b と M のスケールに織り込む。
// - matrix が .unspecified のとき BT.601/video range の assumption を適用できる（05 §3）。
//   適用したら `assumptionApplied` を残す — plan と診断に必ず現す（09 §5 の再現性）。

public struct YCbCrToRGBConstants: Sendable, Hashable {
    /// 行優先 3x3（[r0 r1 r2, g0 g1 g2, b0 b1 b2]）。
    public var m: [Float]
    /// 加算オフセット（中心化と range 展開を吸収）。
    public var b: [Float]
    /// BT.601 既定の押し付けが発動したか（診断・plan 表示用）。
    public var assumptionApplied: Bool
    /// 使用したマトリクスの実名称（plan に載せる）。
    public var matrixUsed: String
    public var rangeUsed: YCbCrRange

    public init(m: [Float], b: [Float], assumptionApplied: Bool,
                matrixUsed: String, rangeUsed: YCbCrRange) {
        self.m = m
        self.b = b
        self.assumptionApplied = assumptionApplied
        self.matrixUsed = matrixUsed
        self.rangeUsed = rangeUsed
    }

    /// テスト・診断用: [0,1] の YCbCr を rgb（クランプ無し）に落とす。
    public func transform(y: Double, cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
        let v = [y, cb, cr]
        func row(_ i: Int) -> Double {
            (0..<3).reduce(Double(b[i])) { acc, j in acc + Double(m[i * 3 + j]) * v[j] }
        }
        return (row(0), row(1), row(2))
    }
}

public enum ColorMatrixBuilder {
    /// kr, kb から YCbCr→RGB の係数を導出する（ITU-R BT.601/709 の定義式そのもの:
    /// R = Y + 2(1−kr)·V; B = Y + 2(1−kb)·U; G = Y − [2kb(1−kb)/kg]·U − [2kr(1−kr)/kg]·V）。
    private static func coefficients(kr: Double, kb: Double)
        -> (rV: Double, gU: Double, gV: Double, bU: Double) {
        let kg = 1.0 - kr - kb
        return (2.0 * (1.0 - kr),
                2.0 * kb * (1.0 - kb) / kg,
                2.0 * kr * (1.0 - kr) / kg,
                2.0 * (1.0 - kb))
    }

    private static func krkb(for matrix: MatrixCoefficients) -> (kr: Double, kb: Double)? {
        switch matrix {
        case .bt601_4: return (0.299, 0.114)                 // SMPTE 170M / EBU 3213
        case .bt709_2: return (0.2126, 0.0722)
        case .smpte240M: return (0.212, 0.06)                // SMPTE 240M
        case .fcc: return (0.30, 0.11)                       // FCC
        case .bt2020NonConstantLuminance: return (0.2627, 0.0593)
        case .unspecified: return nil
        }
    }

    /// ColorInfo + plan の段設定から定数を作る。matrix が決められない場合は nil
    /// （EngineCore 側は plan 生成失敗として recoverable error に落とす — 01 §5）。
    public static func resolve(color: ColorInfo, parameters: ColorConvertParameters)
        -> YCbCrToRGBConstants? {
        var matrix = color.matrix
        var assumption = false
        if matrix == .unspecified {
            // 指定された color primaries からマトリクスを導く（assumption ではない）。
            switch color.primaries {
            case .bt709: matrix = .bt709_2
            case .bt2020: matrix = .bt2020NonConstantLuminance
            case .smpte240m: matrix = .smpte240M
            case .bt601EBU, .bt601SMPTEC: matrix = .bt601_4
            case .unspecified:
                // 05 §3: 何も語らない SD 素材は BT.601/video range の assumption を適用する。
                // 発動は必ず記録する（plan・診断に assumptionApplied を残す）。
                guard parameters.assumeBT601WhenUnstated else { return nil }
                matrix = .bt601_4
                assumption = true
            }
        }
        guard let (kr, kb) = krkb(for: matrix) else { return nil }
        let c = coefficients(kr: kr, kb: kb)

        // range の選択（video range = studio swing の展開、full range = 素）:
        let ys: Double, cs: Double, yOff: Double, cOff: Double
        switch color.range {
        case .videoRange:
            ys = 255.0 / 219.0
            cs = 255.0 / 224.0
            yOff = 16.0 / 255.0
            cOff = 128.0 / 255.0
        case .fullRange:
            ys = 1.0
            cs = 1.0
            yOff = 0.0
            cOff = 128.0 / 255.0
        }

        // 保存値（[0,1]）から M·[Y,Cb,Cr] + b へ、中心化・range 展開を完全に展開して畳む:
        //   R = yScale·(Y−yOff) + vScale·rV·(Cr−cOff)
        //     = yScale·Y + vScale·rV·Cr − (yScale·yOff + vScale·rV·cOff)
        //   G = yScale·Y − uScale·gU·Cb − vScale·gV·Cr − (yScale·yOff − uScale·gU·cOff − vScale·gV·cOff)
        //   B = yScale·Y + uScale·bU·Cb − (yScale·yOff + uScale·bU·cOff)
        let yScale = ys, uScale = cs, vScale = cs
        let m: [Float] = [
            Float(yScale), 0, Float(vScale * c.rV),
            Float(yScale), Float(-uScale * c.gU), Float(-vScale * c.gV),
            Float(yScale), Float(uScale * c.bU), 0,
        ]
        let b: [Float] = [
            Float(-(yScale * yOff + vScale * c.rV * cOff)),
            Float(-(yScale * yOff - uScale * c.gU * cOff - vScale * c.gV * cOff)),
            Float(-(yScale * yOff + uScale * c.bU * cOff)),
        ]
        return YCbCrToRGBConstants(m: m, b: b, assumptionApplied: assumption,
                                   matrixUsed: matrix.rawValue, rangeUsed: color.range)
    }
}
