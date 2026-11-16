import AppKit
import SwiftUI
import RVPlaybackEngine

// MARK: - アプリシェール（00 §2 の App/RetroVisionApp。#17 の view tree の根）

/// 終了後始末の入口。applicationShouldTerminate は同期経路 — model 側で
/// engine.close（= source.close: unmount と修復写し temp の掃除）を上限付きで完了させて
/// から終らせる。「アプリは通常動作でログを書かない」方針は不変（待てた上限の逸脱のみ
/// rvquit 一行で出る）。
public final class AppTerminationHandler: NSObject, NSApplicationDelegate, @unchecked Sendable {
    /// 代入も参照も main thread 限定（applicationShouldTerminate は main で同期呼出し、
    /// 代入は AppBody.init = @MainActor）。設計上の main 直列なので unsafe 明示で受容する。
    nonisolated(unsafe) static weak var model: PlayerViewModel?

    public override init() { super.init() }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppTerminationHandler.model else { return .terminateNow }
        // 終了を一度保留し（terminateLater）、AppKit の通常ループで engine.close を完了させてから
        // 終る（後始末 = unmount と修復写し temp の掃除。03 §1 の close 契約）。
        // 待ち続けないための watchdog（3 s）— 超過時は rvquit 一行だけ残して進行させる。
        var replied = false
        let finish: @MainActor () -> Void = {
            if replied { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model.closeEngineForQuit()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !replied {
                FileHandle.standardError.write(Data("rvquit: engine close exceeded 3s limit, proceeding with termination\n".utf8))
                finish()
            }
        }
        return .terminateLater
    }
}

public struct RetroVisionAppBody: App {
    @State private var model: PlayerViewModel
    @NSApplicationDelegateAdaptor(AppTerminationHandler.self) private var terminationHandler

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
        // 終了後始末への配線（03 §1 の MediaSource.close 契約。model の唯一の所有者は
        // App の @State — 生存 = プロセスなので weak で所有環にしない。実測 2026-11-17:
        // 何も繋がないと終了後に ISO マウントと 430 MB の修復写し temp が残った）。
        AppTerminationHandler.model = _model.wrappedValue
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
