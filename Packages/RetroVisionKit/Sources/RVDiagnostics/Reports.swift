import Foundation
import RVMediaCore

// MARK: - 診断出力（08 §7.1）

/// JSON Lines 形式の 1 行。診断保存・後続分析用。
public struct MetricsLine: Codable, Sendable {
    public struct Stages: Codable, Sendable {
        public var stage: String
        public var p50MS: Double
        public var p95MS: Double
        public var maxMS: Double
    }

    public var timestampMS: Double
    public var windowMS: Double
    public var tier: String
    public var stages: [Stages]
    public var endToEnd: DiagnosticsSummary.Percentiles
    public var frames: FrameStats
    public var clock: ClockBlock
    public var resources: ResourceUsage
    public var queues: [String: Int]

    public struct ClockBlock: Codable, Sendable {
        public var p50MS: Double
        public var maxMS: Double
        public var audioUnderruns: Int
    }

    public init(timestamp: HostTime, summary: DiagnosticsSummary, tier: QualityTier) {
        self.timestampMS = Double(timestamp.machTime)
        self.windowMS = summary.windowMS
        self.tier = tier.metricName
        self.stages = summary.stageDurations.map {
            Stages(stage: $0.key.rawValue, p50MS: $0.value.p50, p95MS: $0.value.p95, maxMS: $0.value.max)
        }.sorted { $0.stage < $1.stage }
        self.endToEnd = summary.endToEnd
        self.frames = summary.frames
        self.clock = ClockBlock(p50MS: summary.clockDrift.p50, maxMS: summary.clockDrift.max,
                                audioUnderruns: summary.audioUnderruns)
        self.resources = summary.resources
        self.queues = summary.queueDepths
    }
}

/// 診断ログの書き出し（「診断を保存」から使う。08 §7.3）。
public struct MetricsJSONLWriter: Sendable {
    public enum WriteError: Error { case cannotOpen(URL) }

    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ line: MetricsLine) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        var data = try encoder.encode(line)
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            do { try data.write(to: url) } catch { throw WriteError.cannotOpen(url) }
        }
    }
}

// MARK: - ベンチマークレポート（08 §7.2）

public struct BenchmarkReport: Codable, Sendable {
    public static let schemaVersion = 2

    public struct RunInfo: Codable, Sendable {
        public var id: String
        public var gitRev: String
        public var appVersion: String
        public var machine: Machine
        public var display: Display
        public struct Machine: Codable, Sendable {
            public var model: String
            public var chip: String
            public var memoryGB: Int
            public var os: String
        }
        public struct Display: Codable, Sendable {
            public var refreshHzMeasured: Double
            public var pixels: String
        }
    }

    public struct Input: Codable, Sendable {
        public var fixtureID: String
        public var sha256: String
        public var resolution: String
        public var cadence: String
        public var durationS: Double
        public var frames: Int
    }

    public struct Pipeline: Codable, Sendable {
        public var tier: String
        public var planHash: String
        public var stages: [String]
        public var model: ModelBlock?
        public struct ModelBlock: Codable, Sendable {
            public var id: String
            public var revision: String
            public var computeUnits: String
            public var tile: String
        }
    }

    public struct Budget: Codable, Sendable {
        public var decode: Double
        public var deinterlace: Double
        public var inference: Double
        public var post: Double
        public var present: Double
        public var headroom: Double
    }

    public struct Results: Codable, Sendable {
        public var fpsTarget: Double
        public var fpsMeasured: Double
        public var endToEnd: DiagnosticsSummary.Percentiles
        public var deadlineMissPct: Double
        public var dropped: Int
        public var jitterMS: Double
        public var drift: DiagnosticsSummary.Percentiles
        public var perStage: [String: DiagnosticsSummary.Percentiles]
    }

    /// 実行していない項目は空欄にせず null で置く（08 §7.2）。
    public struct Quality: Codable, Sendable {
        private enum CodingKeys: String, CodingKey { case psnr, ssim, vmaf, flickerIndex, notesRef }

        public var psnr: Double?
        public var ssim: Double?
        public var vmaf: Double?
        public var flickerIndex: Double?
        public var notesRef: String?

        public init(psnr: Double? = nil, ssim: Double? = nil, vmaf: Double? = nil,
                    flickerIndex: Double? = nil, notesRef: String? = nil) {
            self.psnr = psnr; self.ssim = ssim; self.vmaf = vmaf
            self.flickerIndex = flickerIndex; self.notesRef = notesRef
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Nullable(psnr), forKey: .psnr)
            try c.encode(Nullable(ssim), forKey: .ssim)
            try c.encode(Nullable(vmaf), forKey: .vmaf)
            try c.encode(Nullable(flickerIndex), forKey: .flickerIndex)
            try c.encode(Nullable(notesRef), forKey: .notesRef)
        }
    }

    public struct Comparison: Codable, Sendable {
        public var baselineRunID: String
        public var diff: [String: Double]
    }

    public var schemaVersion: Int
    public var run: RunInfo
    public var input: Input
    public var pipeline: Pipeline
    public var budget: Budget
    public var results: Results
    public var quality: Quality
    public var comparison: Comparison?

    public init(schemaVersion: Int = BenchmarkReport.schemaVersion, run: RunInfo, input: Input,
                pipeline: Pipeline, budget: Budget, results: Results, quality: Quality,
                comparison: Comparison? = nil) {
        self.schemaVersion = schemaVersion
        self.run = run
        self.input = input
        self.pipeline = pipeline
        self.budget = budget
        self.results = results
        self.quality = quality
        self.comparison = comparison
    }

    public func encoded(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// 未実行の項目を null として出力するためのラッパ（08 §7.2）。
/// Swift の JSONEncoder は optional を省略するため、意図的に null を書く。
private struct Nullable<Value: Encodable>: Encodable {
    private let value: Value?
    init(_ value: Value?) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}
