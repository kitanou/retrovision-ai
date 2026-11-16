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
    private var controller = AdaptivePolicyEngine()
    private var continuation: AsyncStream<PlayerEvent>.Continuation?
    private var stream: AsyncStream<PlayerEvent>?

    // 再生線（#11/#10）。pipeline は「その source を実際に走らせるための配線」で、
    // ファイル source 以外は Phase 2 で同じスロットに収める（FileMediaSource の注記参照）。
    private var pipeline: Pipeline?
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
        lineGeneration &+= 1   // 古い線のイベント・in-flight 運送操作を黙らせる（下記ガード）
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
            await preparePlaybackLine()
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
        lineGeneration &+= 1   // seek 実行中に close されたら、seek 復帰後の phase 復帰を行わない
        sessionTask?.cancel()
        if let session { await session.shutdown() }
        sessionTask = nil
        session = nil
        sessionRunning = false
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
        // load で作って warmup 済みのセッション（#12）は run 開始だけ。実行中のものは resume。
        if session == nil, let pipeline, activePlan ?? pendingPlan != nil {
            await makeSession(for: pipeline)
        }
        guard let session else { return }
        if sessionRunning {
            await session.resume()
            return
        }
        sessionRunning = true
        sessionTask = Task { await session.run() }
    }

    /// セッション生成（load の warmup 経路と、seek 後の再生再開从这里通る）。
    private func makeSession(for pipeline: Pipeline) async {
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
            report: { [weak self, line = lineGeneration] event in
                // 古い線の session が closer 後に流すイベントは無視（close/load で generation が進む）。
                Task { await self?.handleSessionEvent(event, line: line) }
            })
        self.session = session
        expectedPositionGeneration = await session.currentSeekGeneration   // 新 session: 生成時点の世代から受理
        if let videoSink { await session.setVideoSink(videoSink) }
        if volumeGain != 1.0 { await session.setVolume(volumeGain) }
        self.sessionRunning = false
    }
    /// 保持する提示サーフェス（OQ-26）。セッション再生成（トラック切替・item 切替）で貼り直す。
    private var videoSink: (any VideoPresentSink)?

    /// 提示サーフェスの設定（OQ-26 の暫定ハンドオフ）。nil で計測のみ提示に戻す。
    /// 実際の提示（#5 の Metal）が実装されるまで、UI はこの経路で frame を受け取る。
    public func setVideoSink(_ sink: (any VideoPresentSink)?) async {
        videoSink = sink
        await session?.setVideoSink(sink)
    }
    private typealias Pipeline = (demuxer: any Demuxer, track: TrackID, format: VideoFormatDescription,
                                  audioTrack: TrackID?, audioFormat: AudioFormatDescription?)
    private var sessionRunning = false

    /// 起動準備（#12・OQ-18）。open の完了（.preparing のあいだ）にセッションを作り、
    /// 復号の初回スパイク（44〜70 ms）と音声 prefill を here 消化する。失敗しても
    /// open を失敗させない（outcome.errors に残り、再生時に縮退として表面化する）。
    private func preparePlaybackLine() async {
        guard let pipeline else { return }
        await makeSession(for: pipeline)
        await session?.prepare()
    }

    /// 音声線の組立て（#10）。demuxer が PCMSampleSource（AVFoundation の PCM 変換読み出し、
    /// EXP-002 A1）のときだけ作る。sink.start() は出力装置の無い環境（CI など）で失敗するが、
    /// それはセッション側で「暫定 pacing へ縮退」として扱う（start はここで呼ばない）。
    private func makeAudioLine(for pipeline: Pipeline?) async -> AudioLine? {
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

    /// seek（04 §6、#13）。セッションを生かしたまま復号配線を組み替える — VT session を
    /// 壊さない（初回复号スパイクを再払しない。#12 と同じ設計）。SeekController の手順:
    /// 音声は target-0.2 s 前から実音 preroll、映像は直前 keyframe から捨てながら進む
    /// （PlaybackSession.seek がやる）。UI には target 位置を示し、preroll 完了後
    /// （この呼び出しの復帰時）に seek 前の phase へ戻す（04 §6「完了まで待つ」）。
    public func seek(to time: MediaTime, tolerance: SeekTolerance = .default) async {
        guard phase == .playing || phase == .paused else { return }
        let resumeTo = phase
        let myGen = lineGeneration
        transition(to: .seeking(target: time))
        position = time   // プログレスは目標位置を表示（04 §6）
        lastPositionEmitSeconds = nil   // 後方 seek でも位置イベントが再開される
        continuation?.yield(.positionUpdated(position: time, duration: structure?.items.first?.duration,
                                             clockDriftMS: 0))
        if let session {
            await session.seek(to: time, tolerance: tolerance)
            // seek 完了で session の世代が進んだ。ここから先の position イベントはこの世代のみ受理
            // （次の transition まで同一の actor turn なので、旧世代の後出しは起きない）。
            expectedPositionGeneration = await session.currentSeekGeneration
        } else if pipeline != nil, activePlan ?? pendingPlan != nil {
            // 実行中のセッションが無い（open 直後等）: seek 位置の状態で作り、warmup まで行う。
            if let pipeline {
                await makeSession(for: pipeline)
                await session?.prepare()
            }
        }
        // session.seek の最中に close / 別 load が入っていたら、この seek は線の外側。
        // phase を触らずに黙って終る（actor の reentrancy で close が先に .empty へ進んでいる）。
        guard lineGeneration == myGen else { return }
        transition(to: resumeTo)
    }

    public func step(_ direction: StepDirection) async {
        guard phase == .paused else { return }
        // 1 帧送りは seek を使わない（04 §6）。実デコードが載るまで phase はそのまま。
    }

    public func setRate(_ rate: Double) async {
        // 1.0 以外はまだサポートしない（OQ-09）。
    }

    /// 音量（0.0〜1.0、線形）。#17 の音量スライダーの受け口。保持してセッション再生成
    /// （トラック・item 切替）でも引き継ぐ。音声線の無い素材では no-op（VM 側の状態だけ保つ）。
    public func setVolume(_ gain: Double) async {
        volumeGain = min(max(gain, 0.0), 1.0)
        await session?.setVolume(volumeGain)
    }
    private var volumeGain = 1.0

    /// 受理する position イベントの seek 世代（session の #13 ガードと同じ値で照合する。
    /// 古い線の後出しを捨て、position の非逆行を守る — 02 §4、決定ログ #14）。
    private var expectedPositionGeneration = 0

    /// 再生線の generation（#13 のセッション内ガードの engine 側対応。actor の reentrancy で
    /// close/load と in-flight の seek が交差すると、遅れて復帰した seek が phase を復活させる。
    /// 線の切り替えで同期インクリメントし、線の外側になった操作とイベントは黙る）。
    private var lineGeneration = 0

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
        // 配線口（03 §4）。#3 で DemuxerProviding に一般化: source が item 単位の
        // demuxer を提供する。selected item が structure にあればそれ、無ければ先頭
        // （DVD のタイトル切り替え UI は #3 の別増分。load の時点で選べる状況にしない）。
        guard let provider = source as? any DemuxerProviding else { return }
        let selected = selection?.item
        guard let item = structure.items.first(where: { $0.id == selected }) ?? structure.items.first,
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
        pipeline = (await provider.makeDemuxer(itemId: item.id), track.id, videoFormat, audioTrack, audioFormat)
    }

    private func handleSessionEvent(_ event: PlaybackSession.Event, line: Int) async {
        guard line == lineGeneration else { return }   // 古い線の closer（close/load 済み）
        switch event {
        case .position(let pts, let seekGeneration):
            // 位置イベントの契約（02 §4。2026-11-16 の CI で実測した逆行の修正 — 決定ログ #14）。
            // 三重の濾過:
            //  ① seeking のあいだは全て黙る（UI は target を表示済み。この窓のイベントは
            //    古い線の後出しか、早期すぎて意味が無い）。
            //  ② 旧 seek 世代のイベントは捨てる（session の #13 ガードと同じ世代値で照合。
            //    await で遅延実行された旧提示の Task が新 target の「後」に届く構造を消す）。
            //  ③ 床ガード: engine が一度出した位置（= 運送操作の target も含む）より
            //    小さい値は出さない（非逆行を出力点で決定的に保証する）。
            if case .seeking = phase { return }
            guard seekGeneration >= expectedPositionGeneration else { return }
            guard pts.seconds >= position.seconds else { return }
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
            sessionRunning = false
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
