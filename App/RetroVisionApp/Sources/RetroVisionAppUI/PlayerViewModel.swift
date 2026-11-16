import AVKit
import AppKit
import CoreMedia
import Foundation
import Observation
import RVMediaCore
import RVMediaSources
import RVPlaybackEngine
// MARK: - PlayerViewModel（#17「UI 状態とエンジンの対応」の実装点）
//
// 指針（#17 設計方針 2）: 表示状態はすべて PlayerStateSnapshot / PlayerEvent から導出し、
// UI 側に遷移テーブルを持たない。コントロールの有効・無効も phase から computed property で
// 導出する（#17 の表。PlayerViewModelTests で全 phase を固定する）。

/// 提示サーフェスの配線口（composition root だけが知る。#17 の view tree で
/// MetalVideoViewRepresentable 相当がここを通す。#5 の Metal 提示では不要になる — OQ-26）。
@MainActor
protocol VideoSurfaceBinding: AnyObject {
    func attachVideoSink(_ sink: (any VideoPresentSink)?) async
}

extension DefaultPlayerEngine: VideoSurfaceBinding {
    func attachVideoSink(_ sink: (any VideoPresentSink)?) async {
        await setVideoSink(sink)
    }
}

@MainActor
@Observable
final class PlayerViewModel {
    // engine 由来の現在値（events からのみ更新する — ミラーの単一更新経路）。
    private(set) var phase: EnginePhase = .empty
    private(set) var position: MediaTime = .zero
    private(set) var duration: MediaTime?
    private(set) var availableTracks: [TrackInfo] = []
    /// dvdTitles 構造などの multi-item source のタイトル一覧（#3 追加分のタイトルメニュー用。
    /// 単一項目 source では空 = メニューは出ない）。
    private(set) var availableTitles: [MediaItem] = []
    private(set) var selected: PlaybackSelection?
    private(set) var quality = QualityPresentation()
    private(set) var lastError: PlaybackError?
    /// 表示比率（#17 の「AspectResolution で letterbox / pillarbox」の暫定版。
    /// 最初の帧の format から AspectResolver で解いて決める。nil = 未知 = 1:1 画素比で仮表示）。
    private(set) var displayAspectValue: Double?

    // UI ローカルな状態（engine に意味を渡さない）。
    var volume: Double = 1.0 {
        didSet { Task { await engine.setVolume(muted ? 0 : volume) } }
    }
    var muted: Bool = false {
        didSet { Task { await engine.setVolume(muted ? 0 : volume) } }
    }
    var aspectPolicy: AspectPolicy = .followSource {
        didSet { Task { await engine.apply(currentSettings()) } }
    }
    var timelineScrubbing: Bool = false

    let engine: any PlayerEngine
    private let surfaceBinding: (any VideoSurfaceBinding)?
    private var eventTask: Task<Void, Never>?
    private var surface: SurfaceSink?
    private var lastOpenedURL: URL?
    /// menu 再生終了の自動進行のガード（同一 .ended を複数回発火させない。
    /// selectionChanged が観測されたら解除 — 単一更新経路の原則（#17）と同じ場所で行う）。
    private var menuAdvancePending = false

    init(engine: any PlayerEngine) {
        self.engine = engine
        // 既定のサーフェス対応（DefaultPlayerEngine / FakePlayerEngine の両方が適合する）。
        if let binding = engine as? any VideoSurfaceBinding {
            self.surfaceBinding = binding
        } else {
            self.surfaceBinding = nil
        }
        startEventPump()
    }

    private func startEventPump() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let engine = self?.engine else { return }
            for await event in engine.events() {
                if Task.isCancelled { break }
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: PlayerEvent) {
        switch event {
        case .phaseChanged(let phase):
            self.phase = phase
            if case .failed(let error) = phase { lastError = error }
            if case .empty = phase { lastError = nil }
            if case .ended = phase { scheduleMenuAutoAdvance() }
        case .positionUpdated(let position, let duration, _):
            guard !timelineScrubbing else { return }   // ドラッグ中のつまみはユーザー操作に固定（#17）
            self.position = position
            if let duration { self.duration = duration }
        case .structureChanged(let structure):
            // 構造から表示材料を採る（item 1 個のファイル素材では duration / trackTable がここに乗る。
            // 複数 item（DVD タイトル）はタイトルメニューの材料に載せる — 選択中の duration と
            // トラック表は engine が selectionChanged / tracksChanged / positionUpdated(.zero) で
            // 送るため、そちらが単一の更新経路）。
            if let duration = structure.items.first?.duration { self.duration = duration }
            availableTracks = structure.items.first?.trackTable ?? []
            availableTitles = structure.items.count > 1 ? structure.items : []
        case .tracksChanged(let tracks):
            availableTracks = tracks
        case .selectionChanged(let selection):
            selected = selection
            menuAdvancePending = false   // 選択が動いた = 直前の menu 終端処理は完了
        case .qualityChanged(let presentation):
            quality = presentation
        case .enhancementDegraded:
            break   // Phase 1 は強調化の実働がない（#17 のプレースホルダ方針）。#9 でトースト化する
        case .warning, .failure:
            break   // failure は phase .failed として届く（#17 §9: インラインカードは phase 由来）
        case .mediaRemoved:
            closeItem()   // ディスク取出しは空状態へ戻す（位置保存は Phase 2・Sandbox）
        case .statisticsUpdated:
            break   // 診断 inspector は Phase 5（#9）
        }
    }

    // MARK: - 有効・無効（#17 の表。phase から ONLY に導出する）
    //
    // 実測された形（EngineCore の実挙動）:
    // - `.seeking` は transient で、直後に再生中へ戻る（04 §6 の手順 5。UI の transport は
    //   再生継続のまま、つまみだけ target に固定される #17 §2）。
    // - `.preparing` は load 中に一瞬通り、UI が購読する前に .ready へ進みうる（warmup を
    //   load の中に済ませるため #12）。したがって preparing は「操作できない phase」ではなく
    //   「再生開始だけ可、構造が必要な操作は不可」に緩める（#17 の表からの逸脱として決定ログに記録）。

    var transportEnabled: Bool {
        switch phase {
        case .empty, .seeking, .failed: return false
        case .preparing, .ready, .playing, .paused, .stalled, .ended: return true
        }
    }
    var seekEnabled: Bool {
        switch phase {
        case .empty, .preparing, .seeking, .failed: return false
        case .ready, .playing, .paused, .ended, .stalled: return true
        }
    }
    var stepEnabled: Bool {
        switch phase {
        case .ready, .paused, .ended: return true
        case .empty, .preparing, .playing, .seeking, .stalled, .failed: return false
        }
    }
    var trackSelectionEnabled: Bool {
        switch phase {
        case .ready, .playing, .paused, .ended, .stalled: return true
        case .empty, .preparing, .seeking, .failed: return false
        }
    }
    /// タイトル切り替えは trackSelectionEnabled と同じ phase で有効（切り替え自体が
    /// preparing を経るので、seeking 中は受け付けない）。
    var titleSelectionEnabled: Bool { trackSelectionEnabled }
    var hasTitleChoice: Bool { availableTitles.count > 1 }
    var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }
    var positionSeconds: Double { position.isValid ? position.seconds : 0 }
    var durationSeconds: Double { duration?.seconds ?? 0 }

    // MARK: - 操作（#17「呼ぶ」列）

    func open(url: URL) {
        lastOpenedURL = url
        lastError = nil
        Task {
            do {
                // 一つの入口（#3）: ディレクトリ=VIDEO_TS、ディスクイメージ=ISO mount、
                // 他=ファイル。型の判定は MediaSourceRouting（RVPlaybackEngineTests で検査）。
                // 選択は構造駆動（selection nil → engine が structure の先頭 item で解決する。
                // 03 §5 の実挙動合わせ — menu=VMGM が先頭に居ればそれが menu 優先になる）。
                let structure = try await engine.load(MediaSourceRouting.makeSource(for: url),
                                                      selection: nil)
                // first-play 政策（menu 増分。03 §5 の実挙動合わせ）: DVD で menu が先頭に
                // 居る場合、盤挿入 = 再生開始が実機の挙動なので menu を自动再生する
                // （#17 の user gate は「menu の無い素材」では従来のまま変えない）。
                if structure.items.contains(where: { $0.titleNumber == 0 }) {
                    await engine.play()
                }
                // 開いた直後は再生しない（#17: preparing → ready。transport は user gate）。
            } catch let error as PlaybackError {
                lastError = error
            } catch {
                lastError = PlaybackError(kind: .internalFailure(String(describing: error)),
                                          recovery: .needsUserAction(.selectDifferentItem),
                                          userMessage: "開けませんでした")
            }
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        // #3: ディレクトリ選択を許す（DVD-Video フォルダ / マウント済みボリュームの入口）。
        // 型フィルタは掛けない（#3 で VIDEO_TS / ISO まで一つの入口に載せる設計。
        // 開けない素材は engine が .unsupportedStructure 等で構造化して返す）。
        panel.canChooseDirectories = true
        panel.prompt = "開く"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func retryLastOpened() {
        if let url = lastOpenedURL { open(url: url) }
    }

    func playPause() {
        Task {
            if isPlaying {
                await engine.pause()
            } else {
                await engine.play()
            }
        }
    }

    func closeItem() {
        surface?.reset()
        Task { await engine.close() }
        position = .zero
        duration = nil
        availableTracks = []
        availableTitles = []
        displayAspectValue = nil
    }

    /// タイムライン操作（#17 §「UI 状態とエンジンの対応」の row: ドラッグ中はつまみだけ動かし、
    /// 離した時に .exact で 1 回だけ engine に投げる。ドラッグ中の seek はしない —
    /// 04 §6 の preroll を無限に繰り返すことになるため）。
    func beginScrub() { timelineScrubbing = true }
    func previewScrub(_ seconds: Double) {
        position = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }
    func commitScrub() {
        let target = position
        timelineScrubbing = false
        Task { await engine.seek(to: target, tolerance: .exact) }
    }

    func skip(by seconds: Double) {
        let base = position.isValid ? position.seconds : 0
        let target = max(0, min(base + seconds, durationSeconds > 0 ? durationSeconds : base + seconds))
        Task { await engine.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000),
                                 tolerance: .default) }
    }

    func step(_ direction: StepDirection) {
        Task { await engine.step(direction) }
    }

    func selectAudio(_ track: TrackID?) {
        guard let track else { return }
        Task { await engine.select(track, for: .audio) }
    }

    /// タイトル切り替え（#3 追加分。03 §5 の select(item:) — engine 側は「同じ source の
    /// 再 load」で線を組み替える。表示状態は selectionChanged / tracksChanged /
    /// positionUpdated(.zero) からのみ更新される（単一経路の原則 — #17））。
    func selectTitle(_ item: ItemID) {
        guard availableTitles.contains(where: { $0.id == item }) else { return }
        Task { await engine.select(item: item) }
    }

    /// DVD 実機の first-play 動作（03 §5 の実挙動合わせ、menu 増分）: menu item
    /// （titleNumber 0 の約束 — VideoTsNavigator の VMGM 列）の再生が ended になったら、
    /// 最初の本体タイトル（titleNumber 最小）を auto-select して再生を続ける。
    /// 本体タイトルが無い盘（menu-only）では何もしない（盘の動作と同じくそこで終わり）。
    private func scheduleMenuAutoAdvance() {
        guard !menuAdvancePending,
              let selectedID = selected?.item,
              let playing = availableTitles.first(where: { $0.id == selectedID }),
              playing.titleNumber == 0
        else { return }
        // 本体タイトル（titleNumber 最小）へ自動進行する（menu-only 盘では行わない）。
        let titles = availableTitles.filter { (($0.titleNumber ?? 1) >= 1) }
        guard let firstTitle = titles.min(by: { ($0.titleNumber ?? 0) < ($1.titleNumber ?? 0) }) else { return }
        menuAdvancePending = true
        Task { [weak self] in
            guard let self else { return }
            await self.engine.select(item: firstTitle.id)
            await self.engine.play()
        }
    }

    func setFullscreen(_ window: NSWindow?) {
        window?.toggleFullScreen(nil)
    }

    // MARK: - 提示サーフェスの配線（view が layer を作ったときに呼ぶ）

    func attachSurface(layer: AVSampleBufferDisplayLayer) {
        let sink = SurfaceSink(layer: layer) { [weak self] dar in
            Task { @MainActor [weak self] in
                if self?.displayAspectValue != dar { self?.displayAspectValue = dar }
            }
        }
        surface = sink
        Task { await self.surfaceBinding?.attachVideoSink(sink) }
    }

    func detachSurface(_ sink: SurfaceSink) {
        if surface === sink {
            Task { await self.surfaceBinding?.attachVideoSink(nil) }
        }
    }

    private func currentSettings() -> PlayerSettings {
        var settings = PlayerSettings()
        settings.aspectPolicy = aspectPolicy
        return settings
    }
}
