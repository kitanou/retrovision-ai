import AppKit
import Foundation

// MARK: - transport バー再表示の入力源（#22。#17 方針1 の実装補完）
//
// 実測（2026-11-17、ユーザー実機の ISO 再生): バーは自動非表示で消えた後、
// マウスを動かしても一切戻らない。原因は入力源側の欠陥 — `.onContinuousHover` は
// 純 SwiftUI 領域でしか効かず、映像面 VideoLayerView（layer-backed NSView の
// NSViewRepresentable）が画面を覆う再生中には mouseMoved が SwiftUI の hover
// tracking に届かない（AppKit は mouseMoved を deepest hit-test 側へ送る）。
//
// 对策は AppKit 層の入力源追加（意味論 — 「再生画面上の mouse-moved/操作で再表示」—
// は #17 のまま変えない）。NSEvent local monitor は NSApplication.sendEvent の
// 分发前に割込むため view 階層に依存しない。発火は main thread。onContinuousHover
// も併存させる（bar 自身の上など SwiftUI 側ではこちらも効き、二重の発火は
// showControls() の冪等性で無害）。

@MainActor
public final class ControlsActivityMonitor {
    private let onActivity: @MainActor () -> Void
    private var token: Any?

    public init(onActivity: @escaping @MainActor () -> Void) {
        self.onActivity = onActivity
    }

    /// 再生画面の表示中に開始（冪等 — 二重登録しない）。
    public func start() {
        guard token == nil else { return }
        let notify = self.onActivity
        token = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { event in
            // オプトイン診断（既定は沈黙・「アプリはログを書かない」方針は不変）。
            // RV_DEBUG_ACTIVITY=1 のときだけ stderr に活動イベントを流す。実機での
            // 登録/発火の切り分けに実測で使った（2026-11-17、#22: 窓の mouse-moved
            // 生成が既定 false で monitor に一行も届かない状態を確定させた計器）。
            if ProcessInfo.processInfo.environment["RV_DEBUG_ACTIVITY"] != nil {
                FileHandle.standardError.write("activity event=\(event.type.rawValue)\n".data(using: .utf8)!)
            }
            // local monitor の handler は main thread で同期呼出し（sendEvent の
            // 分发前。検査 ControlsActivityMonitorTests で実測固定）。
            MainActor.assumeIsolated { notify() }
            return event   // イベントを吞まない（バー自身の操作 — timeline ドラッグ等 — を壊さない）
        }
        if ProcessInfo.processInfo.environment["RV_DEBUG_ACTIVITY"] != nil {
            FileHandle.standardError.write("controls activity monitor registered\n".data(using: .utf8)!)
        }
    }

    /// 再生画面の非表示化時に解除。stop 後は発火しない（検査で固定）。
    public func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
