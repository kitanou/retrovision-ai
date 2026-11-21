import AppKit
import SwiftUI
import RVMediaCore
import RVPlaybackEngine

// MARK: - メニューとキーボードショートカット（#17 の表。全てメニューから発見可能 = 受け入れ基準）

struct PlayerCommands: Commands {
    let model: PlayerViewModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("ファイルを開く…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("閉じる") { model.closeItem() }
                .keyboardShortcut("w")
        }
        CommandMenu("再生") {
            Button(model.isPlaying ? "一時停止" : "再生") { model.playPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.transportEnabled)
            Divider()
            Button("5 秒戻る") { model.arrowKey(.left) { if model.seekEnabled { model.skip(by: -5) } } }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("5 秒進む") { model.arrowKey(.right) { if model.seekEnabled { model.skip(by: 5) } } }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("30 秒戻る") { model.skip(by: -30) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(!model.seekEnabled)
            Button("30 秒進む") { model.skip(by: 30) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(!model.seekEnabled)
            Divider()
            Button("前のコマへ（一時停止中）") { model.step(.backward) }
                .keyboardShortcut(",")
                .disabled(!model.stepEnabled)
            Button("次のコマへ（一時停止中）") { model.step(.forward) }
                .keyboardShortcut(".")
                .disabled(!model.stepEnabled)
            Divider()
            Button("ミュート切替") { model.muted.toggle() }
                .keyboardShortcut("m", modifiers: [])
            Button("音量を上げる") { model.arrowKey(.up) { model.volume = min(model.volume + 0.05, 1) } }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("音量を下げる") { model.arrowKey(.down) { model.volume = max(model.volume - 0.05, 0) } }
                .keyboardShortcut(.downArrow, modifiers: [])
            Divider()
            Button("メニューのボタンを決定") { model.menuActivate() }
                .keyboardShortcut(.return, modifiers: [])
            Button("DVD メニューへ戻る") { model.showDVDMenu() }
                .keyboardShortcut("t", modifiers: .command)
        }
        CommandMenu("映像") {
            Picker("比率", selection: Binding(get: { model.aspectPolicy },
                                             set: { model.aspectPolicy = $0 })) {
                Text("ソースに従う").tag(AspectPolicy.followSource)
                Text("4:3").tag(AspectPolicy.explicit(.dar4x3))
                Text("16:9").tag(AspectPolicy.explicit(.dar16x9))
            }
            Divider()
            // 強調化は Phase 3–4 で実働（#17 §3 のプレースホルダ方針: 形だけ先に載せる）。
            Menu("強調化プリセット") {
                Button("オフ（Phase 1 の実動作）") {}.disabled(true)
                Button("控えめ（準備中）") {}.disabled(true)
                Button("標準（準備中）") {}.disabled(true)
                Button("最大（準備中）") {}.disabled(true)
            }
            .disabled(true)
        }
        CommandGroup(replacing: .toolbar) {
            Button("全画面") { model.setFullscreen(NSApp.keyWindow) }
                .keyboardShortcut("f", modifiers: [.control, .command])
        }
    }
}

// MARK: - 設定ウィンドウ（#17 §8 の Phase 1 版。一般 = UI ローカル、映像 = PlayerSettings 経由）

struct SettingsRootView: View {
    @Environment(PlayerViewModel.self) private var model
    @AppStorage("ui.autoHideControls") private var autoHideControls = true
    @AppStorage("ui.showQualityPill") private var showQualityPill = true

    var body: some View {
        TabView {
            Form {
                Toggle("コントロールを自動的に隠す", isOn: $autoHideControls)
                Toggle("品質ピルを表示", isOn: $showQualityPill)
                Text("続きから再生・最近使った項目は App Sandbox の準備（#16）とともに追加します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("一般", systemImage: "gearshape") }
            .frame(width: 420)

            Form {
                Picker("表示比率", selection: Binding(get: { model.aspectPolicy },
                                                     set: { model.aspectPolicy = $0 })) {
                    Text("ソースに従う").tag(AspectPolicy.followSource)
                    Text("4:3").tag(AspectPolicy.explicit(.dar4x3))
                    Text("16:9").tag(AspectPolicy.explicit(.dar16x9))
                }
                Text("変更は次の frame 境界から反映されます（INV-3）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("映像", systemImage: "film") }
            .frame(width: 420)
        }
        .padding()
    }
}
