import CoreMedia
import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources

// MARK: - 適応制御（08 §4、§5）

final class AdaptivePolicyTests: XCTestCase {
    private func signals(missRatio: Double, endToEndP95: Double,
                        thermal: ThermalState = .nominal,
                        memory: ControlSignals.MemoryPressureLevel = .normal,
                        breaker: Bool = false, jitter: Double = 0) -> ControlSignals {
        var frames = FrameStats(total: 60, presented: 60)
        let dropped = Int((Double(frames.total) * missRatio).rounded())
        frames.dropped = dropped
        frames.presented = frames.total - dropped
        var summary = DiagnosticsSummary()
        summary.frames = frames
        summary.endToEnd = .init(p50: endToEndP95 * 0.6, p95: endToEndP95, max: endToEndP95)
        return ControlSignals(summary: summary, thermal: thermal, memoryPressureLevel: memory,
                              modelBreakerOpen: breaker, presentJitterMS: jitter)
    }

    /// 期限超過が高いとき、影響の小さい順に 1 つだけ適用する（08 §5）。
    func testDegradeAppliesSoftActionsInOrder() {
        var engine = AdaptivePolicyEngine()
        engine.state.activeTier = .fullML
        engine.state.requestedTier = .fullML
        var observed: [[ControlAction]] = []
        for i in 0..<7 {
            observed.append(engine.evaluate(signals: signals(missRatio: 0.2, endToEndP95: 30),
                                           atMS: Double(i) * 2_000))
        }
        XCTAssertEqual(observed[0], [.bypassStage(.sharpen)])
        XCTAssertEqual(observed[1], [.disableTemporalBlend])
        XCTAssertEqual(observed[2], [.useLighterModelVariant])
        XCTAssertEqual(observed[3], [.reduceInferenceScale(0.75)])
        XCTAssertEqual(observed[4], [.enhanceEveryNFrames(2)])
        XCTAssertTrue(observed[5].contains(.setTier(.lightML)), "soft action が尽きたら tier を 1 段下げる")
        XCTAssertTrue(observed[6].contains(.setTier(.metalOnly)))
    }

    /// 昇格は 2 個の clean window + 降格から 10 s 経過でのみ、1 窓に 1 action（08 §5）。
    func testUpgradeRequiresCleanWindowsAndCooldown() {
        var engine = AdaptivePolicyEngine()
        engine.state.activeTier = .fullML
        engine.state.requestedTier = .fullML
        _ = engine.evaluate(signals: signals(missRatio: 0.3, endToEndP95: 40), atMS: 0)
        _ = engine.evaluate(signals: signals(missRatio: 0.3, endToEndP95: 40), atMS: 2_000)

        // クールダウン中は昇格しない。
        XCTAssertEqual(engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1), atMS: 4_000), [])
        XCTAssertEqual(engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1), atMS: 6_000), [])
        // 10 s を超えて clean window が 2 個たまったら、降格の逆順で 1 つだけ戻す。
        let actions = engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1), atMS: 14_000)
        XCTAssertEqual(actions.count, 1)
    }

    func testThermalCriticalCapsTier() {
        var engine = AdaptivePolicyEngine()
        engine.state.activeTier = .fullML
        engine.state.requestedTier = .fullML
        let actions = engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1, thermal: .critical),
                                     atMS: 1_000)
        XCTAssertEqual(actions, [.setTier(.metalOnly)])
        XCTAssertEqual(engine.state.activeTier, .metalOnly)
    }

    func testBreakerOpenCapsTierAndHolds() {
        var engine = AdaptivePolicyEngine()
        engine.state.activeTier = .fullML
        engine.state.requestedTier = .fullML
        _ = engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1, breaker: true), atMS: 0)
        XCTAssertEqual(engine.state.activeTier, .metalOnly)
        // breaker が開いている間、clean window が溜まっても fullML には戻らない。
        for i in 0..<10 {
            _ = engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1, breaker: true),
                                atMS: Double(i) * 2_000 + 2_000)
        }
        XCTAssertLessThanOrEqual(engine.state.activeTier, .metalOnly)
    }

    func testJitterReducesInFlightLimit() {
        var engine = AdaptivePolicyEngine()
        engine.state.requestedTier = .lightML
        engine.state.activeTier = .lightML
        let actions = engine.evaluate(signals: signals(missRatio: 0, endToEndP95: 1, jitter: 12), atMS: 0)
        XCTAssertTrue(actions.contains(.setInFlightLimit(1)))
    }
}

// MARK: - EngineCore の状態機械と plan 生成（02 §3、INV-2、INV-3、INV-6）

final class EngineCoreTests: XCTestCase {
    func testLoadThenPlayReachesPlayingPhase() async throws {
        let engine = EngineCore()
        try await engine.load(TestSource(), selection: PlaybackSelection(item: ItemID(1)))
        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertFalse(snapshot.available.isEmpty)

        await engine.play()
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .playing)

        await engine.pause()
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .paused)
    }

    func testLoadFailureSurfacesRecoverableError() async {
        let engine = EngineCore()
        do {
            try await engine.load(FailingSource(), selection: PlaybackSelection(item: ItemID(1)))
            XCTFail("失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .source(.protectedNeedsLicense))
            XCTAssertEqual(error.recovery, .needsUserAction(.contactVendorAboutLicense))
        } catch {
            XCTFail("PlaybackError がexpected: \(error)")
        }
        let snapshot = await engine.snapshot()
        if case .failed = snapshot.phase {} else { XCTFail("failed phase が無い: \(snapshot.phase)") }
    }

    /// INV-2: ユーザーが tier を off にすると、SR 段が消える。
    func testPolicyOffRemovesEnhancementStages() async throws {
        let engine = EngineCore()
        try await engine.load(TestSource(), selection: PlaybackSelection(item: ItemID(1)))
        await engine.apply(PlayerSettings(enhancement: .presetMaximum))
        await engine.play()
        let plan = await engine.currentPlan()
        XCTAssertNotNil(plan)
        XCTAssertFalse(plan!.stages.contains { $0.stage == .superResolution },
                       "モデル manifest がない限り SR 段は入らない（06 §2）")

        await engine.apply(PlayerSettings(enhancement: .presetOff))
        await engine.play()
        let offPlan = await engine.currentPlan()
        XCTAssertNotNil(offPlan)
        XCTAssertFalse(offPlan!.stages.contains { $0.stage == .superResolution })
    }

    /// INV-3: 設定変更で active plan はその場で差し替わらない（pending に入り、境界で切り替わる）。
    func testSettingsChangeDoesNotSwapActivePlanImmediately() async throws {
        let engine = EngineCore()
        try await engine.load(TestSource(), selection: PlaybackSelection(item: ItemID(1)))
        await engine.play()
        let before = await engine.currentPlan()?.id
        await engine.apply(PlayerSettings(enhancement: .presetMaximum))
        let after = await engine.currentPlan()?.id
        XCTAssertEqual(before, after)
    }

    /// 比率を解決できない場合は、回復方針付きで失敗する（05 §6）。
    func testAspectUnresolvedProducesRecoverableError() async throws {
        let engine = EngineCore()
        do {
            try await engine.load(TestSource(hasAspectSignals: false),
                                  selection: PlaybackSelection(item: ItemID(1)))
            XCTFail("比率を解決できない場合は失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.recovery, .needsUserAction(.chooseAspect))
        }
        let snapshot = await engine.snapshot()
        if case .failed = snapshot.phase {} else { XCTFail("failed phase が無い") }
    }
}

/// テスト用のソース。VIDEO_TS 相当の構造をメモリ上に作る（09 §3）。
struct TestSource: MediaSource {
    let hasAspectSignals: Bool
    init(hasAspectSignals: Bool = true) { self.hasAspectSignals = hasAspectSignals }

    var descriptor: SourceDescriptor {
        SourceDescriptor(id: SourceID(1), kind: .videoTsFolder, displayName: "test",
                         location: .fileURL(URL(fileURLWithPath: "/tmp/test")))
    }

    func open() async throws -> OpenedSource {
        var signals = AspectSignals()
        if hasAspectSignals {
            signals = AspectSignals(dvdAspectFlag: .allowed4x3, sampleAspectFromStandard: .bt601NTSCSample)
        }
        let video = VideoFormatDescription(codedSize: PixelSize(width: 720, height: 480),
                                          sampleAspect: hasAspectSignals ? .bt601NTSCSample : nil,
                                          frameRate: .ntsc,
                                          interlace: .ntscInterlaced,
                                          aspectSignals: signals)
        let item = MediaItem(id: ItemID(1), titleNumber: 1,
                             duration: CMTime(value: 60, timescale: 1),
                             trackTable: [TrackInfo(id: TrackID(1), kind: .video, format: .video(video))],
                             videoFormat: video,
                             chapters: [ChapterMark(index: 0, start: .zero)],
                             aspectFlag: hasAspectSignals ? .allowed4x3 : nil)
        let structure = MediaStructure(itemKind: .dvdTitles, items: [item])
        return OpenedSource(reader: MemoryBlockReader(bytes: Data(count: 2_048 * 8)),
                            structure: structure,
                            formatHint: .mpegProgramStream)
    }
}

/// 保護 Disc を表すテスト用ソース。ライセンス未確認で開けないケース（03 §7）。
struct FailingSource: MediaSource {
    var descriptor: SourceDescriptor {
        SourceDescriptor(id: SourceID(2), kind: .opticalDisc, displayName: "protected",
                         location: .blockDevice(path: "/dev/disk4"), protectionHint: .protectedCSS)
    }

    func open() async throws -> OpenedSource {
        throw PlaybackError(kind: .source(.protectedNeedsLicense),
                            recovery: .needsUserAction(.contactVendorAboutLicense),
                            userMessage: "この盤は保護されており、再生ライセンスの確認が完了していません")
    }
}
