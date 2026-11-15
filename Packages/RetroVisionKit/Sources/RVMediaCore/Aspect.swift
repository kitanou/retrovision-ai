import Foundation

/// 比率（既約化して保持）。01 §2。
public struct AspectRatio: Sendable, Hashable, CustomStringConvertible {
    public var w: Int32
    public var h: Int32

    public init(w: Int32, h: Int32) {
        precondition(w > 0 && h > 0, "aspect must be positive")
        let g = Self.gcd(Int64(w), Int64(h))
        self.w = Int32(Int64(w) / g)
        self.h = Int32(Int64(h) / g)
    }

    public static let square = AspectRatio(w: 1, h: 1)
    public static let dar4x3 = AspectRatio(w: 4, h: 3)
    public static let dar16x9 = AspectRatio(w: 16, h: 9)
    public static let dar2p21x1 = AspectRatio(w: 221, h: 100)
    /// ITU-R BT.601 NTSC のサンプルアスペクト比（05 §6 の 720/704 の注意を参照）。
    public static let bt601NTSCSample = AspectRatio(w: 10, h: 11)
    /// ITU-R BT.601 PAL。
    public static let bt601Palsample = AspectRatio(w: 12, h: 11)

    public var value: Double { Double(w) / Double(h) }
    public var description: String { "\(w):\(h)" }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = Swift.abs(a), y = Swift.abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}

/// codedSize の座標系における矩形。CoreMedia の clean aperture（`CMRectCoordinate`）への変換は
/// 対応を取る層で行う（ここでは CoreMedia の型を使わない）。
public struct PixelRect: Sendable, Hashable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static func centered(width: Int32, height: Int32, in full: PixelRect) -> PixelRect {
        let w = Swift.max(1, Swift.min(width, full.width))
        let h = Swift.max(1, Swift.min(height, full.height))
        return PixelRect(x: full.x + (full.width - w) / 2,
                         y: full.y + (full.height - h) / 2,
                         width: w, height: h)
    }
}

/// 比に関するソース側の断片。これらを 1 か所で解決し、結果だけを流す（01 §2、05 §6）。
public struct AspectSignals: Sendable, Hashable {
    /// MPEG-2 sequence display extension の aspect_ratio_information。
    public enum MPEGAspectInfo: Int32, Sendable {
        case unspecified = 1        // 1:1 の sample 比を意味する
        case dar4x3 = 2
        case dar16x9 = 3
        case dar2p21x1 = 4
    }

    /// DVD の video_ts_attr / VTS attribute から取る表示比率の指示。
    public enum DVDAspectFlag: Int32, Sendable { case allowed4x3 = 0, allowed16x9 = 1 }

    public var mpegAspectInformation: MPEGAspectInfo?
    public var dvdAspectFlag: DVDAspectFlag?
    /// known standard から導くサンプルアスペクト比（BT.601 NTSC/PAL など）。
    public var sampleAspectFromStandard: AspectRatio?
    /// パースキャン等の切り出し情報。Phase 2 では解析のみ（05 §6）。
    public var statedCleanAperture: PixelRect?

    public init(mpegAspectInformation: MPEGAspectInfo? = nil,
                dvdAspectFlag: DVDAspectFlag? = nil,
                sampleAspectFromStandard: AspectRatio? = nil,
                statedCleanAperture: PixelRect? = nil) {
        self.mpegAspectInformation = mpegAspectInformation
        self.dvdAspectFlag = dvdAspectFlag
        self.sampleAspectFromStandard = sampleAspectFromStandard
        self.statedCleanAperture = statedCleanAperture
    }
}

/// 比の解決方針（05 §6）。
public enum AspectPolicy: Sendable, Hashable {
    /// ソースの信号から解決する。既定。
    case followSource
    /// 画面に合わせて引き伸ばす（ユーザーが明示的に選ぶ場合のみ。#5 の受入基準に抵触しうる）。
    case fitToDisplay
    /// ユーザーが固定する。**最高優先**（05 §6 の 4 は「固定した場合はソースの信号に勝る」と解釈する）。
    case explicit(AspectRatio)
}

/// 解決結果。UI と pipeline はこれだけを見る（01 §2）。
public struct AspectResolution: Sendable, Hashable {
    public var targetDAR: AspectRatio
    /// codedSize から実際に表示する範囲（720 幅のまま比率計算をしないための切り出し。05 §6）。
    public var cleanAperture: PixelRect
    /// どの信号から解決したか。診断・再現性のために必ず残す。
    public var source: AspectSource

    public enum AspectSource: String, Sendable {
        case userOverride
        case dvdAspectFlag
        case mpegDisplayExtension
        case statedCleanAperture
        case sampleAspectOnly
        case unresolved
    }
}

/// 比の解決は 1 か所で行う（INV-3: 結果は plan に焼き込む）。
public enum AspectResolver {
    /// - Parameter coded: エンコード寸法とフルフレーム矩形。
    public static func resolve(codedSize: PixelSize,
                               signals: AspectSignals,
                               policy: AspectPolicy) -> AspectResolution {
        let full = PixelRect(x: 0, y: 0, width: codedSize.width, height: codedSize.height)

        switch policy {
        case .explicit(let dar):
            return AspectResolution(targetDAR: dar,
                                    cleanAperture: fitCleanAperture(to: dar, coded: codedSize, signals: signals) ?? full,
                                    source: .userOverride)
        case .fitToDisplay:
            // 画面比率に合わせる選択。切り出しはしない（引き伸ばすことを明示的に選んだ場合のみ）。
            return AspectResolution(targetDAR: signals.resolvedTargetDAR() ?? .dar4x3,
                                    cleanAperture: full,
                                    source: signals.darSource() ?? .unresolved)
        case .followSource:
            break
        }

        // 1. 目標 DAR 指示（DVD flag → MPEG display extension）
        if let flag = signals.dvdAspectFlag {
            let dar: AspectRatio = (flag == .allowed16x9) ? .dar16x9 : .dar4x3
            if let aperture = fitCleanAperture(to: dar, coded: codedSize, signals: signals) {
                return AspectResolution(targetDAR: dar, cleanAperture: aperture, source: .dvdAspectFlag)
            }
            return AspectResolution(targetDAR: dar, cleanAperture: full, source: .dvdAspectFlag)
        }
        if let info = signals.mpegAspectInformation {
            let dar: AspectRatio?
            switch info {
            case .dar4x3: dar = .dar4x3
            case .dar16x9: dar = .dar16x9
            case .dar2p21x1: dar = .dar2p21x1
            case .unspecified: dar = nil
            }
            if let dar {
                if let aperture = fitCleanAperture(to: dar, coded: codedSize, signals: signals) {
                    return AspectResolution(targetDAR: dar, cleanAperture: aperture, source: .mpegDisplayExtension)
                }
                return AspectResolution(targetDAR: dar, cleanAperture: full, source: .mpegDisplayExtension)
            }
        }

        // 2. 明示的な clean aperture
        if let stated = signals.statedCleanAperture, signals.sampleAspectFromStandard != nil {
            let sa = signals.sampleAspectFromStandard!
            let dar = AspectRatio(w: Int32(Int64(stated.width) * Int64(sa.w)),
                                  h: Int32(Int64(stated.height) * Int64(sa.h)))
            return AspectResolution(targetDAR: dar, cleanAperture: stated, source: .statedCleanAperture)
        }

        // 3. sample aspect のみ。目標 DAR が得られない場合は 4:3 に既定で倒さない（05 §6）。
        if let sa = signals.sampleAspectFromStandard {
            let dar = AspectRatio(w: Int32(Int64(codedSize.width) * Int64(sa.w)),
                                  h: Int32(Int64(codedSize.height) * Int64(sa.h)))
            return AspectResolution(targetDAR: dar, cleanAperture: full, source: .sampleAspectOnly)
        }

        // 4. 解決できない。UI に選択を求めるため、source に unresolved を残す。
        return AspectResolution(targetDAR: .square, cleanAperture: full, source: .unresolved)
    }

    /// 目標 DAR になるように、codedSize 内の切り出し矩形を求める。
    /// 720 サンプルにはブランキング部分がふくまれるため、目標比から逆算した幅で切り出す（05 §6）。
    private static func fitCleanAperture(to dar: AspectRatio,
                                         coded: PixelSize,
                                         signals: AspectSignals) -> PixelRect? {
        guard let sa = signals.sampleAspectFromStandard else { return nil }
        // 必要なサンプル幅 = DAR × 高さ × (sa.h / sa.w)
        let neededW = Int64(coded.height) * Int64(dar.w) * Int64(sa.h) / (Int64(dar.h) * Int64(sa.w))
        guard neededW > 0 else { return nil }
        let w = Int32(neededW)
        if w <= coded.width {
            return PixelRect.centered(width: w, height: coded.height,
                                     in: PixelRect(x: 0, y: 0, width: coded.width, height: coded.height))
        }
        // 必要な幅が coded より広い → 切り出せない。letterbox 側で解決するため、フルフレームを返す。
        return PixelRect(x: 0, y: 0, width: coded.width, height: coded.height)
    }
}

extension AspectSignals {
    /// 信号から目標 DAR を取り出せるだけ取り出す（诊断用。解決そのものは AspectResolver が行う）。
    fileprivate func resolvedTargetDAR() -> AspectRatio? {
        if let f = dvdAspectFlag { return f == .allowed16x9 ? .dar16x9 : .dar4x3 }
        switch mpegAspectInformation {
        case .dar4x3: return .dar4x3
        case .dar16x9: return .dar16x9
        case .dar2p21x1: return .dar2p21x1
        default: return nil
        }
    }

    fileprivate func darSource() -> AspectResolution.AspectSource? {
        if dvdAspectFlag != nil { return .dvdAspectFlag }
        if mpegAspectInformation != nil { return .mpegDisplayExtension }
        return nil
    }
}

/// エンコード寸法。
public struct PixelSize: Sendable, Hashable {
    public var width: Int32
    public var height: Int32
    public init(width: Int32, height: Int32) { self.width = width; self.height = height }
}
