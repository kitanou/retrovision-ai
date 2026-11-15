import Foundation
import RVMediaCore

// MARK: - メトリクスバス（08 §3、§7.1）
//
// 再生パスからは fire-and-forget で呼び、backpressure で再生を待たせない（00 §5）。
// 窓（既定 2 s）で p50 / p95 / max を集計し、1 Hz で UI とレポートに出す。

public actor MetricBus {
    public struct Config: Sendable {
        public var windowMS: Double
        public var maxSamplesPerWindow: Int
        public init(windowMS: Double = 2_000, maxSamplesPerWindow: Int = 4_096) {
            self.windowMS = windowMS
            self.maxSamplesPerWindow = maxSamplesPerWindow
        }
    }

    private struct Window {
        var startedAt: HostTime
        var stageSamples: [StageID: DurationHistogram] = [:]
        var endToEnd = DurationHistogram()
        var drift = DurationHistogram()
        var frames = FrameStats()
        var audioUnderruns = 0
        var queueDepths: [String: Int] = [:]
        var resources = ResourceUsage()
        /// 計測されていない段が plan に入った場合の記録（INV-6 の検査）。
        var unmeasuredStages: Set<StageID> = []
    }

    private let config: Config
    private let time: any TimeSource
    private var window: Window
    private var lastSummary: DiagnosticsSummary?
    private var exporters: [@Sendable (DiagnosticsSummary) -> Void] = []

    public init(config: Config = Config(), time: any TimeSource = SystemTimeSource()) {
        self.config = config
        self.time = time
        let now = time.now()
        self.window = Window(startedAt: now)
    }

    // MARK: 記録

    public func record(_ sample: MetricStageSample) {
        guard sample.end.ms(since: sample.start) >= 0 else { return }
        rolloverIfNeeded()
        let duration = sample.gpuDurationMS ?? sample.cpuDurationMS
        window.stageSamples[sample.stage, default: DurationHistogram(capacity: 64)]
            .add(duration, capacity: config.maxSamplesPerWindow)
    }

    public func recordEndToEnd(_ sample: MetricStageSample) {
        rolloverIfNeeded()
        window.endToEnd.add(sample.cpuDurationMS, capacity: config.maxSamplesPerWindow)
    }

    public func recordFramePresented(frameID: FrameID) {
        rolloverIfNeeded()
        window.frames.total += 1
        window.frames.presented += 1
    }

    /// 提示されたが遅れた場合（dropped とは別カウント。deadlineMiss は late + dropped を数える）。
    public func recordFramePresentedLate(frameID: FrameID) {
        rolloverIfNeeded()
        window.frames.total += 1
        window.frames.presented += 1
        window.frames.late += 1
    }

    public func recordFrameDropped(reason: DropReason) {
        rolloverIfNeeded()
        window.frames.total += 1
        window.frames.dropped += 1
        window.frames.dropReasons[reason, default: 0] += 1
        if reason == .enhancementNotReady { window.frames.enhancementSkipped += 1 }
    }

    public func recordDrift(_ driftMS: Double) {
        rolloverIfNeeded()
        window.drift.add(driftMS, capacity: config.maxSamplesPerWindow)
    }

    public func recordAudioUnderrun() {
        rolloverIfNeeded()
        window.audioUnderruns += 1
    }

    public func recordQueueDepth(name: String, depth: Int) {
        rolloverIfNeeded()
        window.queueDepths[name] = depth
    }

    public func recordResources(_ usage: ResourceUsage) {
        rolloverIfNeeded()
        window.resources = usage
    }

    public func recordUnmeasuredStage(_ stage: StageID) {
        rolloverIfNeeded()
        window.unmeasuredStages.insert(stage)
    }

    // MARK: 集計

    /// 窓を閉じて DiagnosticsSummary を作る。再生側はこれを待たない（INV-1）。
    public func flush(force: Bool = false) -> DiagnosticsSummary? {
        let now = time.now()
        guard force || now.ms(since: window.startedAt) >= config.windowMS else { return nil }
        var stageDurations: [StageID: DiagnosticsSummary.Percentiles] = [:]
        for (stage, histogram) in window.stageSamples {
            stageDurations[stage] = histogram.percentiles()
        }
        let summary = DiagnosticsSummary(windowMS: now.ms(since: window.startedAt),
                                       stageDurations: stageDurations,
                                       endToEnd: window.endToEnd.percentiles(),
                                       frames: window.frames,
                                       clockDrift: window.drift.percentiles(),
                                       audioUnderruns: window.audioUnderruns,
                                       queueDepths: window.queueDepths,
                                       resources: window.resources)
        lastSummary = summary
        for exporter in exporters { exporter(summary) }
        window = Window(startedAt: now)
        return summary
    }

    public func currentSummary() -> DiagnosticsSummary? { lastSummary }

    public func addExporter(_ exporter: @escaping @Sendable (DiagnosticsSummary) -> Void) {
        exporters.append(exporter)
    }

    /// 計測されていない段（INV-6）。plan 生成側が plan 段を登録し、実行時に呼ぶ。
    public static let measuredSet: Set<StageID> = Set(StageID.measuredStages)

    private func rolloverIfNeeded() {
        // 記録のたびに窓切りを調べる（時刻取得は軽量）。
        if time.now().ms(since: window.startedAt) >= config.windowMS {
            _ = flush(force: true)
        }
    }
}

/// 窓内のサンプルを保持して分位点を出す。フレーム数が小さいので全保持で足りる（08 §3）。
struct DurationHistogram {
    private(set) var values: [Double] = []

    init(capacity: Int = 64) { values.reserveCapacity(capacity) }

    mutating func add(_ value: Double, capacity: Int) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    func percentiles() -> DiagnosticsSummary.Percentiles {
        guard !values.isEmpty else { return .init() }
        let sorted = values.sorted()
        func at(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded(.up))))
            return sorted[idx]
        }
        return DiagnosticsSummary.Percentiles(p50: at(0.50), p95: at(0.95), max: sorted[sorted.count - 1])
    }
}
