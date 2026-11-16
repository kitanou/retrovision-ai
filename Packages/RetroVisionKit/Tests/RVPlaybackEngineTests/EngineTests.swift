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

    /// タイトル切り替え（03 §5、#3 追加分）: select(item:) は「同じ source の再 load」で
    /// 選択・duration・トラック表を一括更新し、position を 0 に戻す。実運用で「ISO を開くと
    /// 最初のタイトルしか再生されない」境界が報告され（2026-11-17）、その固定として追加。
    func testSelectItemSwitchesSelectionDurationAndTracks() async throws {
        let engine = EngineCore()
        let events = await engine.events()
        try await engine.load(TestSource(itemCount: 2), selection: PlaybackSelection(item: ItemID(1)))
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.duration?.seconds, 60, "初期選択は item 1（60 s 相当）でないと")

        // 再生状態から切り替えても、線は止まり .ready で落ち着く（v1 の切り替え意味論）。
        await engine.play()
        await engine.select(item: ItemID(2))
        snap = await engine.snapshot()
        XCTAssertEqual(snap.phase, .ready, "切り替え後は ready で静止（再生は押し直し）")
        XCTAssertEqual(snap.selected?.item, ItemID(2), "選択が切り替わらない")
        XCTAssertEqual(snap.duration?.seconds, 30, "duration が古い item のまま（selectedItem 未反映）")
        XCTAssertEqual(snap.position, .zero, "position が古い位置を表示したまま")
        XCTAssertEqual(snap.available.first?.id, TrackID(21), "トラック表が古い item のまま")

        // events 側にも同じ事実が届く（UI は events からのみ導出する原則 — #17）。
        var sawSecondTable = false
        var sawZeroPosition = false
        collect: for await event in events {
            switch event {
            case .tracksChanged(let table) where table.first?.id == TrackID(21): sawSecondTable = true
            case .positionUpdated(let position, _, _) where position == .zero: sawZeroPosition = true
            default: break
            }
            if sawSecondTable && sawZeroPosition { break collect }
        }
        XCTAssertTrue(sawSecondTable, "tracksChanged が新しい item の表を運ばない")
        XCTAssertTrue(sawZeroPosition, "positionUpdated(.zero) の初期化イベントが無い")
        await engine.close()
    }

    // MARK: source.close の伝搬（03 §1 の MediaSource.close 契約、#3 終了後始末）
    //
    // engine.close は「参照を落とす」だけではなく source.close を呼ぶ（process 終末の
    // deinit 依存にしない — 実測 2026-11-17: 終了時 close 無しで ISO マウントと
    // 430 MB の修復写し temp が残った）。source は 1 度だけ（close 後は currentSource を
    // 手放す）。EngineCore.close の 2 回目の呼び出しは no-op のまま。

    func testEngineCloseReleasesSourceResources() async throws {
        let engine = EngineCore()
        let source = ClosableTestSource()
        try await engine.load(source, selection: PlaybackSelection(item: ItemID(1)))
        await engine.close()
        let afterFirst = await source.closeCount
        XCTAssertEqual(afterFirst, 1, "engine.close が source.close に届かない（03 §1 の明示 release 契約）")
        await engine.close()
        let afterSecond = await source.closeCount
        XCTAssertEqual(afterSecond, 1, "close が source に 2 回伝播した（手放した source を握り直している）")
    }

}

/// テスト用のソース。VIDEO_TS 相当の構造をメモリ上に作る（09 §3）。
struct TestSource: MediaSource {
    let hasAspectSignals: Bool
    /// 2 にすると dvdTitles 構造（item 数・duration が項目ごとに違う形）を作れる
    /// （タイトル切り替えの state machine 検査用 — EngineCoreTests）。
    let itemCount: Int
    init(hasAspectSignals: Bool = true, itemCount: Int = 1) {
        self.hasAspectSignals = hasAspectSignals
        self.itemCount = itemCount
    }

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
        var items: [MediaItem] = []
        for n in 1...itemCount {
            let item = MediaItem(id: ItemID(UInt64(n)), titleNumber: n,
                                 duration: CMTime(value: Int64(60 / n), timescale: 1),
                                 trackTable: [TrackInfo(id: TrackID(UInt32(10 * n + 1)), kind: .video,
                                                        format: .video(video))],
                                 videoFormat: video,
                                 chapters: [ChapterMark(index: 0, start: .zero)],
                                 aspectFlag: hasAspectSignals ? .allowed4x3 : nil)
            items.append(item)
        }
        let structure = MediaStructure(itemKind: .dvdTitles, items: items)
        return OpenedSource(reader: MemoryBlockReader(bytes: Data(count: 2_048 * 8)),
                            structure: structure,
                            formatHint: .mpegProgramStream)
    }
}

/// 03 §1 の close 契約検査用の test double（close 回数を数える）。open/構造は
/// TestSource と同一形（再生線は走らせず close の伝搬だけ見る）。
actor ClosableTestSource: MediaSource {
    nonisolated var descriptor: SourceDescriptor {
        SourceDescriptor(id: SourceID(77), kind: .videoTsFolder, displayName: "closable",
                         location: .fileURL(URL(fileURLWithPath: "/tmp/closable")))
    }
    private(set) var closeCount = 0
    func open() async throws -> OpenedSource { try await TestSource().open() }
    func close() async { closeCount += 1 }
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

/// 適応制御の窓評価（08 §3）: 累積 stats の差分と thermal の写像。
final class AdaptiveWindowTests: XCTestCase {
    func testWindowedStatsIsTheDifferenceOfCumulativeStats() {
        let previous = FrameStats(total: 100, presented: 90, dropped: 10, late: 4,
                                  enhancementSkipped: 1, dropReasons: [.late: 4])
        let current = FrameStats(total: 160, presented: 140, dropped: 20, late: 10,
                                 enhancementSkipped: 3, dropReasons: [.late: 10])
        let w = EngineCore.windowedStats(previous: previous, current: current)
        XCTAssertEqual(w.presented, 50)
        XCTAssertEqual(w.dropped, 10)
        XCTAssertEqual(w.total, 60, "窓の total = 提示 + 落とした")
        XCTAssertEqual(w.late, 6)
        XCTAssertEqual(w.dropReasons[.late], 6)
        XCTAssertEqual(w.deadlineMissRatio, 16.0 / 60.0, accuracy: 1e-9, "(dropped + late) / total")
    }

    func testWindowedStatsNeverGoesNegativeWhenCumulativeResets() {
        let previous = FrameStats(total: 500, presented: 480, dropped: 20, late: 9)
        let fresh = FrameStats(total: 3, presented: 3)
        let w = EngineCore.windowedStats(previous: previous, current: fresh)
        XCTAssertEqual(w.total, 0, "新 session で累積が戻っても窓は負にならない（0 に丸める）")
        XCTAssertEqual(w.dropped, 0)
        XCTAssertEqual(w.late, 0)
    }

    func testThermalStateMapping() {
        XCTAssertEqual(EngineCore.thermalState(from: .nominal), .nominal)
        XCTAssertEqual(EngineCore.thermalState(from: .fair), .fair)
        XCTAssertEqual(EngineCore.thermalState(from: .serious), .serious)
        XCTAssertEqual(EngineCore.thermalState(from: .critical), .critical)
    }
}

