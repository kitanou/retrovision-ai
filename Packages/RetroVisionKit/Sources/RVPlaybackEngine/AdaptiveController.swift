import Foundation
import RVMediaCore

// MARK: - 適応品質制御（08 §4、§5）
//
// 決めるのは「強調化の強さ」だけ。運送・音声の設定は変更しない（INV-1）。
// 判定は純粋な値型 `AdaptivePolicyEngine` に置き、actor は状態保持と action 配信だけを持つ。
// こうすることで、fake 信号での昇格・降格を CI で検査できる（09 §8 Phase 5）。

public struct ControlSignals: Sendable, Hashable {
    public var summary: DiagnosticsSummary
    public var thermal: ThermalState
    public var memoryPressureLevel: MemoryPressureLevel
    public var modelBreakerOpen: Bool
    /// 表示予約と実提示の差（05 §7）。
    public var presentJitterMS: Double

    public enum MemoryPressureLevel: String, Sendable { case normal, warn, critical }

    public init(summary: DiagnosticsSummary, thermal: ThermalState = .nominal,
                memoryPressureLevel: ControlSignals.MemoryPressureLevel = .normal,
                modelBreakerOpen: Bool = false, presentJitterMS: Double = 0) {
        self.summary = summary
        self.thermal = thermal
        self.memoryPressureLevel = memoryPressureLevel
        self.modelBreakerOpen = modelBreakerOpen
        self.presentJitterMS = presentJitterMS
    }
}

public enum ControlAction: Sendable, Hashable {
    case setTier(QualityTier)
    case bypassStage(StageID)
    case disableTemporalBlend
    case useLighterModelVariant
    case reduceInferenceScale(Double)
    case enhanceEveryNFrames(Int)
    case setInFlightLimit(Int)
    case unloadModel
}

public struct AdaptivePolicyEngine: Sendable {
    public struct Config: Sendable {
        /// 08 §4 の初期値。Phase 5 の実測で改定する。
        public var degradeWhenMissRatioAbove: Double = 0.15
        public var holdWhenMissRatioAbove: Double = 0.08
        public var cleanWindowMaxMissRatio: Double = 0.0
        public var cleanWindowBudgetUsage: Double = 0.85
        public var upgradeAfterCleanWindows: Int = 2
        public var cooldownAfterDegradeMS: Double = 10_000
        public var breakerOpenHoldMS: Double = 600_000
        public var jitterLimitMS: Double = 8
        public var windowMS: Double = 2_000
        public init() {}
    }

    public struct State: Sendable {
        public var requestedTier: QualityTier = .metalOnly
        public var activeTier: QualityTier = .metalOnly
        /// 08 §5 の soft action をどこまで適用済みか（影響の小さい順）。
        public var appliedSoftActions: [ControlAction] = []
        public var consecutiveCleanWindows: Int = 0
        public var lastDegradeAtMS: Double = -.infinity
        public var breakerOpenedAtMS: Double?
        public init() {}
    }

    public var config: Config
    public var state: State

    public init(config: Config = Config(), state: State = State()) {
        self.config = config
        self.state = state
    }

    /// 1 窓分の信号を受けて action を返す（08 §4）。
    public mutating func evaluate(signals: ControlSignals, atMS now: Double) -> [ControlAction] {
        var actions: [ControlAction] = []

        // --- 予防的な上限（08 §4 の表） ---
        var ceiling = state.requestedTier
        switch signals.thermal {
        case .nominal, .fair: break
        case .serious: ceiling = min(ceiling, .lightML)
        case .critical: ceiling = min(ceiling, .metalOnly)
        }
        if signals.memoryPressureLevel == .warn || signals.memoryPressureLevel == .critical {
            ceiling = min(ceiling, .metalOnly)
            actions.append(.unloadModel)
        }
        if signals.modelBreakerOpen {
            if state.breakerOpenedAtMS == nil { state.breakerOpenedAtMS = now }
            ceiling = min(ceiling, .metalOnly)
        } else if let openedAt = state.breakerOpenedAtMS, now - openedAt > config.breakerOpenHoldMS {
            state.breakerOpenedAtMS = nil
        }
        if state.activeTier > ceiling {
            state.activeTier = ceiling
            actions.append(.setTier(ceiling))
            return actions
        }

        // --- 期限超過による降格 ---
        let missRatio = signals.summary.frames.deadlineMissRatio
        let budgetUsage = signals.summary.endToEnd.p95 / max(config.windowMS * 0.001, 1)
        let inFlightLimitSignal = signals.presentJitterMS > config.jitterLimitMS

        if inFlightLimitSignal {
            actions.append(.setInFlightLimit(1))
        }

        if missRatio > config.degradeWhenMissRatioAbove {
            actions.append(contentsOf: degrade(atMS: now))
            state.consecutiveCleanWindows = 0
            return actions
        }
        if missRatio > config.holdWhenMissRatioAbove {
            state.consecutiveCleanWindows = 0
            return actions
        }

        // --- clean window の数え上げと昇格 ---
        if missRatio <= config.cleanWindowMaxMissRatio && budgetUsage <= config.cleanWindowBudgetUsage {
            state.consecutiveCleanWindows += 1
        } else {
            state.consecutiveCleanWindows = 0
        }

        if state.consecutiveCleanWindows >= config.upgradeAfterCleanWindows,
           now - state.lastDegradeAtMS >= config.cooldownAfterDegradeMS,
           !state.appliedSoftActions.isEmpty {
            // 降格の逆順で 1 つだけ戻す（08 §5）。
            if let last = state.appliedSoftActions.popLast() {
                actions.append(reverse(of: last))
                state.consecutiveCleanWindows = 0
            }
        } else if state.consecutiveCleanWindows >= config.upgradeAfterCleanWindows,
                  state.appliedSoftActions.isEmpty, state.activeTier < state.requestedTier {
            let next = QualityTier(rawValue: state.activeTier.rawValue + 1) ?? state.requestedTier
            state.activeTier = Swift.min(next, state.requestedTier)
            actions.append(.setTier(state.activeTier))
            state.consecutiveCleanWindows = 0
        }
        return actions
    }

    /// 影響の小さい順に 1 つ適用する（08 §5）。
    private mutating func degrade(atMS now: Double) -> [ControlAction] {
        state.lastDegradeAtMS = now
        let plan: [ControlAction] = [
            .bypassStage(.sharpen),
            .disableTemporalBlend,
            .useLighterModelVariant,
            .reduceInferenceScale(0.75),
            .enhanceEveryNFrames(2),
        ]
        for action in plan where !state.appliedSoftActions.contains(action) {
            state.appliedSoftActions.append(action)
            return [action]
        }
        if state.activeTier > .off {
            let next = QualityTier(rawValue: state.activeTier.rawValue - 1) ?? .off
            state.activeTier = next
            // soft action はそのまま適用済みとして扱う（lower tier でも無効なまま）。
            // こうしないと、段を下げるたびに同じ soft action を再び出し直すことになる（08 §5）。
            return [.setTier(next)]
        }
        return []
    }

    private func reverse(of action: ControlAction) -> ControlAction {
        switch action {
        case .bypassStage(let stage): return .bypassStage(stage)      // 解除は同じ action で toggle を意味する
        case .disableTemporalBlend: return .disableTemporalBlend
        case .useLighterModelVariant: return .useLighterModelVariant
        case .reduceInferenceScale(let f): return .reduceInferenceScale(1 / max(f, 0.01))
        case .enhanceEveryNFrames: return .enhanceEveryNFrames(1)
        case .setTier(let t): return .setTier(t)
        case .setInFlightLimit: return .setInFlightLimit(3)
        case .unloadModel: return .unloadModel
        }
    }
}

// MARK: - 実行側の actor

/// `diagnosticsQueue` で動き、engine へは action を投稿するだけ。再生を待たない（INV-1）。
public actor AdaptiveController {
    private var engine: AdaptivePolicyEngine
    private let onActions: @Sendable ([ControlAction]) -> Void

    public init(policy: AdaptivePolicyEngine = AdaptivePolicyEngine(),
                onActions: @escaping @Sendable ([ControlAction]) -> Void) {
        self.engine = policy
        self.onActions = onActions
    }

    public func setUserRequestedTier(_ tier: QualityTier) {
        engine.state.requestedTier = tier
    }

    public func currentTier() -> QualityTier { engine.state.activeTier }

    public func apply(_ signals: ControlSignals, atMS now: Double) {
        let actions = engine.evaluate(signals: signals, atMS: now)
        guard !actions.isEmpty else { return }
        onActions(actions)
    }
}
