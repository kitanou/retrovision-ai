import CoreMedia
import Foundation
import RVDiagnostics
import RVEnhancement
import RVMediaCore
import RVMediaSources

// MARK: - 再生エンジンの公開 API（02 §2〜§5）
//
// UI はこの型にのみ依存する（INV-8）。FakePlayerEngine で UI の単体テストができる。

public enum EnginePhase: Sendable, Hashable {
    case empty
    case preparing
    case ready
    case playing
    case paused
    case seeking(target: MediaTime)
    case stalled(reason: StallReason)
    case ended
    case failed(PlaybackError)
}

public enum StallReason: String, Sendable, CaseIterable {
    case demuxStarved, decodeStarved, mediaSlow, resourceExhausted
}

public struct QualityPresentation: Sendable, Hashable {
    /// ユーザー設定の上限。
    public var requestedTier: QualityTier
    /// 制御が実際に適用している段階。
    public var activeTier: QualityTier
    public var appliedStages: [StageID]
    public var activeModel: ModelID?
    public var degradeReasons: [DegradeReason]
    public var frameStats: FrameStats

    public init(requestedTier: QualityTier = .off, activeTier: QualityTier = .off,
                appliedStages: [StageID] = [], activeModel: ModelID? = nil,
                degradeReasons: [DegradeReason] = [], frameStats: FrameStats = .init()) {
        self.requestedTier = requestedTier
        self.activeTier = activeTier
        self.appliedStages = appliedStages
        self.activeModel = activeModel
        self.degradeReasons = degradeReasons
        self.frameStats = frameStats
    }
}

public struct PlayerStateSnapshot: Sendable, Hashable {
    public var phase: EnginePhase
    public var position: MediaTime
    public var duration: MediaTime?
    public var selected: PlaybackSelection?
    public var available: [TrackInfo]
    public var quality: QualityPresentation
    public var diagnosticsSummary: DiagnosticsSummary?

    public init(phase: EnginePhase = .empty, position: MediaTime = .zero, duration: MediaTime? = nil,
                selected: PlaybackSelection? = nil, available: [TrackInfo] = [],
                quality: QualityPresentation = .init(), diagnosticsSummary: DiagnosticsSummary? = nil) {
        self.phase = phase
        self.position = position
        self.duration = duration
        self.selected = selected
        self.available = available
        self.quality = quality
        self.diagnosticsSummary = diagnosticsSummary
    }
}

public enum PlayerEvent: Sendable, Hashable {
    case phaseChanged(EnginePhase)
    case positionUpdated(position: MediaTime, duration: MediaTime?, clockDriftMS: Double)
    case structureChanged(MediaStructure)
    case tracksChanged([TrackInfo])
    case selectionChanged(PlaybackSelection)
    case qualityChanged(QualityPresentation)
    case enhancementDegraded(reason: DegradeReason, to: QualityTier)
    case warning(PlaybackError)
    case failure(PlaybackError)
    case mediaRemoved
    case statisticsUpdated(DiagnosticsSummary)
}

public struct PlayerSettings: Sendable, Hashable {
    public var enhancement: EnhancementPolicy
    public var deinterlaceMode: DeinterlaceMode
    public var aspectPolicy: AspectPolicy
    public var subtitlePolicy: SubtitleChoice
    public var advanced: AdvancedSettings

    public init(enhancement: EnhancementPolicy = .presetStandard,
                deinterlaceMode: DeinterlaceMode = .auto,
                aspectPolicy: AspectPolicy = .followSource,
                subtitlePolicy: SubtitleChoice = .auto,
                advanced: AdvancedSettings = .init()) {
        self.enhancement = enhancement
        self.deinterlaceMode = deinterlaceMode
        self.aspectPolicy = aspectPolicy
        self.subtitlePolicy = subtitlePolicy
        self.advanced = advanced
    }
}

/// UI が選ぶ強調化のプリセット（RVEnhancement を import できない App 向けの語彙。07 §5）。
public enum EnhancementPreset: String, Sendable, CaseIterable, Hashable {
    case off, conservative, standard, maximum

    public var policy: EnhancementPolicy {
        switch self {
        case .off: return .presetOff
        case .conservative: return .presetConservative
        case .standard: return .presetStandard
        case .maximum: return .presetMaximum
        }
    }

    public var displayName: String {
        switch self {
        case .off: return "オフ"
        case .conservative: return "控えめ"
        case .standard: return "標準"
        case .maximum: return "最大"
        }
    }
}

public extension PlayerSettings {
    var preset: EnhancementPreset {
        get { EnhancementPreset.allCases.first { $0.policy == enhancement } ?? .standard }
        set { enhancement = newValue.policy }
    }
}

public struct AdvancedSettings: Sendable, Hashable {
    public var maxDecodedFrameQueue: Int
    public var metricsEnabled: Bool
    public var modelChoice: ModelID?

    public init(maxDecodedFrameQueue: Int = 3, metricsEnabled: Bool = true, modelChoice: ModelID? = nil) {
        self.maxDecodedFrameQueue = maxDecodedFrameQueue
        self.metricsEnabled = metricsEnabled
        self.modelChoice = modelChoice
    }
}

// MARK: - プロトコル

/// 提示サーフェスへのハンドオフ（OQ-26 の暫定経路。#5 A1a で Metal 提示（`VideoFramePresenter`）が既定になり、
/// これは `RV_LEGACY_PRESENT` のフォールバックとして残る。元は #5 の Metal 提示に差し替えるまでの間、
/// 提示済み帧を UI 側の実装へ渡す）。契約は 05 §7 の前借りだが、GPU 段を通さないため
/// 「engine が drawable 予約に描く」ではなく「提示済み帧を渡す」形になる。
///
/// - engine は**提示（present）を済らせた帧だけを**渡す（late でも presented は増える設計どおり）。
/// - サーフェスが遅れても engine は止まらない（INV-1）: in-flight 上限（00 §5 の 3）を越えた
///   帧は渡さず `PlaybackOutcome.displayMissed` に数える。
public protocol VideoPresentSink: Sendable {
    func receive(_ frame: DecodedVideoFrame) async
}

@MainActor
public protocol PlayerEngine: AnyObject {
    /// selection nil = 構造駆動の既定選択（03 §5 の実挙動合わせ、メニュー増分）。
    /// open 後、structure の先頭 item で解決される（VIDEO_TS では menu=VMGM が先頭、
    /// 無い_disc では先頭タイトル）。UI は selectionChanged からのみ選択を導出する。
    func load(_ source: any MediaSource, selection: PlaybackSelection?) async throws -> MediaStructure
    func close() async

    func play() async
    func pause() async
    func seek(to time: MediaTime, tolerance: SeekTolerance) async
    func step(_ direction: StepDirection) async
    func setRate(_ rate: Double) async
    /// 音量（0.0〜1.0、線形。#17 の音量スライダー）。phase を変えない（INV-3 と同じ非侵襲性）。
    /// 音声線の無い素材では no-op だが、UI の状態は保持される（決定ログ #14）。
    func setVolume(_ gain: Double) async

    func select(_ track: TrackID, for kind: TrackKind) async
    func select(item: ItemID) async
    func apply(_ settings: PlayerSettings) async

    var stateSnapshot: PlayerStateSnapshot { get }
    func events() -> AsyncStream<PlayerEvent>
    var structure: MediaStructure? { get }

    /// 操作できる DVD メニューが表示されている間 true（UI はキー・マウスをメニューへ流す）。
    var isMenuActive: Bool { get }
    /// メニューへの入力。処理した（メニューが有効だった）なら true。
    @discardableResult func menuInput(_ input: MenuInput) async -> Bool
}

public extension PlayerEngine {
    var isMenuActive: Bool { false }
    func menuInput(_ input: MenuInput) async -> Bool { false }
}
