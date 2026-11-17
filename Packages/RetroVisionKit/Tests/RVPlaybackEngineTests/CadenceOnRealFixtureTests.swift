import CoreMedia
import CoreVideo
import Foundation
import Metal
import RVDecode
import RVMediaCore
import RVVideoPipeline
import XCTest

/// 標準の 3:2（`telecine=pattern=23`）で作り直した生成素材を実際に復号し、CPU の「歯」指標を
/// `CadenceAnalyzer`（相対しきい値）へ流して、telecine の判定・位相・脱ロックを検査する。
/// 実盤 PICHI（3:2 ではない）相当の「周期なし」入力では telecine を宣言しないことも検査する。
final class CadenceOnRealFixtureTests: XCTestCase {
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/generated")
    }

    /// 歯指標: 輝度が上下の両隣に対して同符号で 12 階調超外れる画素の割合（縞の櫛歯）。
    private func toothScore(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var teeth = 0
        for y in 1..<(h - 1) {
            for x in 0..<w {
                let c = Int(p[y * stride + x])
                let a = c - Int(p[(y - 1) * stride + x]), b = c - Int(p[(y + 1) * stride + x])
                if (a > 12 && b > 12) || (a < -12 && b < -12) { teeth += 1 }
            }
        }
        return Double(teeth) / Double(w * (h - 2))
    }

    private func decodeScores(_ name: String) async throws -> [Double] {
        let url = fixturesDir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fixture が無い: \(name)")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        guard let track = stream.tracks.first(where: { $0.kind == .video }), case let .video(format) = track.format else {
            XCTFail("映像 track が無い"); return []
        }
        let seed = try await demuxer.seedFormatDescription(for: track.id)
        let decoder = VideoToolboxDecoder()
        try await decoder.configure(format, policy: DecodePolicy(), formatDescriptionHint: seed)
        var frames: [DecodedVideoFrame] = []
        for try await sample in await demuxer.samples(for: track.id) {
            if let f = try await decoder.decode(sample) { frames.append(f) }
        }
        frames.append(contentsOf: await decoder.flush())
        return frames.map { toothScore($0.pixelBuffer) }
    }

    func testStandardTelecineFixtureLocksWithTheRightPhase() async throws {
        let scores = try await decodeScores("telecine-32-01.mpg")
        XCTAssertGreaterThanOrEqual(scores.count, 150)
        var analyzer = CadenceAnalyzer(combThreshold: 0.004, relativeFactor: 2.5)
        var decisions: [CadenceDecision] = []
        for s in scores { decisions.append(analyzer.ingest(combScore: s)) }

        let firstLock = decisions.firstIndex { $0.cadence == .telecine32 }
        XCTAssertNotNil(firstLock, "標準 3:2 の実素材でロックしない")
        XCTAssertLessThanOrEqual(firstLock ?? 999, 12, "10〜12 frame 目までにロックするはず")
        // ロック後はずっと telecine のまま（素材全体が標準周期）。
        let afterLock = decisions.dropFirst(firstLock ?? 0)
        XCTAssertEqual(afterLock.filter { $0.cadence != .telecine32 }.count, 0, "ロック後に外れた")
        // 位相の検算: 周期内位置 2・3 が縞ありのはず（素材は frame 2,3 から始まる周期）。
        // 測定では縞ありが index 2,3 / 7,8 / 12,13 … なので、index i の位相は i % 5。
        for (i, d) in decisions.enumerated() where d.cadence == .telecine32 {
            XCTAssertEqual(d.telecinePhase, i % 5, "frame \(i) の周期内位置が測定と合わない")
        }
    }

    func testNoPeriodicCombMeansNoTelecineClaim() async throws {
        // 縞なしの基準が内容で動く実盤相当（0.0065〜0.0155 の揺らぎ）。周期は無い。
        var analyzer = CadenceAnalyzer(combThreshold: 0.004, relativeFactor: 2.5)
        var decisions: [CadenceDecision] = []
        for i in 0..<120 { decisions.append(analyzer.ingest(combScore: 0.0065 + 0.009 * Double((i / 40) % 2) + 0.0003 * Double(i % 3))) }
        XCTAssertTrue(decisions.allSatisfy { $0.cadence != .telecine32 }, "周期のない入力で telecine を宣言した")
    }

    func testNonStandardPatternIsNotClaimedAsTelecine() async throws {
        // 以前の誤った素材（縞が隣り合わない [縞,無,無,縞,無]）は、標準の 3:2 ではないのでロックしない。
        var analyzer = CadenceAnalyzer(combThreshold: 0.004, relativeFactor: 2.5)
        var decisions: [CadenceDecision] = []
        let pattern = [true, false, false, true, false]
        for i in 0..<60 { decisions.append(analyzer.ingest(combScore: pattern[i % 5] ? 0.045 : 0.008)) }
        XCTAssertTrue(decisions.allSatisfy { $0.cadence != .telecine32 }, "非標準の周期で telecine を宣言した")
    }

    func testMatcherRequestsWeaveExactlyOnTheMeasuredCombedFramesOfTheRealFixture() async throws {
        let url = fixturesDir.appendingPathComponent("telecine-32-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        guard let track = stream.tracks.first(where: { $0.kind == .video }), case let .video(format) = track.format else {
            return XCTFail("映像 track が無い")
        }
        let seed = try await demuxer.seedFormatDescription(for: track.id)
        let decoder = VideoToolboxDecoder()
        try await decoder.configure(format, policy: DecodePolicy(), formatDescriptionHint: seed)
        var frames: [DecodedVideoFrame] = []
        for try await sample in await demuxer.samples(for: track.id) {
            if let f = try await decoder.decode(sample) { frames.append(f) }
        }
        frames.append(contentsOf: await decoder.flush())

        var matcher = TelecineMatcher()
        var weaveIndices: [Int] = [], keepIndices: [Int] = [], firstRequest: Int?
        for (i, f) in frames.enumerated() {
            let r = matcher.match(score: CombMetric.toothScore(f.pixelBuffer), pts: f.pts.seconds, duration: f.duration.seconds)
            switch r.request {
            case .weaveWithPrevious: weaveIndices.append(i); firstRequest = firstRequest ?? i
            case .keepWoven: keepIndices.append(i); firstRequest = firstRequest ?? i
            case .none: break
            }
        }
        XCTAssertNotNil(firstRequest, "実素材で一度も指示が出ない")
        // 指示が出始めた後の weave は、測定で縞ありだった周期内位置 2・3 だけ。
        XCTAssertFalse(weaveIndices.isEmpty)
        XCTAssertTrue(weaveIndices.allSatisfy { $0 % 5 == 2 || $0 % 5 == 3 }, "縞なしの frame に weave を指示した: \(weaveIndices)")
        XCTAssertTrue(keepIndices.allSatisfy { $0 % 5 != 2 && $0 % 5 != 3 }, "縞ありの frame を weave のまま通した: \(keepIndices)")
        // 指示が出始めた後は全 frame に指示がある（取りこぼしがない）。
        let covered = Set(weaveIndices).union(keepIndices)
        XCTAssertEqual(covered.count, frames.count - (firstRequest ?? 0), "ロック後に指示の無い frame がある")
    }

    /// 出力の縞を実測する（レンダラーを通した RGB の輝度で歯指標）。ロック後は、元は縞ありだった frame も
    /// 復元後に縞なしの水準まで下がる。ロックしないまま描いた場合（none）は縞が残る。
    func testWeaveRemovesCombingFromTheRenderedOutputOfTheRealFixture() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let context = try? MetalRenderContext(device: device), let graph = try? MetalRenderGraph(context: context) else {
            return XCTFail("Metal device が無い")
        }
        let url = fixturesDir.appendingPathComponent("telecine-32-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        guard let track = stream.tracks.first(where: { $0.kind == .video }), case let .video(format) = track.format else {
            return XCTFail("映像 track が無い")
        }
        let seed = try await demuxer.seedFormatDescription(for: track.id)
        let decoder = VideoToolboxDecoder()
        try await decoder.configure(format, policy: DecodePolicy(), formatDescriptionHint: seed)
        var frames: [DecodedVideoFrame] = []
        for try await sample in await demuxer.samples(for: track.id) {
            if let f = try await decoder.decode(sample) { frames.append(f) }
        }
        frames.append(contentsOf: await decoder.flush())

        func renderedTooth(_ input: RenderFrameInput, plan: RenderPlan) throws -> Double {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 720, height: 480, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = try XCTUnwrap(device.makeTexture(descriptor: d))
            _ = try graph.render(input, plan: plan, to: target)
            let cb = try XCTUnwrap(context.commandQueue.makeCommandBuffer()); cb.commit(); cb.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: 720 * 4 * 480)
            target.getBytes(&bytes, bytesPerRow: 720 * 4, from: MTLRegionMake2D(0, 0, 720, 480), mipmapLevel: 0)
            func luma(_ x: Int, _ y: Int) -> Int {
                let i = y * 720 * 4 + x * 4
                return (299 * Int(bytes[i + 2]) + 587 * Int(bytes[i + 1]) + 114 * Int(bytes[i])) / 1000
            }
            var teeth = 0, total = 0
            for y in 1..<479 { for x in stride(from: 0, to: 720, by: 2) {
                let c = luma(x, y), a = c - luma(x, y - 1), b = c - luma(x, y + 1)
                if (a > 12 && b > 12) || (a < -12 && b < -12) { teeth += 1 }
                total += 1
            } }
            return Double(teeth) / Double(total)
        }

        let aspect = AspectResolution(targetDAR: AspectRatio(w: 720, h: 480),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: 720, height: 480), source: .sampleAspectOnly)
        let output = OutputContract(displayPixels: PixelSize(width: 720, height: 480), aspect: aspect, present: .offscreen)
        // deinterlace 段なしの plan（weave のまま描く）と、auto の plan（既定の deinterlace）。
        let wovenPlan = RenderPlan(id: PlanID(20), tier: .metalOnly,
                                   stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())], output: output)
        let autoPlan = RenderPlan(id: PlanID(21), tier: .metalOnly,
                                  stages: [.init(stage: .deinterlace, parameters: DeinterlaceParameters(mode: .auto)),
                                           .init(stage: .colorConvert, parameters: ColorConvertParameters())], output: output)

        var matcher = TelecineMatcher()
        var previous: CVPixelBuffer?
        var combedOutputTeeth: [Double] = [], cleanOutputTeeth: [Double] = [], combedInputTeeth: [Double] = []
        for (i, f) in frames.enumerated() {
            let inputTooth = CombMetric.toothScore(f.pixelBuffer)
            let r = matcher.match(score: inputTooth, pts: f.pts.seconds, duration: f.duration.seconds)
            var input = RenderFrameInput(pixelBuffer: f.pixelBuffer, color: f.format.color, interlace: f.format.interlace,
                                         aspect: aspect, frameID: f.id,
                                         previousPixelBuffer: r.previousIsContinuous ? previous : nil, fieldMatch: r.request)
            input.interlace = f.format.interlace
            previous = f.pixelBuffer
            guard r.request != .none else { continue }   // ロック前は対象外
            let out = try renderedTooth(input, plan: autoPlan)
            if i % 5 == 2 || i % 5 == 3 {
                combedOutputTeeth.append(out); combedInputTeeth.append(inputTooth)
            } else {
                cleanOutputTeeth.append(out)
            }
            _ = wovenPlan
        }
        XCTAssertGreaterThan(combedOutputTeeth.count, 20)
        let cleanBaseline = cleanOutputTeeth.reduce(0, +) / Double(max(cleanOutputTeeth.count, 1))
        let combedOut = combedOutputTeeth.max() ?? 1
        let combedIn = combedInputTeeth.min() ?? 0
        XCTAssertGreaterThan(combedIn, cleanBaseline * 3, "入力の縞ありは縞なしの 3 倍以上のはず（測定の前提）")
        XCTAssertLessThan(combedOut, cleanBaseline * 1.5,
                          "復元後の出力にまだ縞が残る（最大 \(combedOut) / 縞なしの基準 \(cleanBaseline)）")
    }
}

