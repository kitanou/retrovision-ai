import CoreMedia
import Foundation
import RVMediaCore
import RVMLRuntime
import QuartzCore
import RVEnhancement
import RVMediaSources
import RVVideoPipeline

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
            // 一時停止・終端（静止画のメニューを含む）: 最後の frame を期限なしで強調して描き直す（設計 11 §6.3）。
            switch phase {
            case .paused, .ended: refineStill()
            default: break
            }
            if phase == .ended { titleEnded() }
        case .positionUpdated(let position, let duration, _):
            mirror.position = position
            if duration != nil { mirror.duration = duration }
            // タイトルの PGC の終わり（IFO の再生時間から出した時刻）に着いたら POST へ進む。
            if let end = titleRun?.endTime, position.seconds >= end { titleEnded() }
        case .structureChanged(let structure):
            lastStructure = structure
            mirror.available = structure.items.first?.trackTable ?? mirror.available
            mirror.duration = structure.items.first?.duration ?? mirror.duration
        case .tracksChanged(let tracks):
            mirror.available = tracks
        case .selectionChanged(let selection):
            mirror.selected = selection
            if let run = titleRun, selection.item != ItemID(UInt64(run.vts)) { titleRun = nil }   // 別の item に移った
            updateMenu(for: selection.item)
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
        menuProvider = source as? any DVDMenuAssetProviding
        dvdRegisters = .initial(); titleRun = nil   // 新しい盤: レジスタは初期値から
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
        if let item = mirror.selected?.item { updateMenu(for: item) }
        return structure
    }

    public func close() async {
        menuStartTask?.cancel()
        menu = nil; menuOverlay = nil; menuItem = nil; menuProvider = nil; titleRun = nil
        metalPresenter?.setOverlay(nil)
        await core.close()
        mirror = PlayerStateSnapshot()
        lastStructure = nil
    }

    public func play() async { startPumpIfNeeded(); await core.play() }
    public func pause() async { await core.pause() }
    public func seek(to time: MediaTime, tolerance: SeekTolerance) async {
        await core.seek(to: time, tolerance: tolerance)
    }
    public func step(_ direction: StepDirection) async {
        await core.step(direction)
        // 一時停止中のコマ送りは phase が変わらないことがある（設計 11 §6.3）。コマ送りの frame の提示が
        // 先に済むよう少し待ってから強調する（後から来た提示は refine を取り消すため）。
        guard let presenter = metalPresenter else { return }
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await presenter.refineLastFrame()
        }
    }
    public func setRate(_ rate: Double) async {
        metalPresenter?.setPlaybackRate(rate)   // 速度 ≠ 1 では強調を止める
        await core.setRate(rate)
    }

    private func refineStill() {
        guard let presenter = metalPresenter else { return }
        Task { await presenter.refineLastFrame() }
    }
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
        presenter.setOverlay(menuOverlay)
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
            scale: max(1, model.scaleFactor), io: model.input.kind == .tensor ? .tensor : .image,
            fullFrameSizes: model.acceptedInputSizes.map { PixelSize(width: Int32($0.width), height: Int32($0.height)) })
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

    // MARK: DVD メニュー（B2）

    private var menu: DVDMenuSession?
    private var menuOverlay: OverlayImage?
    private var menuItem: ItemID?
    private var menuProvider: (any DVDMenuAssetProviding)?
    private var menuStartTask: Task<Void, Never>?

    public var isMenuActive: Bool { menu != nil }

    /// 選択された item が静止画のタイトルメニューなら、その VOB / IFO からメニューを組み立てる。そうでなければ外す。
    private func updateMenu(for item: ItemID) {
        guard item != menuItem else { return }
        guard let mediaItem = lastStructure?.items.first(where: { $0.id == item }) else { return }   // 構造が来てから
        menuItem = item
        menuStartTask?.cancel()
        menu = nil; menuOverlay = nil
        metalPresenter?.setOverlay(nil)
        guard let provider = menuProvider, mediaItem.stillImage else { return }
        let size = mediaItem.videoFormat?.codedSize
        menuStartTask = Task { [weak self] in
            guard let assets = await provider.menuAssets(for: item) else { return }
            let w = size.map { Int($0.width) } ?? 720, h = size.map { Int($0.height) } ?? 480
            let data = await Task.detached {
                DVDMenuData.load(vobURL: assets.vobURL, ifoURL: assets.ifoURL, canvasWidth: w, canvasHeight: h)
            }.value
            guard let data, !Task.isCancelled, let self, self.menuItem == item else { return }
            let session = DVDMenuSession(data: data, item: item, vtsNumber: assets.vtsNumber,
                                         registers: self.dvdRegisters)
            self.dvdRegisters = session.registers   // メニューの PRE が決めた値を引き継ぐ
            self.menu = session
            self.menuOverlay = session.render()
            self.metalPresenter?.setOverlay(self.menuOverlay)
        }
    }

    @discardableResult
    public func menuInput(_ input: MenuInput) async -> Bool {
        guard let session = menu else { return false }
        let outcome = session.handle(input, aspect: metalPresenter?.currentAspect)
        dvdRegisters = session.registers
        switch outcome {
        case .unchanged: break
        case .redraw:
            menuOverlay = session.render()
            metalPresenter?.setOverlay(menuOverlay)
        case .action(let action):
            menuOverlay = session.render()   // 実行の色
            metalPresenter?.setOverlay(menuOverlay)
            await perform(action, in: session)
        }
        return true
    }

    private func perform(_ action: DVDMenuAction, in session: DVDMenuSession) async {
        await run(action, vts: session.vtsNumber, info: session.data.titleSet, depth: 0)
    }

    // MARK: タイトルの PGC の流れ（B2 第 8 段。PRE → 再生 → POST → メニューへ戻る / 次の PGC）

    private var dvdRegisters = DVDRegisters.initial()
    /// 再生中のタイトルの PGC。`endTime` は IFO の再生時間から出した終わり（VOB の最後まで続くときは nil。
    /// その場合は再生の終端（.ended）で POST へ進む）。
    private struct TitleRun {
        let vts: Int, ttn: Int, pgc: Int
        let info: DVDTitleSetInfo
        let endTime: Double?
    }
    private var titleRun: TitleRun?
    private var flowBusy = false

    /// メニューの動作 / PGC の流れの結果を実行する。`depth` は PRE ↔ POST の連鎖の打ち切り用。
    private func run(_ action: DVDMenuAction, vts: Int, info: DVDTitleSetInfo, depth: Int) async {
        guard depth < 8 else { return }
        switch action {
        case .playTitle(let ttn): await startTitle(ttn, chapter: 1, vts: vts, info: info, depth: depth)
        case .playChapter(let ttn, let ptt): await startTitle(ttn, chapter: ptt, vts: vts, info: info, depth: depth)
        case .showMenu: await showTitleMenu(vts: vts)
        case .exit, .none, .unsupported: return
        }
    }

    private func startTitle(_ ttn: Int, chapter: Int, vts: Int, info: DVDTitleSetInfo, depth: Int) async {
        guard let pgc = info.title(ttn)?.pgcNumber else {
            // IFO にタイトルが無い（読めなかった）: 流れは追わず、本体を先頭から再生する。
            await select(item: ItemID(UInt64(vts)))
            await play()
            return
        }
        switch DVDTitleFlow.enter(pgc: pgc, in: info, registers: &dvdRegisters) {
        case .play(let n): await playPGC(n, ttn: ttn, chapter: n == pgc ? chapter : 1, vts: vts, info: info)
        case .action(let a): await run(a, vts: vts, info: info, depth: depth + 1)
        case .stop: return
        }
    }

    private func playPGC(_ number: Int, ttn: Int, chapter: Int, vts: Int, info: DVDTitleSetInfo) async {
        let title = info.titles.first { $0.pgcNumber == number } ?? info.title(ttn)
        let start = title.flatMap { info.startTime(title: $0.number, chapter: chapter) } ?? 0
        // PGC の終わり（IFO の再生時間）。VOB の終端に近いときは .ended に任せる（IFO と demux の時刻は約 3 s ずれる）。
        var end: Double?
        if number >= 1, number <= info.titlePGCs.count {
            let pgc = info.titlePGCs[number - 1]
            let itemDuration = lastStructure?.items.first { $0.id == ItemID(UInt64(vts)) }?.duration?.seconds
            if let first = pgc.cells.first, let s = info.timeline.time(ofSector: first.firstSector), pgc.duration > 0,
               let itemDuration, s + pgc.duration < itemDuration - 5 {
                end = s + pgc.duration
            }
        }
        if mirror.selected?.item != ItemID(UInt64(vts)) { await select(item: ItemID(UInt64(vts))) }
        titleRun = TitleRun(vts: vts, ttn: title?.number ?? ttn, pgc: number, info: info, endTime: end)
        await seek(to: CMTime(seconds: start, preferredTimescale: 90_000), tolerance: .exact)
        await play()
    }

    /// 本体（または PGC の終わり）の再生が終わった: POST を評価して、メニューへ戻る / 次の PGC / 止まる。
    private func titleEnded() {
        guard let run = titleRun, !flowBusy else { return }
        flowBusy = true
        titleRun = nil
        Task { [weak self] in
            guard let self else { return }
            switch DVDTitleFlow.afterPlayback(pgc: run.pgc, in: run.info, registers: &self.dvdRegisters) {
            case .play(let n): await self.playPGC(n, ttn: run.ttn, chapter: 1, vts: run.vts, info: run.info)
            case .action(let a): await self.run(a, vts: run.vts, info: run.info, depth: 1)
            case .stop: break
            }
            self.flowBusy = false
        }
    }

    private func showTitleMenu(vts: Int) async {
        // タイトルメニュー（VTS_nn_0.VOB）の item は 1000 + vts（VideoTsMediaSource.itemID）。
        guard lastStructure?.items.contains(where: { $0.id == ItemID(UInt64(1_000 + vts)) }) == true else { return }
        titleRun = nil
        await select(item: ItemID(UInt64(1_000 + vts)))
        await play()
    }

    /// 再生中のタイトルからメニューへ戻る（UI の「メニュー」操作の受け口）。メニューが無ければ何もしない。
    public func showMenu() async {
        guard let item = mirror.selected?.item, item.rawValue > 0, item.rawValue < 1_000 else { return }
        await showTitleMenu(vts: Int(item.rawValue))
    }
}
