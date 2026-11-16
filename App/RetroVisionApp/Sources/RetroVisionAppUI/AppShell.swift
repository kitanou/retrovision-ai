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
