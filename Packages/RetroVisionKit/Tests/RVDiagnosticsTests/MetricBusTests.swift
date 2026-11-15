import Foundation
import XCTest
@testable import RVDiagnostics
@testable import RVMediaCore

final class MetricBusTests: XCTestCase {
    private func makeBus() -> (MetricBus, DeterministicTimeSource) {
        let clock = DeterministicTimeSource(startMS: 0)
        return (MetricBus(config: .init(windowMS: 2_000), time: clock), clock)
    }

    private func sample(stage: StageID, ms: Double, start: HostTime, clock: DeterministicTimeSource) -> MetricStageSample {
        let end = clock.now()
        _ = start
        return MetricStageSample(stage: stage, frameID: FrameID(1),
                                start: end, end: end,
                                gpuDurationMS: ms)
    }

    func testPercentilesAreComputedPerStage() async {
        let (bus, clock) = makeBus()
        for ms in [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 40.0] {
            await bus.record(sample(stage: .videoDecode, ms: ms, start: clock.now(), clock: clock))
        }
        let summary = await bus.flush(force: true)
        XCTAssertNotNil(summary)
        let p = summary!.stageDurations[.videoDecode]
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.max, 40.0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(p!.p95, 12.0)
    }

    func testDropReasonsAreCounted() async {
        let (bus, _) = makeBus()
        await bus.recordFrameDropped(reason: .late)
        await bus.recordFrameDropped(reason: .enhancementNotReady)
        await bus.recordFramePresented(frameID: FrameID(2))
        let summary = await bus.flush(force: true)!
        XCTAssertEqual(summary.frames.total, 3)
        XCTAssertEqual(summary.frames.dropped, 2)
        XCTAssertEqual(summary.frames.enhancementSkipped, 1)
        XCTAssertEqual(summary.frames.dropReasons[.late], 1)
        XCTAssertEqual(summary.frames.deadlineMissRatio, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testWindowRollsOverAutomatically() async {
        let (bus, clock) = makeBus()
        await bus.record(sample(stage: .present, ms: 1, start: clock.now(), clock: clock))
        await clock.advance(ms: 1_000)
        let midFlush = await bus.flush()          // 窓前。まだ出さない
        XCTAssertNil(midFlush)
        await clock.advance(ms: 1_500)
        let summary = await bus.flush()            // 2 s を超えたので出る
        XCTAssertNotNil(summary)
        XCTAssertNotNil(summary!.stageDurations[.present])
    }

    func testJSONLWriterProducesParseableLines() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("metrics-\(UUID().uuidString).jsonl")
        let writer = MetricsJSONLWriter(url: url)
        var summary = DiagnosticsSummary()
        summary.stageDurations[.videoDecode] = .init(p50: 2, p95: 4, max: 9)
        summary.endToEnd = .init(p50: 11, p95: 17, max: 24)
        try writer.append(MetricsLine(timestamp: HostTime(machTime: 1), summary: summary, tier: .lightML))
        try writer.append(MetricsLine(timestamp: HostTime(machTime: 2), summary: summary, tier: .metalOnly))
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoder = JSONDecoder()
        let first = try decoder.decode(MetricsLine.self, from: Data(String(lines[0]).utf8))
        XCTAssertEqual(first.tier, "lightML")
        XCTAssertEqual(first.stages.first?.stage, "videoDecode")
        try? FileManager.default.removeItem(at: url)
    }

    func testBenchmarkReportKeepsNullsForUnrunMetrics() throws {
        var report = BenchmarkReport(
            run: .init(id: "r1", gitRev: "abc", appVersion: "0.1.0",
                       machine: .init(model: "Mac17,14", chip: "M5 Max", memoryGB: 64, os: "27.2.1"),
                       display: .init(refreshHzMeasured: 59.94, pixels: "3840x2160")),
            input: .init(fixtureID: "ntsc480i-mixed-01", sha256: "x", resolution: "720x480",
                         cadence: "interlaced22", durationS: 60, frames: 1798),
            pipeline: .init(tier: "fullML", planHash: "fnv1a64-0000000000000000",
                            stages: ["deinterlace", "superResolution"]),
            budget: .init(decode: 6, deinterlace: 3, inference: 18, post: 2, present: 1.5, headroom: 3),
            results: .init(fpsTarget: 29.97, fpsMeasured: 29.97, endToEnd: .init(p50: 11, p95: 17, max: 24),
                           deadlineMissPct: 0.2, dropped: 1, jitterMS: 0.8,
                           drift: .init(p50: 0.4, p95: 3, max: 6), perStage: [:]),
            quality: .init())
        report.comparison = .init(baselineRunID: "r0", diff: ["endToEndP95MS": -2.1])
        let data = try report.encoded(pretty: false)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"psnr\":null"))
        XCTAssertTrue(json.contains("\"planHash\":\"fnv1a64-0000000000000000\""))
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: data)
        XCTAssertNil(decoded.quality.vmaf)
        XCTAssertEqual(decoded.comparison?.baselineRunID, "r0")
    }
}
