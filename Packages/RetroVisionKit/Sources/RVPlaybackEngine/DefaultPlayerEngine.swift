import Foundation
import RVMediaCore
import RVMLRuntime
import QuartzCore
import RVEnhancement
import RVMediaSources

// MARK: - PlayerEngine への適合（02 §2 の「実装クラス」）
//
// EngineCore（actor の状態機械）を @MainActor の公開 API へ転送する薄い適配層。
// UI は PlayerEngine プロトコルだけを見る（INV-8）。ここが 02 §4 の fan-out を持つ:
// EngineCore のイベント列は単一契約者（actor の内側）で受け、ミラー（snapshot の
// 現在値）を更新しながら UI 側の購読者へ流す。

@MainActor
public final class DefaultPlayerEngine: PlayerEngine {
    private let core: EngineCore
    private var mirror = PlayerStateSnapshot()
    private var lastStructure: MediaStructure?

    private let fanOut: AsyncStream<PlayerEvent>
    private let fanOutContinuation: AsyncStream<PlayerEvent>.Continuation
    private var pumpStarted = false

    public init(core: EngineCore = EngineCore()) {
        self.core = core
        let (stream, continuation) = AsyncStream.makeStream(of: PlayerEvent.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        self.fanOut = stream
        self.fanOutContinuation = continuation
    }

    /// EngineCore のイベント列を 1 本だけ吸う（02 §4 の fan-out 実装点）。
    private func startPumpIfNeeded() {
        guard !pumpStarted else { return }
        pumpStarted = true
        Task { [core, weak self] in
            for await event in await core.events() {
                self?.applyToLocal(event)
                self?.fanOutContinuation.yield(event)
            }
        }
    }

    /// ミラーの更新。positionUpdated / phaseChanged などから現在値を作る（snapshot の
    /// 直読みは actor を跨ぐので使わない — 初期値と load 直後の全更新だけ await core.snapshot()）。
    private func applyToLocal(_ event: PlayerEvent) {
        switch event {
        case .phaseChanged(let phase):
            mirror.phase = phase
        case .positionUpdated(let position, let duration, _):
            mirror.position = position
            if duration != nil { mirror.duration = duration }
        case .structureChanged(let structure):
            lastStructure = structure
            mirror.available = structure.items.first?.trackTable ?? mirror.available
            mirror.duration = structure.items.first?.duration ?? mirror.duration
        case .tracksChanged(let tracks):
            mirror.available = tracks
        case .selectionChanged(let selection):
            mirror.selected = selection
        case .qualityChanged(let quality):
            mirror.quality = quality
        case .statisticsUpdated(let summary):
            mirror.diagnosticsSummary = summary
        case .enhancementDegraded, .warning, .failure, .mediaRemoved:
            break   // 状態の現在値ではなく通知。UI は events 側で受け取る。
        }
    }

    // MARK: PlayerEngine

    public func load(_ source: any MediaSource, selection: PlaybackSelection?) async throws -> MediaStructure {
        startPumpIfNeeded()
        try await core.load(source, selection: selection)
        if let resolved = await core.snapshot().selected {
            mirror.selected = resolved
        }
        if let structure = await core.currentStructure() {
            applyToLocal(.structureChanged(structure))
        }
        mirror = await core.snapshot()
        guard let structure = await core.currentStructure() else {
            throw PlaybackError(kind: .source(.notFound),
                                recovery: .needsUserAction(.selectDifferentItem),
                                userMessage: "開いた素材の構造が得られませんでした")
        }
        lastStructure = structure
        return structure
    }

    public func close() async {
        await core.close()
        mirror = PlayerStateSnapshot()
        lastStructure = nil
    }

    public func play() async { startPumpIfNeeded(); await core.play() }
    public func pause() async { await core.pause() }
    public func seek(to time: MediaTime, tolerance: SeekTolerance) async {
        await core.seek(to: time, tolerance: tolerance)
    }
    public func step(_ direction: StepDirection) async { await core.step(direction) }
    public func setRate(_ rate: Double) async { await core.setRate(rate) }
    public func setVolume(_ gain: Double) async { await core.setVolume(gain) }

    public func select(_ track: TrackID, for kind: TrackKind) async {
        await core.select(track, for: kind)
    }
    public func select(item: ItemID) async { await core.select(item: item) }
    public func apply(_ settings: PlayerSettings) async { await core.apply(settings) }

    public var stateSnapshot: PlayerStateSnapshot { mirror }

    /// 単一購読者（02 §4 の契約）。UI 側の ViewModel が 1 回だけ購読する。
    public func events() -> AsyncStream<PlayerEvent> {
        startPumpIfNeeded()
        return fanOut
    }

    public var structure: MediaStructure? { lastStructure }

    // MARK: 合成根からの配線（プロトコル外。#17 の view tree では composition root だけが触る）

    /// 提示サーフェスの配線（OQ-26 の暫定ハンドオフ）。#5 の Metal 提示では不要になる。
    public func setVideoSink(_ sink: (any VideoPresentSink)?) async {
        await core.setVideoSink(sink)
    }

    // MARK: Metal 提示面（#5。OQ-26 の暫定経路の置換）

    private var metalPresenter: MetalFramePresenter?

    /// Metal 提示面を接続する。UI は CAMetalLayer を渡すだけで、RVVideoPipeline を知らない（INV-8）。
    /// Metal デバイスが無い環境では false を返し、呼び出し側は暫定の sink 経路を使う。
    /// `onAspectResolved` は表示比率（targetDAR）が決まる・変わるたびに呼ばれる。
    @discardableResult
    public func attachMetalSurface(layer: CAMetalLayer,
                                   onAspectResolved: @escaping @Sendable (Double) -> Void) async -> Bool {
        if metalPresenter == nil { metalPresenter = MetalFramePresenter() }
        guard let presenter = metalPresenter else { return false }
        if let pending = pendingEnhancement { presenter.setEnhancement(runtime: pending.runtime, model: pending.model, tiling: pending.tiling) }
        presenter.attachLayer(layer)
        presenter.setAspectHandler(onAspectResolved)
        await core.setVideoPresenter(presenter)
        return true
    }

    /// Metal 提示面を外す（view 破棄）。presenter 自体は残り、次の attach で再利用される。
    public func detachMetalSurface() async {
        metalPresenter?.attachLayer(nil)
        metalPresenter?.setAspectHandler(nil)
        await core.setVideoPresenter(nil)
    }

    /// 最後の frame を現在の drawable 寸法で再描画する（窓リサイズ・一時停止中）。
    public func redrawMetalSurface() {
        metalPresenter?.redraw()
    }

    // MARK: AI 強調（06・07。#6 / #7 の統合）

    private var pendingEnhancement: (runtime: any ModelRuntimeProtocol, model: ModelID, tiling: MLEnhancementStage.Tiling)?

    /// AI 段を有効にする。モデルを load し、presenter に AI 段を設定し、エンジンにモデル実行層を接続する
    /// （plan に superResolution 段が入り、breaker / memory pressure が適応制御の信号になる）。
    /// 実際に使われるのは、設定の tier が lightML 以上で、適応制御が tier を許す間だけ。
    /// load に失敗したら false（AI 段は有効にならず、再生は従来どおり）。
    /// タイルはモデルの入力寸法、重なりは 16 px（入力寸法の半分未満に収める）、倍率は manifest の scaleFactor。
    @discardableResult
    public func attachEnhancement(runtime: any ModelRuntimeProtocol, model: ModelManifest) async -> Bool {
        do { try await runtime.load(model.modelID) } catch { return false }
        let tiling = MLEnhancementStage.Tiling(
            tileWidth: model.input.width, tileHeight: model.input.height,
            overlap: min(16, max(0, min(model.input.width, model.input.height) / 2 - 1)),
            scale: max(1, model.scaleFactor))
        pendingEnhancement = (runtime, model.modelID, tiling)
        metalPresenter?.setEnhancement(runtime: runtime, model: model.modelID, tiling: tiling)
        await core.setModelRuntime(runtime, models: [model.modelID], manifests: [model])
        return true
    }

    /// AI 段を無効にする（モデルを unload し、実行層を切り離す）。
    public func detachEnhancement() async {
        if let pending = pendingEnhancement { await pending.runtime.unload(pending.model) }
        pendingEnhancement = nil
        metalPresenter?.clearEnhancement()
        await core.setModelRuntime(nil)
    }

    /// AI 段の統計（強調して提示した frame 数・非強調に倒した数など）。診断・テスト用。
    public func enhancementStatistics() -> MetalFramePresenter.EnhancementStatistics? {
        metalPresenter?.statistics
    }
}
