import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import XCTest
@testable import RVPlaybackEngine
import RVEnhancement
import RVMediaCore
import RVMediaSources
import RVMLRuntime
import RVVideoPipeline

/// AI 段の再生経路への組み込み（#6 / #7）。実際の Metal + Core ML（tiny model）で、plan への反映・
/// 強調して提示・失敗時に非強調で提示・同時に 1 推論だけ、を検査する。
private actor SlowRuntime: ModelRuntimeProtocol {
    func discover() async -> [ModelManifest] { [] }
    func load(_ id: ModelID) async throws {}
    func unload(_ id: ModelID) async {}
    func predict(_ request: InferenceRequest, input: InferenceFrame) async throws -> InferenceFrame {
        try? await Task.sleep(nanoseconds: 250_000_000)   // 遅い推論（busy 判定を決定的にする）
        return input
    }
    func health(of id: ModelID) async -> ModelHealth { ModelHealth() }
}

final class EnhancementPlaybackTests: XCTestCase {
    private var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RVMLRuntimeTests/Models")
    }
    private let modelID = ModelID("test.tiny.invert@1")

    /// tiny model の manifest に、plan が選べる条件（種類 superResolution・計測記録あり）をテスト内で足す。
    private func manifest() throws -> ModelManifest {
        let data = try Data(contentsOf: modelsDirectory.appendingPathComponent("tiny-invert-v1/model.json"))
        var m = try JSONDecoder().decode(ModelManifest.self, from: data)
        m.task = .superResolution
        m.measuredOn = ModelManifest.Measurement(device: "test", os: "test", date: "2026-11-17")
        return m
    }

    private func makeLayer(size: Int) throws -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: size, height: size)
        return layer
    }

    private func makeFrame(size: Int) throws -> DecodedVideoFrame {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, plane == 0 ? 120 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format = VideoFormatDescription(codedSize: PixelSize(width: Int32(size), height: Int32(size)))
        format.sampleAspect = AspectRatio(w: 1, h: 1)
        return DecodedVideoFrame.make(id: FrameID(1), pixelBuffer: buffer, format: format,
                                      pts: CMTime(seconds: 0, preferredTimescale: 600),
                                      duration: CMTime(seconds: 1.0 / 29.97, preferredTimescale: 30_000), isKey: true)
    }

    private func plan(size: Int, withSR: Bool, tier: QualityTier = .lightML) -> RenderPlan {
        let aspect = AspectResolution(targetDAR: AspectRatio(w: Int32(size), h: Int32(size)),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: Int32(size), height: Int32(size)),
                                      source: .sampleAspectOnly)
        var stages: [StageRequest] = [.init(stage: .colorConvert, parameters: ColorConvertParameters())]
        if withSR { stages.append(.init(stage: .superResolution, parameters: SuperResolutionParameters(model: modelID))) }
        return RenderPlan(id: PlanID(1), tier: tier, stages: stages,
                          output: OutputContract(displayPixels: PixelSize(width: Int32(size), height: Int32(size)), aspect: aspect))
    }

    private func makePresenter(runtime: any ModelRuntimeProtocol, size: Int) throws -> MetalFramePresenter {
        let presenter = try XCTUnwrap(MetalFramePresenter())
        presenter.attachLayer(try makeLayer(size: size))
        presenter.setEnhancement(runtime: runtime, model: modelID,
                                 tiling: .init(tileWidth: 32, tileHeight: 32, overlap: 8))
        return presenter
    }

    // MARK: plan への反映（エンジン）

    func testPlanGainsTheSuperResolutionStageOnlyWhileARuntimeIsAttachedAndTheTierAllows() async throws {
        let core = EngineCore()
        try await core.load(TestSource(), selection: PlaybackSelection(item: ItemID(1)))
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let m = try manifest()

        await core.apply(PlayerSettings(enhancement: .presetConservative))
        var raised = AdaptivePolicyEngine.State()
        raised.requestedTier = .lightML; raised.activeTier = .lightML
        await core.seedAdaptiveState(raised)
        await core.play()
        let withoutRuntime = await core.currentPlan()
        XCTAssertFalse(withoutRuntime?.stages.contains { $0.stage == .superResolution } ?? true, "実行層が無いのに SR 段が入った")

        await core.setModelRuntime(runtime, models: [m.modelID], manifests: [m])
        await core.pause()
        await core.play()
        let withRuntime = await core.currentPlan()
        let sr = withRuntime?.stages.first { $0.stage == .superResolution }?.parameters as? SuperResolutionParameters
        XCTAssertEqual(sr?.model, m.modelID, "実行層を接続し tier が許すのに SR 段が plan に入らない")

        await core.setModelRuntime(nil)
        await core.pause()
        await core.play()
        let detached = await core.currentPlan()
        XCTAssertFalse(detached?.stages.contains { $0.stage == .superResolution } ?? true, "切り離した後も SR 段が残った")
    }

    // MARK: 提示（presenter）

    func testEnhancedFramesAreDeliveredThroughTheAIStage() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let outcome = await presenter.present(try makeFrame(size: 64), plan: plan(size: 64, withSR: true))
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(presenter.statistics.enhanced, 1, "AI 段を通して提示されていない: \(presenter.statistics)")
        XCTAssertEqual(presenter.statistics.fellBack, 0)
    }

    func testTheSameFrameWithoutASuperResolutionStageIsNotEnhanced() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let belowTier = await presenter.present(try makeFrame(size: 64), plan: plan(size: 64, withSR: true, tier: .metalOnly))
        let noStage = await presenter.present(try makeFrame(size: 64), plan: plan(size: 64, withSR: false))
        XCTAssertEqual(belowTier, .delivered)
        XCTAssertEqual(noStage, .delivered)
        XCTAssertEqual(presenter.statistics.enhanced, 0, "tier が足りない / SR 段が無いのに強調した")
    }

    func testAFailingModelFallsBackToAnUnenhancedFrameAndNeverDropsIt() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        // load していない → 推論は失敗する。frame は捨てず、非強調で提示される。
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let outcome = await presenter.present(try makeFrame(size: 64), plan: plan(size: 64, withSR: true))
        XCTAssertEqual(outcome, .delivered, "AI 段の失敗で frame を落とした（非強調で出すはず）")
        XCTAssertEqual(presenter.statistics.fellBack, 1)
        XCTAssertEqual(presenter.statistics.enhanced, 0)
        XCTAssertNotNil(presenter.statistics.lastError)
    }

    func testAMissedDeadlineDiscardsTheResultAndPresentsUnenhanced() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        presenter.enhancementBudgetMS = -1_000   // 期限は過去（必ず間に合わない）
        let outcome = await presenter.present(try makeFrame(size: 64), plan: plan(size: 64, withSR: true))
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(presenter.statistics.fellBack, 1, "期限切れの結果を使った")
        print("LASTERROR:", presenter.statistics.lastError ?? "nil")
        XCTAssertNotNil(presenter.statistics.lastError)
    }

    func testOnlyOneInferenceRunsAtATimeAndOtherFramesAreNotMadeToWait() async throws {
        let presenter = try makePresenter(runtime: SlowRuntime(), size: 64)
        let frame = try makeFrame(size: 64), p = plan(size: 64, withSR: true)
        let started = Date()
        async let first = presenter.present(frame, plan: p)          // 推論が 250 ms かかる
        try await Task.sleep(nanoseconds: 60_000_000)
        let second = await presenter.present(frame, plan: p)         // 実行中なので待たずに非強調で提示
        let secondElapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(second, .delivered)
        XCTAssertLessThan(secondElapsed, 0.2, "推論の完了を待ってしまった（\(secondElapsed) s）")
        XCTAssertEqual(presenter.statistics.skippedBusy, 1)
        let firstResult = await first
        XCTAssertEqual(firstResult, .delivered)
        XCTAssertEqual(presenter.statistics.enhanced, 1)
    }

    // MARK: エンジンの公開 API

    @MainActor
    func testAttachEnhancementReturnsFalseWhenTheModelCannotBeLoaded() async throws {
        let engine = DefaultPlayerEngine()
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-no-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let runtime = CoreMLModelRuntime(modelsDirectory: emptyDir, options: .init(requireMeasurement: false))
        let attached = await engine.attachEnhancement(runtime: runtime, model: try manifest())
        XCTAssertFalse(attached, "load できないモデルで AI 段が有効になった")
        let ok = await engine.attachEnhancement(
            runtime: CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false)),
            model: try manifest())
        XCTAssertTrue(ok)
        await engine.detachEnhancement()
    }
}
