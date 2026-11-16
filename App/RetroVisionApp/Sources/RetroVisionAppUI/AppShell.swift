import AppKit
import SwiftUI
import RVPlaybackEngine

// MARK: - アプリシェール（00 §2 の App/RetroVisionApp。#17 の view tree の根）

public struct RetroVisionAppBody: App {
    @State private var model: PlayerViewModel

    @MainActor
    public init() {
        // SPM の実行可能ターゲットで起動する場合（#16 でバンドル化在此之前の暫定）、
        // アクティベーションポリシーを明示してメニューバーとドックを持つ通常アプリにする。
        NSApplication.shared.setActivationPolicy(.regular)
        _model = State(initialValue: PlayerViewModel(engine: DefaultPlayerEngine()))
        // 起動時 QA 入口（RV_AUTO_OPEN）。RootView.onAppear では走らせない —
        // 実測 2026-11-17: 画面ロック中の起動では onAppear 自体が発火しない
        // （RV_DEBUG_ACTIVITY の登録ログが一行も出ないで窓だけ居た）。
        _model.wrappedValue.autoOpenFromLaunchEnvironment()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .commands {
            PlayerCommands(model: model)
        }

        Settings {
            SettingsRootView()
                .environment(model)
        }
    }
}
