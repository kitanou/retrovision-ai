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

@MainActor
public protocol PlayerEngine: AnyObject {
    func load(_ source: any MediaSource, selection: PlaybackSelection) async throws -> MediaStructure
    func close() async

    func play() async
    func pause() async
    func seek(to time: MediaTime, tolerance: SeekTolerance) async
    func step(_ direction: StepDirection) async
    func setRate(_ rate: Double) async

    func select(_ track: TrackID, for kind: TrackKind) async
    func select(item: ItemID) async
    func apply(_ settings: PlayerSettings) async

    var stateSnapshot: PlayerStateSnapshot { get }
    func events() -> AsyncStream<PlayerEvent>
    var structure: MediaStructure? { get }
}
