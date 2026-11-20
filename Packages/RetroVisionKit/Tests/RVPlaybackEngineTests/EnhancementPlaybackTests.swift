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
/// 入力をそのまま返す実行層（推論時間ほぼ 0。session の先読みが実際に効くかだけを見る）。
private actor ImmediateRuntime: ModelRuntimeProtocol {
    func discover() async -> [ModelManifest] { [] }
    func load(_ id: ModelID) async throws {}
    func unload(_ id: ModelID) async {}
    func predict(_ request: InferenceRequest, input: InferenceFrame) async throws -> InferenceFrame { input }
    func predictTensor(_ request: InferenceRequest, input: TensorFrame) async throws -> TensorFrame { input }
    func health(of id: ModelID) async -> ModelHealth { ModelHealth() }
}

/// 推論の完了をテストが決める実行層（sleep に頼らず、先読みのタイミングを決定的にする）。
private actor GatedRuntime: ModelRuntimeProtocol {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func discover() async -> [ModelManifest] { [] }
    func load(_ id: ModelID) async throws {}
    func unload(_ id: ModelID) async {}
    func predict(_ request: InferenceRequest, input: InferenceFrame) async throws -> InferenceFrame {
        started += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
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

    private func makeFrame(size: Int, index: Int = 0) throws -> DecodedVideoFrame {
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
        return DecodedVideoFrame.make(id: FrameID(UInt64(index + 1)), pixelBuffer: buffer, format: format,
                                      pts: CMTime(value: CMTimeValue(index) * 1001, timescale: 30_000),
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

    private func makePresenter(runtime: any ModelRuntimeProtocol, size: Int,
                               scheduling: MetalFramePresenter.Scheduling = .init(),
                               clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) throws -> MetalFramePresenter {
        let presenter = try XCTUnwrap(MetalFramePresenter(scheduling: scheduling, clock: clock))
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

    /// 先読みで推論を済ませた frame は、提示のときに強調して出る。
    func testEnhancedFramesAreDeliveredThroughTheAIStage() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let frame = try makeFrame(size: 64), p = plan(size: 64, withSR: true)
        presenter.prepare(frame, plan: p)
        await presenter.waitUntilIdle()
        let outcome = await presenter.present(frame, plan: p)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(presenter.statistics.enhanced, 1, "AI 段を通して提示されていない: \(presenter.statistics)")
        XCTAssertEqual(presenter.statistics.fellBack, 0)
    }

    func testTheSameFrameWithoutASuperResolutionStageIsNotEnhanced() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        for (i, p) in [plan(size: 64, withSR: true, tier: .metalOnly), plan(size: 64, withSR: false)].enumerated() {
            let frame = try makeFrame(size: 64, index: i)
            presenter.prepare(frame, plan: p)
            await presenter.waitUntilIdle()
            let outcome = await presenter.present(frame, plan: p)
            XCTAssertEqual(outcome, .delivered)
        }
        XCTAssertEqual(presenter.statistics.enhanced, 0, "tier が足りない / SR 段が無いのに強調した")
        XCTAssertEqual(presenter.statistics.eligible, 0, "強調の対象でない frame を数えた")
    }

    func testAFailingModelFallsBackToAnUnenhancedFrameAndNeverDropsIt() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        // load していない → 推論は失敗する。frame は捨てず、非強調で提示される。
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let frame = try makeFrame(size: 64), p = plan(size: 64, withSR: true)
        presenter.prepare(frame, plan: p)
        await presenter.waitUntilIdle()
        let outcome = await presenter.present(frame, plan: p)
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
        let frame = try makeFrame(size: 64), p = plan(size: 64, withSR: true)
        presenter.prepare(frame, plan: p)
        await presenter.waitUntilIdle()
        let outcome = await presenter.present(frame, plan: p)
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(presenter.statistics.fellBack, 1, "期限切れの結果を使った")
        XCTAssertNotNil(presenter.statistics.lastError)
    }

    // MARK: 先読み（設計 11 §6・P4）

    /// 推論が終わっていなくても、提示は待たずに非強調で出す。
    func testPresentDoesNotWaitForAPendingInference() async throws {
        let runtime = GatedRuntime()
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let frame = try makeFrame(size: 64), p = plan(size: 64, withSR: true)
        presenter.prepare(frame, plan: p)
        let started = Date()
        let outcome = await presenter.present(frame, plan: p)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "推論の完了を待った")
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(presenter.statistics.notReady, 1)
        XCTAssertEqual(presenter.statistics.enhanced, 0)
        await runtime.release()
        await presenter.waitUntilIdle()
    }

    /// 同時に走る推論は上限（2）まで。超えた分は待ち行列に入り、枠が空いたら走る（復号は数 frame まとめて進むため）。
    func testJobsOverTheCapWaitAndRunWhenASlotFrees() async throws {
        let runtime = GatedRuntime()
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let p = plan(size: 64, withSR: true)
        let frames = try (0..<3).map { try makeFrame(size: 64, index: $0) }
        frames.forEach { presenter.prepare($0, plan: p) }
        await presenter.waitUntilIdle(timeout: 0.3)   // 2 本は門で止まっている
        let started = await runtime.started
        XCTAssertEqual(started, 2, "上限を超えて推論を始めた")
        await runtime.release()
        await presenter.waitUntilIdle()
        for f in frames { _ = await presenter.present(f, plan: p) }
        let s = presenter.statistics
        XCTAssertEqual(s.enhanced, 3, "待ち行列の推論が走っていない: \(s)")
        XCTAssertEqual(s.eligible, 3, "提示した frame = 強調 + 非強調（理由別）の保存則: \(s)")
    }

    /// 待ち行列も一杯なら、推論を始めずに非強調で出す（skippedBusy）。
    func testFramesBeyondTheQueueAreSkippedAsBusy() async throws {
        var scheduling = MetalFramePresenter.Scheduling()
        scheduling.maxPendingJobs = 0
        let runtime = GatedRuntime()
        let presenter = try makePresenter(runtime: runtime, size: 64, scheduling: scheduling)
        let p = plan(size: 64, withSR: true)
        let frames = try (0..<3).map { try makeFrame(size: 64, index: $0) }
        frames.forEach { presenter.prepare($0, plan: p) }
        await presenter.waitUntilIdle(timeout: 0.3)
        await runtime.release()
        await presenter.waitUntilIdle()
        for f in frames { _ = await presenter.present(f, plan: p) }
        let s = presenter.statistics
        XCTAssertEqual(s.enhanced, 2)
        XCTAssertEqual(s.skippedBusy, 1)
        XCTAssertEqual(s.eligible, 3, "保存則: \(s)")
    }

    /// シーク等で世代が進んだら、古い世代の結果は使わない。
    func testAResultFromAnOlderGenerationIsNotUsed() async throws {
        let runtime = GatedRuntime()
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let frame = try makeFrame(size: 64), p = plan(size: 64, withSR: true)
        presenter.prepare(frame, plan: p)
        await presenter.waitUntilIdle(timeout: 0.2)
        presenter.flush()
        await runtime.release()
        await presenter.waitUntilIdle()
        _ = await presenter.present(frame, plan: p)
        XCTAssertEqual(presenter.statistics.enhanced, 0, "シーク前の結果を出した")
        XCTAssertEqual(presenter.statistics.notPrepared, 1)
    }

    /// 先読みの後に plan が替わったら（AI の設定変更など）、古い plan の結果は使わない（INV-3）。
    func testAResultForADifferentPlanIsNotUsed() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let frame = try makeFrame(size: 64)
        presenter.prepare(frame, plan: plan(size: 64, withSR: true))
        await presenter.waitUntilIdle()
        var other = plan(size: 64, withSR: true)
        other = RenderPlan(id: PlanID(2), tier: .fullML, stages: other.stages, output: other.output)   // tier が違う → planHash が違う
        _ = await presenter.present(frame, plan: other)
        XCTAssertEqual(presenter.statistics.enhanced, 0, "替わる前の plan の結果を出した")
    }

    /// 起動直後（まだ 1 枚も強調していない）の取りこぼしでは、強調を止めない。
    func testStartupMissesDoNotSuspendEnhancement() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        var scheduling = MetalFramePresenter.Scheduling()
        scheduling.minSamples = 3
        let presenter = try makePresenter(runtime: runtime, size: 64, scheduling: scheduling)
        presenter.enhancementBudgetMS = -1_000   // どの推論も期限切れ（取りこぼし）
        let p = plan(size: 64, withSR: true)
        for i in 0..<10 {
            let f = try makeFrame(size: 64, index: i)
            presenter.prepare(f, plan: p)
            await presenter.waitUntilIdle()
            _ = await presenter.present(f, plan: p)
        }
        XCTAssertEqual(presenter.statistics.suspensions, 0)
        XCTAssertEqual(presenter.statistics.fellBack, 10)
    }

    /// 強調が始まった後に取りこぼしが続くと、強調を止める。止めている間は推論を始めない。
    func testRepeatedMissesAfterTheFirstHitSuspendEnhancement() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        var scheduling = MetalFramePresenter.Scheduling()
        scheduling.minSamples = 3
        scheduling.suspendSeconds = 1_000
        let presenter = try makePresenter(runtime: runtime, size: 64, scheduling: scheduling, clock: { 100 })
        let p = plan(size: 64, withSR: true)
        func run(_ i: Int) async throws {
            let f = try makeFrame(size: 64, index: i)
            presenter.prepare(f, plan: p)
            await presenter.waitUntilIdle()
            _ = await presenter.present(f, plan: p)
        }
        try await run(0)                                    // 強調（ここから数える）
        presenter.enhancementBudgetMS = -1_000
        for i in 1...2 { try await run(i) }                 // 期限切れの取りこぼし → 3 サンプル中 2 → 停止
        XCTAssertEqual(presenter.statistics.suspensions, 1)
        presenter.enhancementBudgetMS = nil
        try await run(10)
        XCTAssertEqual(presenter.statistics.suspended, 1, "止めている間に推論した")
        XCTAssertEqual(presenter.statistics.enhanced, 1)
    }

    /// 一時停止中の期限なし強調は描き直す。ただし、その間に次の frame が提示されたら結果を使わない。
    func testRefineRedrawsTheLastFrameUnlessANewerFrameWasPresented() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let presenter = try makePresenter(runtime: runtime, size: 64)
        let p = plan(size: 64, withSR: true)
        _ = await presenter.present(try makeFrame(size: 64, index: 0), plan: p)
        let refined = await presenter.refineLastFrame()
        XCTAssertTrue(refined)
        XCTAssertEqual(presenter.statistics.refined, 1)

        let gated = GatedRuntime()
        let presenter2 = try makePresenter(runtime: gated, size: 64)
        _ = await presenter2.present(try makeFrame(size: 64, index: 0), plan: p)
        async let pending = presenter2.refineLastFrame()
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await presenter2.present(try makeFrame(size: 64, index: 1), plan: p)   // 再生が進んだ
        await gated.release()
        let stale = await pending
        XCTAssertFalse(stale, "新しい frame の後に古い frame の強調を出した")
        XCTAssertEqual(presenter2.statistics.refined, 0)
    }

    // MARK: 実際の再生（session の先読み → presenter）

    /// 実ファイルを再生し、session の復号の先読み（maxQueuedFrames = 4）で推論が提示に間に合うこと。
    /// 推論はほぼ 0 秒の偽物なので、強調されないなら先読みの配線か橋渡しの処理が間に合っていない。
    @MainActor
    private func playWithInstantModel(io: ModelManifest.TensorSpec.Kind) async throws -> MetalFramePresenter.EnhancementStatistics {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/generated/ntsc480i-22-01.mpg")
        let core = EngineCore()
        let engine = DefaultPlayerEngine(core: core)
        let attachedSurface = await engine.attachMetalSurface(layer: try makeLayer(size: 720), onAspectResolved: { _ in })
        XCTAssertTrue(attachedSurface)
        var m = try manifest()
        m.input.kind = io; m.output.kind = io
        m.input.width = 704; m.input.height = 480; m.output.width = 704; m.output.height = 480; m.scaleFactor = 1
        m.constraints.enumeratedSizes = [.init(width: 704, height: 480), .init(width: 720, height: 480)]
        let attached = await engine.attachEnhancement(runtime: ImmediateRuntime(), model: m)
        XCTAssertTrue(attached)
        _ = try await engine.load(FileMediaSource(url: url), selection: nil)
        var raised = AdaptivePolicyEngine.State()
        raised.requestedTier = .lightML; raised.activeTier = .lightML
        await core.seedAdaptiveState(raised)
        // tier を上げた状態で plan を作り直させる（apply が plan を作り直す。seed だけでは作り直さない）。
        await core.apply(PlayerSettings(enhancement: .presetConservative))
        await engine.play()
        for _ in 0..<200 where engine.stateSnapshot.phase != .ended { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(engine.stateSnapshot.phase, .ended)
        return try XCTUnwrap(engine.enhancementStatistics())
    }

    /// 16 bit テンソル経路（GPU）なら、先読みで大半の frame が強調されて提示される。
    @MainActor
    func testRealPlaybackEnhancesFramesThroughTheSessionLookahead() async throws {
        let s = try await playWithInstantModel(io: .tensor)
        print("SESSION-LOOKAHEAD tensor:", s)
        XCTAssertGreaterThan(s.enhanced, s.eligible / 2, "先読みで強調が間に合っていない: \(s)")
        XCTAssertEqual(s.suspensions, 0, "偽の即時推論で強調を止めた: \(s)")
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
