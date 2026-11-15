import Foundation

// MARK: - 診断 ID（01 §6、INV-6）
//
// 新しい段を足すとき、集計側（RVDiagnostics）を触らなければビルドが落ちる構造にする。

public enum StageID: String, Sendable, CaseIterable, Codable {
    case demux
    case videoDecode
    case audioDecode
    case fieldMatch
    case deinterlace
    case inverseTelecine
    case colorConvert
    case scale
    case superResolution
    case denoise
    case sharpen
    case subtitleComposite
    case tensorInput
    case tensorOutput
    case mlInference
    case present

    /// 計測が必須の段（INV-6）。これ以外を plan に入れた場合、集計は uncoveredStage として記録する。
    public static let measuredStages: [StageID] = [
        .demux, .videoDecode, .audioDecode, .deinterlace, .colorConvert, .scale,
        .superResolution, .denoise, .tensorInput, .tensorOutput, .mlInference, .present,
    ]
}

public struct FrameID: Sendable, Hashable, CustomStringConvertible {
    public var value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public var description: String { "frame:\(value)" }
}

public struct PlanID: Sendable, Hashable, CustomStringConvertible {
    public var value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public var description: String { "plan:\(value)" }
}

public struct ModelID: Sendable, Hashable, CustomStringConvertible, Codable {
    /// "task.name@revision" の形（06 §2）。
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

// MARK: - 計測サンプル

public struct MetricStageSample: Sendable, Hashable {
    public let stage: StageID
    public let frameID: FrameID
    public let start: HostTime
    public let end: HostTime
    /// GPU 側で測った場合のみ値が入る（05 §8）。CPU のみの段は nil。
    public let gpuDurationMS: Double?
    public let detail: [String: String]

    public init(stage: StageID, frameID: FrameID, start: HostTime, end: HostTime,
                gpuDurationMS: Double? = nil, detail: [String: String] = [:]) {
        self.stage = stage
        self.frameID = frameID
        self.start = start
        self.end = end
        self.gpuDurationMS = gpuDurationMS
        self.detail = detail
    }

    public var cpuDurationMS: Double { end.ms(since: start) }
}

public enum DropReason: String, Sendable, CaseIterable, Codable {
    case late
    case skippedByPolicy
    case enhancementNotReady
    case leaseViolation
    case drawableLost
}

/// 1 窓分のフレーム統計（08 §3）。
public struct FrameStats: Sendable, Hashable, Codable {
    public var total: Int
    public var presented: Int
    public var dropped: Int
    public var late: Int
    public var enhancementSkipped: Int
    public var dropReasons: [DropReason: Int]

    public init(total: Int = 0, presented: Int = 0, dropped: Int = 0, late: Int = 0,
                enhancementSkipped: Int = 0, dropReasons: [DropReason: Int] = [:]) {
        self.total = total
        self.presented = presented
        self.dropped = dropped
        self.late = late
        self.enhancementSkipped = enhancementSkipped
        self.dropReasons = dropReasons
    }

    public var deadlineMissRatio: Double {
        total == 0 ? 0 : Double(dropped + late) / Double(total)
    }
}

/// 1 Hz で UI とレポートに出す集計（08 §4、§7.1）。
public struct DiagnosticsSummary: Sendable, Hashable {
    public struct Percentiles: Sendable, Hashable, Codable {
        public var p50: Double
        public var p95: Double
        public var max: Double
        public init(p50: Double = 0, p95: Double = 0, max: Double = 0) {
            self.p50 = p50; self.p95 = p95; self.max = max
        }
    }

    public var windowMS: Double
    public var stageDurations: [StageID: Percentiles]
    public var endToEnd: Percentiles
    public var frames: FrameStats
    public var clockDrift: Percentiles
    public var audioUnderruns: Int
    public var queueDepths: [String: Int]
    public var resources: ResourceUsage

    public init(windowMS: Double = 1_000,
                stageDurations: [StageID: Percentiles] = [:],
                endToEnd: Percentiles = .init(),
                frames: FrameStats = .init(),
                clockDrift: Percentiles = .init(),
                audioUnderruns: Int = 0,
                queueDepths: [String: Int] = [:],
                resources: ResourceUsage = .init()) {
        self.windowMS = windowMS
        self.stageDurations = stageDurations
        self.endToEnd = endToEnd
        self.frames = frames
        self.clockDrift = clockDrift
        self.audioUnderruns = audioUnderruns
        self.queueDepths = queueDepths
        self.resources = resources
    }
}

public struct ResourceUsage: Sendable, Hashable, Codable {
    public var gpuMB: Double
    public var appMB: Double
    public var gpuPct: Double
    public var anePct: Double
    public var cpuPct: Double
    public var thermal: ThermalState

    public init(gpuMB: Double = 0, appMB: Double = 0, gpuPct: Double = 0, anePct: Double = 0,
                cpuPct: Double = 0, thermal: ThermalState = .nominal) {
        self.gpuMB = gpuMB; self.appMB = appMB; self.gpuPct = gpuPct
        self.anePct = anePct; self.cpuPct = cpuPct; self.thermal = thermal
    }
}

public enum ThermalState: String, Sendable, CaseIterable, Codable {
    case nominal, fair, serious, critical
}
