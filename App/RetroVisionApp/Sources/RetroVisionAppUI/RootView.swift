import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RVMediaCore
import RVPlaybackEngine

// MARK: - ルート画面（#17 §1 空状態 / §2 再生画面）

struct RootView: View {
    @Environment(PlayerViewModel.self) private var model

    var body: some View {
        Group {
            if case .empty = model.phase {
                EmptyStateView()
            } else {
                PlayerScreenView()
            }
        }
        .frame(minWidth: 480, minHeight: 270)
    }
}

// MARK: - 空状態（#17 §1）
//
// Phase 1 の範囲: ドロップとファイル開きのみ。光学ドライブの候補一覧と最近使った項目は
// Phase 2（#3 と App Sandbox — security-scoped bookmark は #16 のバンドル整備と一緒）。

struct EmptyStateView: View {
    @Environment(PlayerViewModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("ここにファイルをドロップ")
                .font(.title3)
            Text("映像ファイル・VIDEO_TS フォルダ・ISO")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("ファイルを開く…") { model.presentOpenPanel() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in model.open(url: url) }
                }
            }
            return true
        }
    }
}

// MARK: - 再生画面（#17 §2）

struct PlayerScreenView: View {
    @Environment(PlayerViewModel.self) private var model
    @AppStorage("ui.autoHideControls") private var autoHideControls = true
    @AppStorage("ui.showQualityPill") private var showQualityPill = true
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// 再生画面の表示中だけ有効な入力源（#22。onContinuousHover が NSView 映像面の
    /// 上で効かないため、AppKit local monitor を併存させる — ControlsActivity.swift）。
    @State private var activityMonitor: ControlsActivityMonitor?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoSurface
            statusOverlay
            controlBar
        }
        .overlay(alignment: .topTrailing) {
            if showQualityPill {
                QualityPill().padding(10)
            }
        }
        .onContinuousHover { _ in showControls() }
        .onAppear {
            let monitor = ControlsActivityMonitor { showControls() }
            monitor.start()
            activityMonitor = monitor
            // 起動時 QA 入口（RV_AUTO_OPEN。未設定なら何もしない — 通常起動は従来どおり）。
            model.autoOpenFromLaunchEnvironment()
        }
        .onDisappear {
            activityMonitor?.stop()
            activityMonitor = nil
            hideTask?.cancel()
        }
    }

    // MARK: 映像（#17 §2 の letterbox/pillarbox。枠の比率は AspectResolution の targetDAR に合わせる）

    @ViewBuilder
    private var videoSurface: some View {
        let attach: @MainActor (AVSampleBufferDisplayLayer) -> Void = { layer in
            model.attachSurface(layer: layer)
        }
        if let aspect = model.displayAspectValue, aspect > 0 {
            VideoSurfaceView(onLayer: attach, onActivity: { showControls() })
                .aspectRatio(aspect, contentMode: .fit)
        } else {
            // 比率未解決のあいまは枠いっぱいに仮表示（最初の帧で解決され、直ちに枠が変わる。
            // unknown を 4:3 に倒さない — #17 の方針 4・01 §2 と同じ「推測で既定にしない」）。
            VideoSurfaceView(onLayer: attach, onActivity: { showControls() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 状態オーバーレイ（#17 §2 stalled・§9 error。モーダルにしない）

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .preparing:
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("開いています…").foregroundStyle(.secondary)
            }
        case .stalled(let reason):
            VStack(spacing: 8) {
                ProgressView()
                Text("読み込み待ち（\(reason.displayName)）").foregroundStyle(.secondary)
            }
        case .seeking:
            // 位置は target に固定済み（controlBar の timeline が target を示す）。進行マークのみ。
            ProgressView().controlSize(.small)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 10) {
                Text("再生を続けられません").font(.headline)
                Text(error.userMessage).font(.body)
                if let cause = error.causeDescription {
                    Text(cause).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("再試行") { model.retryLastOpened() }
                    Button("閉じる") { model.closeItem() }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(40)
        default:
            EmptyView()
        }
    }

    // MARK: コントロールバー（#17 §2 浮遊・自動非表示。表どおりの有効・無効は model 側）

    @ViewBuilder
    private var controlBar: some View {
        VStack(spacing: 6) {
            timeline
            controlsRow
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    private var timeline: some View {
        Slider(
            value: Binding(get: { model.positionSeconds },
                           set: { model.previewScrub($0) }),
            in: 0...max(model.durationSeconds, 0.001),
            onEditingChanged: { editing in
                editing ? model.beginScrub() : model.commitScrub()
            }
        )
        .disabled(!model.seekEnabled)
        .accessibilityLabel("再生位置")
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button { model.step(.backward) } label: { Image(systemName: "backward.fill") }
                .disabled(!model.stepEnabled)
                .accessibilityLabel("前のコマへ")
            Button { model.playPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .disabled(!model.transportEnabled)
            .accessibilityLabel(model.isPlaying ? "一時停止" : "再生")
            Button { model.step(.forward) } label: { Image(systemName: "forward.fill") }
                .disabled(!model.stepEnabled)
                .accessibilityLabel("次のコマへ")

            Text("\(formatPlaybackTime(model.positionSeconds)) / \(formatPlaybackTime(model.durationSeconds))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button { model.muted.toggle() } label: {
                    Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .accessibilityLabel(model.muted ? "ミュート解除" : "ミュート")
                Slider(value: Binding(get: { model.volume },
                                     set: { model.volume = min(max($0, 0), 1) }))
                    .frame(width: 90)
                    .accessibilityLabel("音量")
            }

            Menu {
                Picker("比率", selection: Binding(get: { model.aspectPolicy },
                                                 set: { model.aspectPolicy = $0 })) {
                    Text("ソースに従う").tag(AspectPolicy.followSource)
                    Text("4:3").tag(AspectPolicy.explicit(.dar4x3))
                    Text("16:9").tag(AspectPolicy.explicit(.dar16x9))
                }
            } label: {
                Image(systemName: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help("表示比率")

            audioTrackMenu

            titleMenu

            Button { model.setFullscreen(NSApp.keyWindow) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("全画面")
            .help("全画面（⌃⌘F）")
        }
    }

    /// DVD タイトルメニュー（#3 追加分。multi-item 構造のときだけ出る — ISO 実運用で
    /// 「最初のタイトルしか再生されない」境界が報告されたことへの UI 応答。
    /// 選択は events 経由でのみ反映される: engine.select(item:) → selectionChanged /
    /// tracksChanged / positionUpdated(.zero)）。
    @ViewBuilder
    private var titleMenu: some View {
        if model.hasTitleChoice {
            Menu {
                Picker("タイトル", selection: Binding(
                    get: { model.selected?.item },
                    set: { if let item = $0 { model.selectTitle(item) } }
                )) {
                    ForEach(model.availableTitles) { item in
                        // menu（VMGM）は titleNumber 0 の約束（VideoTsNavigator）。UI 名は「メニュー」。
                        Text(item.titleNumber == 0 ? "メニュー"
                             : "タイトル \(item.titleNumber.map(String.init) ?? "\(item.id.rawValue)")")
                            .tag(Optional(item.id))
                    }
                }
            } label: {
                Image(systemName: "film")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .disabled(!model.titleSelectionEnabled)
            .help("DVD タイトル")
        }
    }

    @ViewBuilder
    private var audioTrackMenu: some View {
        let audio = model.availableTracks.filter { $0.kind == .audio }
        if audio.count > 1 {
            Menu {
                Picker("音声トラック", selection: Binding(
                    get: { model.selected?.audio ?? TrackID.none },
                    set: { model.selectAudio($0.rawValue == 0 ? nil : $0) }
                )) {
                    Text("自動").tag(TrackID.none)
                    ForEach(audio, id: \.id) { track in
                        Text(track.displayName).tag(track.id)
                    }
                }
            } label: {
                Image(systemName: "music.note.list")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .disabled(!model.trackSelectionEnabled)
            .help("音声トラック")
        }
    }

    // MARK: 自動非表示（#17 設計方針 1。既定 2.5 s、AppStorage で切る）

    private func showControls() {
        hideTask?.cancel()
        if !controlsVisible { controlsVisible = true }
        guard autoHideControls, model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { controlsVisible = false }
        }
    }
}

// MARK: - 品質ピル（#17 §3 の Phase 1 版: requested/active をそのまま載せる。
// 強調化の実働化は Phase 3–4。07 §5 の「選んだもの」と「実際に動いているもの」の表示契約だけ先に固定する）

struct QualityPill: View {
    @Environment(PlayerViewModel.self) private var model

    var body: some View {
        let q = model.quality
        let text: String = {
            if q.requestedTier == .off { return "強調: オフ" }
            if q.activeTier < q.requestedTier {
                return "強調: \(q.requestedTier.displayName) → \(q.activeTier.displayName)"
            }
            return "強調: \(q.activeTier.displayName)"
        }()
        Text(text)
            .font(.caption)
            .padding(6)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel(text)
    }
}

private extension StallReason {
    var displayName: String {
        switch self {
        case .demuxStarved: return "読み込み待ち"
        case .decodeStarved: return "復号待ち"
        case .mediaSlow: return "メディアの読み込みが遅い"
        case .resourceExhausted: return "リソース不足"
        }
    }
}

private extension TrackInfo {
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let language, !language.isEmpty { return language }
        return "トラック \(id.rawValue)"
    }
}
