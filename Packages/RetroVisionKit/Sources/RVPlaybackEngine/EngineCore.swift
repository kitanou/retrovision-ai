import Foundation
import RVDiagnostics
import RVDecode
import RVEnhancement
import RVMediaCore
import RVMediaSources
import RVVideoPipeline

// MARK: - EngineCore（02 §2 の実体）
//
// Phase 0 の範囲では、状態機械・設定適用・plan 生成までを持つ。
// 実際のデコード・描画は RVDecode / RVVideoPipeline の実装が入ってから接続する（Phase 1）。

public actor EngineCore {
    public struct Deps: Sendable {
        public var time: any TimeSource
        public var metrics: MetricHandle
        public init(time: any TimeSource = SystemTimeSource(), metrics: MetricHandle = MetricHandle()) {
            self.time = time
            self.metrics = metrics
        }
    }

    /// 計測ハンドル。INV-6 に従い、plan の各段が計測点を持つことを生成時に検査する。
    public struct MetricHandle: Sendable {
        public init() {}
    }

    private var phase: EnginePhase = .empty
    private let deps: Deps
    private var structure: MediaStructure?
    private var settings = PlayerSettings()
    private var selection: PlaybackSelection?
    private var openedSource: OpenedSource?

    /// INV-3: 生成済み plan は差し替えない。新しい plan は frame 境界で切り替える。
    private var activePlan: RenderPlan?
    private var pendingPlan: RenderPlan?
    private var planCounter: UInt64 = 0
    private var preSeekPhase: EnginePhase?
    private var controller = AdaptivePolicyEngine()
    private var continuation: AsyncStream<PlayerEvent>.Continuation?
    private var stream: AsyncStream<PlayerEvent>?

    // 再生線（#11/#10）。pipeline は「その source を実際に走らせるための配線」で、
    // ファイル source 以外は Phase 2 で同じスロットに収める（FileMediaSource の注記参照）。
    private var pipeline: (demuxer: any Demuxer, track: TrackID, format: VideoFormatDescription,
                           audioTrack: TrackID?, audioFormat: AudioFormatDescription?)?
    private var session: PlaybackSession?
    private var sessionTask: Task<Void, Never>?
    private var lastOutcome: PlaybackOutcome?
    private var position: MediaTime = .zero
    private var lastPositionEmitSeconds: Double?

    public init(deps: Deps = Deps()) {
        self.deps = deps
        let (s, c) = AsyncStream.makeStream(of: PlayerEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.stream = s
        self.continuation = c
    }

    public func events() -> AsyncStream<PlayerEvent> {
        if let stream { return stream }
        let (s, c) = AsyncStream.makeStream(of: PlayerEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.stream = s
        self.continuation = c
        return s
    }

    public func snapshot() -> PlayerStateSnapshot {
        var quality = QualityPresentation(requestedTier: settings.enhancement.tier,
                                         activeTier: controller.state.activeTier,
                                         frameStats: lastOutcome?.stats ?? FrameStats())
        quality.appliedStages = activePlan?.stages.map(\.stage) ?? []
        return PlayerStateSnapshot(phase: phase,
                                   position: position,
                                   duration: structure?.items.first?.duration,
                                   selected: selection,
                                   available: structure?.items.first?.trackTable ?? [],
                                   quality: quality)
    }

    public func currentStructure() -> MediaStructure? { structure }
    public func currentPlan() -> RenderPlan? { activePlan }

    // MARK: 開く

    public func load(_ source: any MediaSource, selection: PlaybackSelection) async throws {
        transition(to: .preparing)
        self.selection = selection
        do {
            let opened = try await source.open()
            self.openedSource = opened
            self.structure = opened.structure
            await wirePipeline(for: source, structure: opened.structure)
            continuation?.yield(.structureChanged(opened.structure))
            continuation?.yield(.tracksChanged(opened.structure.items.first?.trackTable ?? []))
            try rebuildPlan()
            transition(to: .ready)
        } catch let error as PlaybackError {
            transition(to: .failed(error))
            throw error
        } catch {
            let wrapped = PlaybackError(kind: .source(.unreadable),
                                       causeDescription: String(describing: error),
                                       recovery: .giveUp(reason: "open"),
                                       userMessage: "メディアを開けません")
            transition(to: .failed(wrapped))
            throw wrapped
        }
    }

    public func close() async {
        sessionTask?.cancel()
        if let session { await session.shutdown() }
        sessionTask = nil
        session = nil
        pipeline = nil
        lastOutcome = nil
        position = .zero
        openedSource = nil
        structure = nil
        activePlan = nil
        pendingPlan = nil
        transition(to: .empty)
    }

    /// 直前（または最中）の再生の測定結果。probe と診断 UI 向け（#11 の G1 資料）。
    public func playbackOutcome() -> PlaybackOutcome? { lastOutcome }

    // MARK: 運送

    public func play() async {
        guard phase == .ready || phase == .paused || phase == .stalled(reason: .mediaSlow) else { return }
        promotePendingPlan()
        transition(to: .playing)
        // 再生線がある場合は実際にフレームを回す。ない場合（DVD 等・Phase 2）は状態機械のみ。
        if let session {
            await session.resume()
            return
        }
        if let pipeline, activePlan ?? pendingPlan != nil {
            var config = PlaybackSession.Config(videoTrack: pipeline.track, videoFormat: pipeline.format)
            config.audioTrack = pipeline.audioTrack
            config.audioFormat = pipeline.audioFormat
            let audioLine = await makeAudioLine(for: pipeline)
            let session = PlaybackSession(
                demuxer: pipeline.demuxer,
                decoder: VideoToolboxDecoder(),
                config: config,
                time: deps.time,
                audio: audioLine,
                report: { [weak self] event in
                    Task { await self?.handleSessionEvent(event) }
                })
            self.session = session
            sessionTask = Task { await session.run() }
        }
    }

    /// 音声線の組立て（#10）。demuxer が PCMSampleSource（AVFoundation の PCM 変換読み出し、
    /// EXP-002 A1）のときだけ作る。sink.start() は出力装置の無い環境（CI など）で失敗するが、
    /// それはセッション側で「暫定 pacing へ縮退」として扱う（start はここで呼ばない）。
    private func makeAudioLine(for pipeline: (demuxer: any Demuxer, track: TrackID,
                                             format: VideoFormatDescription,
                                             audioTrack: TrackID?, audioFormat: AudioFormatDescription?)?)
        async -> AudioLine? {
        guard let pipeline, pipeline.audioTrack != nil,
              let audioFormat = pipeline.audioFormat,
              let pcmSource = pipeline.demuxer as? any PCMSampleSource else { return nil }
        let decoder = AVFoundationAudioDecoder(source: pcmSource)
        // sink は「decoder が返すことになっている仕様」で組む（規則の二重化なし）。
        let target = AVFoundationAudioDecoder.pcmFormat(for: audioFormat)
        guard let sink = try? AVFoundationAudioSink(pcmFormat: target) else { return nil }
        return AudioLine(decoder: decoder, sink: sink)
    }

    public func pause() async {
        guard phase == .playing else { return }
        if let session { await session.pause() }
        transition(to: .paused)
    }

    public func seek(to time: MediaTime, tolerance: SeekTolerance = .default) async {
        guard phase == .playing || phase == .paused else { return }
        preSeekPhase = phase
        transition(to: .seeking(target: time))
        // 実際のシーク手順（音声 0.2 s 前から・映像は keyframe から）は #13 で実装する。
        // 再生線がある場合、一時停止して配線を作り直す（#13 まで这是ら暫定）。
        if let session {
            await session.shutdown()
            self.session = nil
            sessionTask?.cancel()
            sessionTask = nil
        }
        transition(to: preSeekPhase ?? .paused)
    }

    public func step(_ direction: StepDirection) async {
        guard phase == .paused else { return }
        // 1 帧送りは seek を使わない（04 §6）。実デコードが載るまで phase はそのまま。
    }

    public func setRate(_ rate: Double) async {
        // 1.0 以外はまだサポートしない（OQ-09）。
    }

    // MARK: 選択・設定

    public func select(_ track: TrackID, for kind: TrackKind) async {
        guard var selection else { return }
        switch kind {
        case .audio: selection.audio = track
        case .subtitle: selection.subtitle = .specific(track)
        default: return
        }
        self.selection = selection
        continuation?.yield(.selectionChanged(selection))
    }

    public func select(item: ItemID) async {
        guard structure?.items.contains(where: { $0.id == item }) == true else { return }
        selection?.item = item
    }

    /// 設定変更は phase を変えない（02 §3）。plan は pending に入り、frame 境界で昇格する（INV-3）。
    public func apply(_ settings: PlayerSettings) async {
        self.settings = settings
        controller.state.requestedTier = settings.enhancement.tier
        do {
            try rebuildPlan()
        } catch let error as PlaybackError {
            continuation?.yield(.warning(error))
        } catch {
            continuation?.yield(.warning(PlaybackError(kind: .internalFailure("plan"),
                                                       recovery: .retryWith(.lowerTier),
                                                       userMessage: "描画計画を作り直せませんでした")))
        }
    }

    /// 適応制御から届いた action を適用する（08 §5）。plan の作り直しは frame 境界で行う。
    public func applyControlActions(_ actions: [ControlAction]) {
        for action in actions {
            switch action {
            case .setTier:
                break // controller 側で state は更新済み
            case .bypassStage(let stage):
                noteDegradation(.loadHigh)
                _ = stage
            case .disableTemporalBlend, .useLighterModelVariant, .reduceInferenceScale,
                 .enhanceEveryNFrames, .setInFlightLimit, .unloadModel:
                noteDegradation(.loadHigh)
            }
        }
        try? rebuildPlan()
    }

    private func noteDegradation(_ reason: DegradeReason) {
        continuation?.yield(.enhancementDegraded(reason: reason, to: controller.state.activeTier))
    }

    // MARK: 内部

    /// source から再生線の配線を作る。判明しているのはファイル source のみ（Phase 2 で DVD に拡張）。
    private func wirePipeline(for source: any MediaSource, structure: MediaStructure) async {
        pipeline = nil
        guard let fileSource = source as? FileMediaSource,
              let item = structure.items.first,
              let videoFormat = item.videoFormat,
              let track = item.trackTable.first(where: { $0.kind == .video }) else { return }
        // 音声トラック（#10）。AVFoundation が列挙できるもののみ（DTS はトラックとして現れない
        // ＝ EXP-002 A6。Phase 4 の shim ゲートまで音声なしで再生する）。
        var audioTrack: TrackID?
        var audioFormat: AudioFormatDescription?
        if let audio = item.trackTable.first(where: { $0.kind == .audio }),
           case .audio(let format) = audio.format {
            audioTrack = audio.id
            audioFormat = format
        }
        pipeline = (await fileSource.makeDemuxer(), track.id, videoFormat, audioTrack, audioFormat)
    }

    private func handleSessionEvent(_ event: PlaybackSession.Event) async {
        switch event {
        case .position(let pts):
            position = pts
            // イベント洪水を防ぐ（UI 向け 0.25 s 間隔。診断は outcome を見る）。
            if lastPositionEmitSeconds == nil || pts.seconds - (lastPositionEmitSeconds ?? -1) >= 0.25 {
                lastPositionEmitSeconds = pts.seconds
                // drift は音声 clock が生きているあいだだけ実値（04 §5 の符号系）。
                var driftMS = 0.0
                if let session, let last = await session.outcomeSnapshot().clockDriftMS.last {
                    driftMS = last
                }
                continuation?.yield(.positionUpdated(position: pts, duration: structure?.items.first?.duration,
                                                     clockDriftMS: driftMS))
            }
        case .finished(let outcome):
            lastOutcome = outcome
            continuation?.yield(.statisticsUpdated(DiagnosticsSummary(frames: outcome.stats)))
            if phase == .playing { transition(to: .ended) }
        }
    }

    private func transition(to next: EnginePhase) {
        phase = next
        continuation?.yield(.phaseChanged(next))
    }

    /// plan を作る。INV-2（AI なし経路が常に成立）と INV-6（計測点）をここで検査する。
    private func rebuildPlan() throws {
        guard let item = structure?.items.first, let format = item.videoFormat else { return }
        let aspect = AspectResolver.resolve(codedSize: format.codedSize,
                                           signals: format.aspectSignals,
                                           policy: settings.aspectPolicy)
        if aspect.source == .unresolved {
            throw PlaybackError(kind: .internalFailure("aspect"),
                                recovery: .needsUserAction(.chooseAspect),
                                userMessage: "表示比率を決定できません")
        }
        planCounter += 1
        let stages = StageGraphBuilder.stageRequests(for: .init(
            userPolicy: settings.enhancement,
            activeTier: controller.state.activeTier,
            deinterlace: settings.deinterlaceMode))
        let output = OutputContract(displayPixels: format.codedSize, aspect: aspect)
        let plan = RenderPlan(id: PlanID(planCounter), tier: controller.state.activeTier,
                              stages: stages, output: output)

        // INV-6: 計測を持たない段をplanに入れた場合、生成は通すが記録して指摘する。
        for stage in plan.stages.map(\.stage) where !MetricBus.measuredSet.contains(stage) {
            continuation?.yield(.warning(PlaybackError(kind: .internalFailure("unmeasured-stage:\(stage.rawValue)"),
                                                       recovery: .giveUp(reason: "diagnostics"),
                                                       userMessage: "計測点のない段が plan に含まれています")))
        }
        // 予算検証（05 §1）。超える plan は作らない。
        // frame rate は demux の時点で解決済みであることが前提（01 §2）。unknown のまま plan まで
        // 来たら作らない（推測で NTSC 扱いにしない）。
        guard let frameRate = format.frameRate else {
            throw PlaybackError(kind: .decode(.formatRejected),
                                recovery: .giveUp(reason: "probe"),
                                userMessage: "フレームレートが未解決のため再生計画を作れません")
        }
        guard plan.budget.isFeasible(for: frameRate) else {
            throw PlaybackError(kind: .internalFailure("budget"),
                                recovery: .retryWith(.lowerTier),
                                userMessage: "フレーム予算を超える描画計画です")
        }
        pendingPlan = plan
    }

    private func promotePendingPlan() {
        guard let pendingPlan else { return }
        activePlan = pendingPlan
        self.pendingPlan = nil
    }
}
