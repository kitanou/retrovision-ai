import Foundation
import RVMediaCore
import RVMLRuntime
import RVVideoPipeline

// MARK: - 強調化ステージの設定（07 §1、§5）
//
// どの滤镜をどの順で掛けるかは plan に現れる順序と参数で決める。
// エンジン側にコードを追加せず段を足せること（INV-6 に従い StageID は中央 enum）。

public struct SuperResolutionParameters: StageParameters, Sendable {
    public var model: ModelID
    public var targetHeight: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var tileOverlap: Int
    public var temporalBlend: TemporalPolicy

    public init(model: ModelID, targetHeight: Int = 1_080,
                tileWidth: Int = 192, tileHeight: Int = 108, tileOverlap: Int = 16,
                temporalBlend: TemporalPolicy = .off) {
        self.model = model
        self.targetHeight = targetHeight
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.tileOverlap = tileOverlap
        self.temporalBlend = temporalBlend
    }

    public var canonicalForm: String {
        "model=\(model.rawValue);h=\(targetHeight);tile=\(tileWidth)x\(tileHeight)+\(tileOverlap);blend=\(temporalBlend.rawValue)"
    }
}

public enum TemporalPolicy: String, Sendable, CaseIterable { case off, light, strong }

public struct DenoiseParameters: StageParameters, Sendable {
    public enum Artifact: String, Sendable, CaseIterable { case blocking, ringing, mosquito, chromaNoise, grain }
    public enum Protect: String, Sendable, CaseIterable { case faces, lineArt, grain, fineTexture, subtitles }
    public enum Implementation: String, Sendable { case metalGuided, learned }

    public var strength: Double
    public var targets: Set<Artifact>
    public var protect: Set<Protect>
    public var implementation: Implementation
    public var learnedModel: ModelID?

    /// 既定は保守的（Issue #8 の要求）。
    public init(strength: Double = 0.35,
                targets: Set<Artifact> = [.blocking, .chromaNoise],
                protect: Set<Protect> = [.faces, .lineArt, .grain, .fineTexture, .subtitles],
                implementation: Implementation = .metalGuided,
                learnedModel: ModelID? = nil) {
        self.strength = min(max(strength, 0), 1)
        self.targets = targets
        self.protect = protect
        self.implementation = implementation
        self.learnedModel = learnedModel
    }

    public var canonicalForm: String {
        let t = targets.map(\.rawValue).sorted().joined(separator: "+")
        let p = protect.map(\.rawValue).sorted().joined(separator: "+")
        return "strength=\(String(format: "%.2f", strength));targets=\(t);protect=\(p);impl=\(implementation.rawValue);model=\(learnedModel?.rawValue ?? "-")"
    }
}

public enum ProcessingOrder: String, Sendable, CaseIterable, Codable {
    /// 既定。SR 後の ringing / hallucination を抑える（07 §4）。
    case deintThenSrThenDenoise
    /// ノイズを先に消す。アニメ素材では有利な場合がある（07 §4）。
    case deintThenDenoiseThenSr
    case srOnly
    case denoiseOnly
}

public struct SuperResolutionPolicy: Sendable, Hashable {
    public enum Mode: String, Sendable { case off, auto, on }
    public var mode: Mode
    public var preferredModel: ModelID?
    public init(mode: Mode = .auto, preferredModel: ModelID? = nil) {
        self.mode = mode; self.preferredModel = preferredModel
    }
}

public struct DenoisePolicy: Sendable, Hashable {
    public enum Mode: String, Sendable { case off, auto, on }
    public var mode: Mode
    public var strength: Double?
    public init(mode: Mode = .auto, strength: Double? = nil) { self.mode = mode; self.strength = strength }
}

/// ユーザー設定の上限。実際の tier は 08 の制御が決める（07 §1）。
public struct EnhancementPolicy: Sendable, Hashable, Codable {
    public var tier: QualityTier
    public var allowAutomaticTierChange: Bool
    public var order: ProcessingOrder
    public var srMode: SRMode
    public var denoiseMode: DenoiseMode

    public enum SRMode: String, Codable, Sendable { case off, auto }
    public enum DenoiseMode: String, Codable, Sendable { case off, auto }

    public init(tier: QualityTier = .metalOnly, allowAutomaticTierChange: Bool = true,
                order: ProcessingOrder = .deintThenSrThenDenoise,
                srMode: SRMode = .auto, denoiseMode: DenoiseMode = .auto) {
        self.tier = tier
        self.allowAutomaticTierChange = allowAutomaticTierChange
        self.order = order
        self.srMode = srMode
        self.denoiseMode = denoiseMode
    }

    /// プリセット（07 §5）。プリセット自体は plan に現れない。
    public static let presetStandard = EnhancementPolicy()
    public static let presetOff = EnhancementPolicy(tier: .off, srMode: .off, denoiseMode: .off)
    public static let presetConservative = EnhancementPolicy(tier: .lightML)
    public static let presetMaximum = EnhancementPolicy(tier: .fullML)
}

// MARK: - plan への展開

/// policy を受け取り、plan の段列を作る（07）。
public enum StageGraphBuilder {
    public struct Request {
        public var userPolicy: EnhancementPolicy
        public var activeTier: QualityTier
        public var deinterlace: DeinterlaceMode
        public var availableModels: [ModelManifest]
        public init(userPolicy: EnhancementPolicy, activeTier: QualityTier,
                    deinterlace: DeinterlaceMode = .auto, availableModels: [ModelManifest] = []) {
            self.userPolicy = userPolicy
            self.activeTier = activeTier
            self.deinterlace = deinterlace
            self.availableModels = availableModels
        }
    }

    /// INV-2: `.off` / `.metalOnly` の plan は常に作れる。AI 段は activeTier >= .lightML のときだけ入る。
    public static func stageRequests(for request: Request) -> [StageRequest] {
        var stages: [StageRequest] = [
            StageRequest(stage: .deinterlace, parameters: DeinterlaceParameters(mode: request.deinterlace)),
            StageRequest(stage: .colorConvert, parameters: ColorConvertParameters()),
        ]

        let ceiling = min(request.userPolicy.tier, request.activeTier)
        guard ceiling >= .lightML else { return stages }

        let srModel = request.userPolicy.srMode == .auto
            ? selectModel(task: .superResolution, from: request.availableModels)
            : nil
        let denoiseModel = request.userPolicy.denoiseMode == .auto
            ? selectModel(task: .denoise, from: request.availableModels)
            : nil

        func appendSR() {
            guard let model = srModel else { return }
            stages.append(StageRequest(stage: .superResolution,
                                      parameters: SuperResolutionParameters(model: model.modelID)))
        }
        func appendDenoise() {
            guard request.userPolicy.denoiseMode != .off else { return }
            let p = DenoiseParameters(implementation: denoiseModel == nil ? .metalGuided : .learned,
                                      learnedModel: denoiseModel?.modelID)
            stages.append(StageRequest(stage: .denoise, parameters: p))
        }

        switch request.userPolicy.order {
        case .deintThenSrThenDenoise:
            appendSR(); appendDenoise()
        case .deintThenDenoiseThenSr:
            appendDenoise(); appendSR()
        case .srOnly:
            appendSR()
        case .denoiseOnly:
            appendDenoise()
        }
        return stages
    }

    /// `measuredOn` があり、期待遅延を持つモデルから、最も軽いものを選ぶ（06 §2）。
    private static func selectModel(task: ModelManifest.Task, from models: [ModelManifest]) -> ModelManifest? {
        models
            .filter { $0.task == task && $0.measuredOn != nil }
            .min { a, b in a.expectedLatencyMS.p95 < b.expectedLatencyMS.p95 }
    }
}

/// graph（RVVideoPipeline）へ渡す値。metalGuided 実装のときだけ強さを返す（learned は ML 段）。
extension DenoiseParameters: LumaChromaDenoiseRequest {
    public var metalDenoiseStrength: Double? { implementation == .metalGuided ? strength : nil }
}

