import Foundation
import RVMediaCore

// MARK: - 描画計画（05 §1）
//
// RenderPlan は不変。生成後は変更せず、設定変更・tier 変更では新しい plan を作る（INV-3）。
// このファイルは Metal を import しない（純粋ロジック部分はテストで回せるようにする）。

public struct RenderPlan: @unchecked Sendable {
    public let id: PlanID
    public let tier: QualityTier
    public var stages: [StageRequest]
    public let output: OutputContract
    public let budget: FrameBudget
    /// 計画の正準ハッシュ。ベンチレポートで「同じ plan を再現できる」ことを示すために使う（08 §7.2）。
    public let planHash: String

    public init(id: PlanID, tier: QualityTier, stages: [StageRequest],
                output: OutputContract, budget: FrameBudget = .initialDraft) {
        self.id = id
        self.tier = tier
        self.stages = stages
        self.output = output
        self.budget = budget
        self.planHash = PlanCanonicalizer.hash(tier: tier, stages: stages, output: output)
    }

    /// INV-2: `.off` の plan は常に作れる。
    public static func metalBaseline(id: PlanID, output: OutputContract,
                                    deinterlace: DeinterlaceParameters = .auto) -> RenderPlan {
        RenderPlan(id: id, tier: .metalOnly,
                   stages: [.init(stage: .deinterlace, parameters: deinterlace),
                            .init(stage: .colorConvert, parameters: ColorConvertParameters()),
                            .init(stage: .scale, parameters: ScaleParameters())],
                   output: output)
    }

    public static func offPlan(id: PlanID, output: OutputContract) -> RenderPlan {
        RenderPlan(id: id, tier: .off,
                   stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())],
                   output: output)
    }

    public func stage(of id: StageID) -> StageRequest? { stages.first { $0.stage == id } }
}

public struct StageRequest: @unchecked Sendable {
    public let stage: StageID
    public let parameters: any StageParameters
    /// 段が必要とする入力（05 §1）。
    public let inputs: [FrameRole]

    public init(stage: StageID, parameters: any StageParameters, inputs: [FrameRole] = [.current]) {
        self.stage = stage
        self.parameters = parameters
        self.inputs = inputs
    }
}

public enum FrameRole: Sendable, Hashable {
    case current
    case previousOutput
    /// 2 つのフィールドを別扱いで受け取る場合（05 §5.1）。
    case fields(order: FieldOrder)
}

public protocol StageParameters: Sendable {
    /// 正準表現（planHash の材料）。同じ設定は同じ文字列になること。
    var canonicalForm: String { get }
}

public struct OutputContract: Sendable, Hashable {
    public var displayPixels: PixelSize
    public var aspect: AspectResolution
    public var present: PresentMode
    public var compositeSubtitle: Bool
    /// offscreen 検証では present を行わない（09 §3）。pipeline に分岐を作らないための表現。
    public enum PresentMode: String, Sendable { case drawable, offscreen }

    public init(displayPixels: PixelSize, aspect: AspectResolution,
                present: PresentMode = .drawable, compositeSubtitle: Bool = false) {
        self.displayPixels = displayPixels
        self.aspect = aspect
        self.present = present
        self.compositeSubtitle = compositeSubtitle
    }
}

/// 段別予算（開発計画 §5 の仮配分。実測で置き換える）。
public struct FrameBudget: Sendable, Hashable {
    public var decodeMS: Double
    public var deinterlaceMS: Double
    public var inferenceMS: Double
    public var postMS: Double
    public var presentMS: Double
    public var headroomMS: Double

    public init(decodeMS: Double, deinterlaceMS: Double, inferenceMS: Double,
                postMS: Double, presentMS: Double, headroomMS: Double) {
        self.decodeMS = decodeMS
        self.deinterlaceMS = deinterlaceMS
        self.inferenceMS = inferenceMS
        self.postMS = postMS
        self.presentMS = presentMS
        self.headroomMS = headroomMS
    }

    /// 初期案。**33.37 ms（29.97 fps）以内に収まる値でなければならない**（開発計画 §5）。
    /// 合計は 33.0 ms に抑え、0.4 ms を実測での再配分の余裕に残す。
    public static let initialDraft = FrameBudget(decodeMS: 5.5, deinterlaceMS: 3, inferenceMS: 18,
                                                postMS: 2, presentMS: 1.5, headroomMS: 3)

    public var totalMS: Double {
        decodeMS + deinterlaceMS + inferenceMS + postMS + presentMS + headroomMS
    }

    /// 目标 fps で総予算が収まるかの検証（plan 生成時に必ず通す）。
    public func isFeasible(for frameRate: FrameRate) -> Bool {
        totalMS <= (1_000 / frameRate.framesPerSecond) + 0.0001
    }
}

public struct DeinterlaceParameters: StageParameters, Sendable {
    public var mode: DeinterlaceMode
    public init(mode: DeinterlaceMode = .auto) { self.mode = mode }
    /// 既定。detector の結果から actual mode を選ぶ（05 §5.2）。
    public static let auto = DeinterlaceParameters(mode: .auto)
    public var canonicalForm: String { "mode=\(mode.rawValue)" }
}

public struct ColorConvertParameters: StageParameters, Sendable {
    public var assumeBT601WhenUnstated: Bool
    public init(assumeBT601WhenUnstated: Bool = true) { self.assumeBT601WhenUnstated = assumeBT601WhenUnstated }
    public var canonicalForm: String { "assume601=\(assumeBT601WhenUnstated)" }
}

/// 非 AI（Metal）のノイズ除去段が graph に渡す最小の契約。`DenoiseParameters`（RVEnhancement）が
/// 適合する — RVVideoPipeline は RVEnhancement に依存できない（依存方向）ので、graph が読む
/// 値だけをここで受ける。nil / 0 は「この段を実行しない」（learned 実装は ML 段が担当する）。
public protocol LumaChromaDenoiseRequest: StageParameters {
    var metalDenoiseStrength: Double? { get }
}

public struct ScaleParameters: StageParameters, Sendable {
    public var filter: ScaleFilter
    public init(filter: ScaleFilter = .highQuality) { self.filter = filter }
    public var canonicalForm: String { "filter=\(filter.rawValue)" }
    public enum ScaleFilter: String, Sendable { case bilinear, highQuality }
}

/// 正準表現からの plan ハッシュ（08 §7.2）。
public enum PlanCanonicalizer {
    public static func hash(tier: QualityTier, stages: [StageRequest], output: OutputContract) -> String {
        var lines = ["tier=\(tier.rawValue)"]
        for s in stages {
            lines.append("stage=\(s.stage.rawValue);params=\(s.parameters.canonicalForm)")
        }
        lines.append("out=\(output.displayPixels.width)x\(output.displayPixels.height)")
        lines.append("dar=\(output.aspect.targetDAR.w)x\(output.aspect.targetDAR.h)")
        lines.append("aperture=\(output.aspect.cleanAperture.width)x\(output.aspect.cleanAperture.height)+\(output.aspect.cleanAperture.x)+\(output.aspect.cleanAperture.y)")
        lines.append("src=\(output.aspect.source.rawValue)")
        lines.append("present=\(output.present.rawValue)")
        return PlanHash.hex(lines.joined(separator: "\n"))
    }
}
