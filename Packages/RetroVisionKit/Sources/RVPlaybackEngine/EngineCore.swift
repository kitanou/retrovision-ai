import Foundation
import RVDiagnostics
import RVDecode
import RVEnhancement
import RVMediaCore
import RVMediaSources
import RVMLRuntime
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
                                   duration: selectedItem()?.duration,
                                   selected: selection,
                                   available: selectedItem()?.trackTable ?? [],
                                   quality: quality)
    }

    /// 選択中の item（structure 内で selection.item に一致。無ければ先頭 = v1 の既定）。
    /// items.first 固定だとタイトル切り替えで duration・トラック表が古い item のままになる
    /// （実測: ISO の 2 本目へ切り替えても UI の duration が 1 本目のままだった）。
    private func selectedItem() -> MediaItem? {
        guard let structure else { return nil }
        if let item = selection?.item,
           let chosen = structure.items.first(where: { $0.id == item }) {
            return chosen
        }
        return structure.items.first
    }

    public func currentStructure() -> MediaStructure? { structure }
    public func currentPlan() -> RenderPlan? { activePlan }

    // MARK: 開く

    public func load(_ source: any MediaSource, selection: PlaybackSelection?) async throws {
        lineGeneration &+= 1   // 古い線のイベント・in-flight 運送操作を黙らせる（下記ガード）
        // 古い再生線を止める（タイトル切り替え = 同じ source への再 load 経路を含む。
        // 以前は初回 load 前提で旧 session を止めておらず、2 回目の load で線が取り残された）。
        sessionTask?.cancel()
        if let session { await session.shutdown() }
        sessionTask = nil
        session = nil
        sessionRunning = false
        lastOutcome = nil
        position = .zero
        transition(to: .preparing)
        self.selection = selection
        // 再 load（タイトル切り替え）のときだけ、古い表示位置を 0 に戻す初期化イベントを
        // 送る。初回 load では送らない — 初回線は最初の提示が position の先頭イベントであり、
        // 先頭フレームの PTS が 0 の素材で 0 が二重に並ぶと「再生中の位置は strictly
        // increasing」（02 §4・#14）の検査の意味と衝突する（FilePlaybackTests の実測で判明）。
        let isReload = structure != nil
        currentSource = source
        // 選択自体も events で流す（UI は selectionChanged からのみ現在の選択を導出する —
        // タイトルメニューの now 表示が古い選択のままにならないため、open でも送る）。
        if let selection {
            continuation?.yield(.selectionChanged(selection))
        }
        do {
            let opened = try await source.open()
            self.openedSource = opened
            self.structure = opened.structure
            await wirePipeline(for: source, structure: opened.structure)
            continuation?.yield(.structureChanged(opened.structure))
            // 構造駆動の既定選択（メニュー増分、03 §5 の実挙動合わせ）: selection nil は
            // open 後の構造を見て先頭 item で解決する。VIDEO_TS では menu（VMGM の
            // VIDEO_TS.VOB）が列の先頭 → menu 優先、menu が無ければ先頭タイトル（従来形）。
            // tracksChanged より先に流す（tracksChanged は selectedItem() を読むため）。
            if selection == nil, let first = opened.structure.items.first {
                let resolved = PlaybackSelection(item: first.id)
                self.selection = resolved
                continuation?.yield(.selectionChanged(resolved))
            }
            // 選ばれている item のトラック表を載せる（items.first 固定だとタイトル切り替えで
            // UI のトラック選択が古い表のままになる — select(item:) の実装で顕在化）。
            continuation?.yield(.tracksChanged(selectedItem()?.trackTable ?? []))
            try rebuildPlan()
            await preparePlaybackLine()
            transition(to: .ready)
            if isReload {
                // 位置・長さの初期化（title 切り替え後に UI が古い位置や古い item の長さを
                // 表示し続けないための単一経路 — events からのみ導出する原則）。
                continuation?.yield(.positionUpdated(position: .zero, duration: selectedItem()?.duration,
                                                     clockDriftMS: 0))
            }
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
    /// 今開いている source（タイトル切り替えの再 load で使う。MediaSource は Sendable）。
    private var currentSource: (any MediaSource)?

    public func close() async {
        lineGeneration &+= 1   // seek 実行中に close されたら、seek 復帰後の phase 復帰を行わない
        sessionTask?.cancel()
        if let session { await session.shutdown() }
        sessionTask = nil
        session = nil
        sessionRunning = false
        pipeline = nil
        // 資源の明示 release（03 §1 の MediaSource.close 契約）。session を止めた**後**に
        // 行う（reader が動いたままの eject は壊れるため順守）。process 終末の deinit
        // 任せにしない — 実測 2026-11-17: 終了時 close 無しだと ISO マウントと
        // 430 MB の修復写し temp が残った。
        if let source = currentSource {
            await source.close()
        }
        lastOutcome = nil
        position = .zero
        openedSource = nil
        currentSource = nil
        structure = nil
        activePlan = nil
        pendingPlan = nil
        transition(to: .empty)
    }

    /// 直前（または最中）の再生の測定結果。probe と診断 UI 向け（#11 の G1 資料）。
    public func playbackOutcome() -> PlaybackOutcome? { lastOutcome }

    // MARK: 運送

    public func play() async {
        // .ended からの play = 先頭から再生し直す（2026-11-17 決定、#22 実測: タイトル終了後
        // play も seek も拒否されて何も押せない状態になっていた — PICHI 実 ISO で観測）。
        // 終了線で session は走り終えているので、落としてから seek(.zero) で新しい線を作る。
        if phase == .ended {
            sessionTask?.cancel()
            if let session { await session.shutdown() }
            sessionTask = nil
            session = nil
            sessionRunning = false
            lastOutcome = nil
            await seek(to: .zero, tolerance: .exact)
        }
        guard phase == .ready || phase == .paused || phase == .stalled(reason: .mediaSlow) else { return }
        await promotePendingPlan()
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
        adaptiveWindowStart = nil   // 新 session は累積 stats が 0 から始まる（窓を取り直す）
        expectedPositionGeneration = await session.currentSeekGeneration   // 新 session: 生成時点の世代から受理
        if let videoPresenter { await session.setVideoPresenter(videoPresenter) }
        else if let videoSink { await session.setVideoSink(videoSink) }
        await session.setRenderPlan(activePlan)
        if volumeGain != 1.0 { await session.setVolume(volumeGain) }
        self.sessionRunning = false
    }
    /// 保持する提示サーフェス（OQ-26）。セッション再生成（トラック切替・item 切替）で貼り直す。
    private var videoSink: (any VideoPresentSink)?

    /// 提示サーフェスの設定（OQ-26 の暫定ハンドオフ）。nil で計測のみ提示に戻す。
    /// 実際の提示（#5 の Metal）が実装されるまで、UI はこの経路で frame を受け取る。
    public func setVideoSink(_ sink: (any VideoPresentSink)?) async {
        videoSink = sink
        videoPresenter = nil
        await session?.setVideoSink(sink)
    }

    /// 提示面（presenter）の設定。Metal 提示はこちら（sink より優先）。nil で sink 経路へ戻す。
    private var videoPresenter: (any VideoFramePresenter)?
    public func setVideoPresenter(_ presenter: (any VideoFramePresenter)?) async {
        videoPresenter = presenter
        if let presenter { await session?.setVideoPresenter(presenter) }
        else { await session?.setVideoSink(videoSink) }
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
        // ended からも seek できる（2026-11-17 決定、#22 実測: 終了後に timeline を触っても
        // 無応答で、UI の位置表示だけが動いていた）。完了後は paused として落ち着く
        // （再生の自動再開はしない — 運送はユーザー操作）。
        guard phase == .playing || phase == .paused || phase == .ended else { return }
        let resumeTo: EnginePhase = (phase == .ended) ? .paused : phase
        let myGen = lineGeneration
        transition(to: .seeking(target: time))
        position = time   // プログレスは目標位置を表示（04 §6）
        lastPositionEmitSeconds = nil   // 後方 seek でも位置イベントが再開される
        continuation?.yield(.positionUpdated(position: time, duration: selectedItem()?.duration,
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

    /// タイトル切り替え（03 §5、#3 の残増分）。v1 の決定（2026-11-17）: 「線を止めて同じ
    /// source を選び直す」reload として実装する — open 側は冪等（VideoTs / DiscImage は
    /// 構造と demuxer を cache 済みで、再 open は再 probe・再連結しない）。phase は
    /// preparing → ready に戻る（再生は押してから）。position は 0 に戻る（load が送る
    /// positionUpdated(.zero) が単一の初期化経路）。実運用で確認された境界: ISO を開くと
    /// 最初のタイトルしか再生されず、「おそらく最初のチャプターのみ」という報告になった。
    public func select(item: ItemID) async {
        guard let structure, structure.items.contains(where: { $0.id == item }) else { return }
        guard phase != .preparing, let source = currentSource else { return }
        var selection = self.selection ?? PlaybackSelection(item: item)
        selection.item = item
        try? await load(source, selection: selection)
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

    // MARK: 適応制御の窓評価（08 §3・§4。信号の生成と controller への配線）
    //
    // 位置イベント（提示のたび）を契機に、窓（既定 2 s）が満ちたときだけ評価する。専用タイマーを
    // 持たない（再生線と同じ流れの中で完結し、止まっている間は評価しない）。窓の FrameStats は
    // session の累積値の差分。thermal は ProcessInfo、memory pressure / breaker / present jitter は
    // 供給元（A2 の runtime、MetalPresenter.onPresented）が載るまで既定値（normal / false / 0）。

    // モデル実行層（A2）。無ければ breaker は常に closed、memory pressure も unload する対象が無い。
    private var modelRuntime: (any ModelRuntimeProtocol)?
    private var trackedModels: [ModelID] = []
    private var availableManifests: [ModelManifest] = []
    private var memoryPressure: ControlSignals.MemoryPressureLevel = .normal
    private var memorySource: (any DispatchSourceMemoryPressure)?
    /// 直近に適用した tier（降格 / 昇格の判別用。nil の間は最初の setTier で基準だけを置く）。
    private var lastAppliedTier: QualityTier?

    /// モデル実行層を接続する。`models` は breaker を監視し、memory pressure で unload する対象。
    /// nil で切り離し（memory pressure の監視も止める）。
    public func setModelRuntime(_ runtime: (any ModelRuntimeProtocol)?, models: [ModelID] = [],
                                manifests: [ModelManifest] = []) {
        modelRuntime = runtime
        trackedModels = runtime == nil ? [] : models
        // plan 生成が参照できるモデル（06 §2。manifest が無ければ SR / 学習ベースの段は入らない）。
        availableManifests = runtime == nil ? [] : manifests
        try? rebuildPlan()
        memorySource?.cancel()
        memorySource = nil
        memoryPressure = .normal
        guard runtime != nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal],
                                                              queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let level: ControlSignals.MemoryPressureLevel =
                event.contains(.critical) ? .critical : (event.contains(.warning) ? .warn : .normal)
            Task { await self?.setMemoryPressure(level) }
        }
        source.resume()
        memorySource = source
    }

    func setMemoryPressure(_ level: ControlSignals.MemoryPressureLevel) { memoryPressure = level }

    /// 追跡中のモデルのどれかの breaker が open か（half-open は試行中なので open 扱いにしない）。
    private func anyModelBreakerOpen() async -> Bool {
        guard let modelRuntime else { return false }
        for id in trackedModels where await modelRuntime.health(of: id).breakerState == .open { return true }
        return false
    }

    /// 窓の統計と各供給元から ControlSignals を作る（純粋。テストで写像を固定する）。
    static func makeSignals(window: FrameStats, windowMS: Double, thermal: ThermalState,
                            memory: ControlSignals.MemoryPressureLevel, breakerOpen: Bool) -> ControlSignals {
        ControlSignals(summary: DiagnosticsSummary(windowMS: windowMS, frames: window), thermal: thermal,
                       memoryPressureLevel: memory, modelBreakerOpen: breakerOpen)
    }

    /// 1 窓分を評価して action を適用する。`evaluateAdaptiveWindowIfDue` の中身（session に依存しない）。
    func evaluateWindow(window: FrameStats, elapsedMS: Double, nowMS: Double,
                        thermal: ThermalState) async -> [ControlAction] {
        let signals = Self.makeSignals(window: window, windowMS: elapsedMS, thermal: thermal,
                                       memory: memoryPressure, breakerOpen: await anyModelBreakerOpen())
        if lastAppliedTier == nil { lastAppliedTier = controller.state.activeTier }   // 評価前の tier を基準にする
        let actions = controller.evaluate(signals: signals, atMS: nowMS)
        // UI に伝える理由: 何が原因で降格したか（優先: breaker > memory > thermal > 負荷）。
        let reason: DegradeReason = signals.modelBreakerOpen ? .modelFailure
            : (signals.memoryPressureLevel != .normal ? .memory
               : ((thermal == .serious || thermal == .critical) ? .thermal : .loadHigh))
        if !actions.isEmpty { await applyControlActions(actions, reason: reason) }
        return actions
    }

    /// テスト用の接点（controller の状態の読み書き）。
    func adaptiveState() -> AdaptivePolicyEngine.State { controller.state }
    func seedAdaptiveState(_ state: AdaptivePolicyEngine.State) { controller.state = state }

    private var adaptiveWindowStart: ContinuousClock.Instant?
    private var adaptiveLastStats = FrameStats()

    /// 累積 stats の窓差分（session 再生成などで累積が戻った場合は負にせず 0 に丸める）。
    static func windowedStats(previous: FrameStats, current: FrameStats) -> FrameStats {
        func delta(_ now: Int, _ before: Int) -> Int { max(0, now - before) }
        var reasons: [DropReason: Int] = [:]
        for (reason, count) in current.dropReasons {
            let d = delta(count, previous.dropReasons[reason] ?? 0)
            if d > 0 { reasons[reason] = d }
        }
        let presented = delta(current.presented, previous.presented)
        let dropped = delta(current.dropped, previous.dropped)
        return FrameStats(total: presented + dropped, presented: presented, dropped: dropped,
                          late: delta(current.late, previous.late),
                          enhancementSkipped: delta(current.enhancementSkipped, previous.enhancementSkipped),
                          dropReasons: reasons)
    }

    static func thermalState(from state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    private func evaluateAdaptiveWindowIfDue(thermal: ThermalState = EngineCore.thermalState(from: ProcessInfo.processInfo.thermalState)) async {
        guard phase == .playing, let session else { return }
        let now = ContinuousClock.now
        if let start = adaptiveWindowStart,
           adaptiveClockMS(now) - adaptiveClockMS(start) < controller.config.windowMS {
            return   // 窓が満ちるまで session に触れない（提示のたびの呼び出しを安くする）
        }
        let current = await session.outcomeSnapshot().stats
        guard let start = adaptiveWindowStart else {
            adaptiveWindowStart = now
            adaptiveLastStats = current
            return
        }
        let elapsedMS = adaptiveClockMS(now) - adaptiveClockMS(start)
        let window = Self.windowedStats(previous: adaptiveLastStats, current: current)
        adaptiveWindowStart = now
        adaptiveLastStats = current
        guard window.total > 0 else { return }
        _ = await evaluateWindow(window: window, elapsedMS: elapsedMS, nowMS: adaptiveClockMS(now), thermal: thermal)
    }

    private let adaptiveClockOrigin = ContinuousClock.now
    private func adaptiveClockMS(_ instant: ContinuousClock.Instant) -> Double {
        let d = instant - adaptiveClockOrigin
        return Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    /// 適応制御から届いた action を適用する（08 §5）。plan の作り直しは frame 境界で行う。
    public func applyControlActions(_ actions: [ControlAction], reason: DegradeReason = .loadHigh) async {
        for action in actions {
            switch action {
            case .setTier(let tier):
                // controller 側で state は更新済み。**降格のときだけ**理由を UI へ（昇格は通知しない）。
                if let previous = lastAppliedTier, tier < previous { noteDegradation(reason) }
                lastAppliedTier = tier
            case .bypassStage(let stage):
                noteDegradation(reason)
                _ = stage
            case .unloadModel:
                // memory pressure: 追跡中のモデルを unload して memory を戻す（06 §6。再生は止めない）。
                if let modelRuntime { for id in trackedModels { await modelRuntime.unload(id) } }
                noteDegradation(.memory)
            case .disableTemporalBlend, .useLighterModelVariant, .reduceInferenceScale,
                 .enhanceEveryNFrames, .setInFlightLimit:
                noteDegradation(reason)
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
            // frame 境界での plan 切り替え（INV-3）。設定変更・適応制御で作られた pending plan は、
            // 次に提示された frame の位置イベントで昇格する（その場では差し替えない）。
            if pendingPlan != nil, phase == .playing { await promotePendingPlan() }
            await evaluateAdaptiveWindowIfDue()
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
            // Strict 床: 既に published した位置と同じ值是黙る。0 に seek した直後の
            // PTS=0 初帧のように 0 が二重になると、位置イベントの strictly increasing
            // contract（02 §4・#14）と衝突する — 再生し直しの実測で判明。
            guard pts.seconds > position.seconds else { return }
            position = pts
            // イベント洪水を防ぐ（UI 向け 0.25 s 間隔。診断は outcome を見る）。
            if lastPositionEmitSeconds == nil || pts.seconds - (lastPositionEmitSeconds ?? -1) >= 0.25 {
                lastPositionEmitSeconds = pts.seconds
                // drift は音声 clock が生きているあいだだけ実値（04 §5 の符号系）。
                var driftMS = 0.0
                if let session, let last = await session.outcomeSnapshot().clockDriftMS.last {
                    driftMS = last
                }
                continuation?.yield(.positionUpdated(position: pts, duration: selectedItem()?.duration,
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
        guard let item = selectedItem(), let format = item.videoFormat else { return }
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
            deinterlace: settings.deinterlaceMode,
            availableModels: availableManifests))
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

    private func promotePendingPlan() async {
        guard let promoted = pendingPlan else { return }
        activePlan = promoted
        pendingPlan = nil
        await session?.setRenderPlan(promoted)   // frame 境界で差し替わる（session が次の提示から読む）
    }
}
