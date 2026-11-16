import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import RetroVisionAppUI

// MARK: - transport バー再表示の入力源（#22 の回帰検査）
//
// 実運用実測: ISO 再生中にバーが自動非表示へ消えた後、マウスを動かしても戻らない
// （onContinuousHover が NSView 映像面の上で効かないため）。对策の local monitor が
//  ・view 階層に依存せず発火する（NSApp.sendEvent の分发前に割込む）
//  ・イベントを吞まない（バー自身の操作を壊さない）
//  ・start 冪等 / stop で解除
// であることを、CGEvent 経由の合成イベント（実機と同じ mouseMoved 経路。実測で
// otherEventWithType は mouseMoved を作れない = 10 決定ログの API 気づき）で固定する。

@MainActor
final class ControlsActivityMonitorTests: XCTestCase {
    /// 実機と同じ合成経路: CGEvent → NSEvent(cgEvent:)。
    private func makeMouseEvent(_ cgType: CGEventType) -> NSEvent? {
        let cg = CGEvent(mouseEventSource: nil, mouseType: cgType,
                        mouseCursorPosition: CGPoint(x: 12, y: 34), mouseButton: .left)
        return cg.flatMap { NSEvent(cgEvent: $0) }
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testActivityEventsReachCallbackWithoutSwallowingAndStopDetaches() throws {
        _ = NSApplication.shared   // local monitor の経路には app オブジェクトが必要（probe 実測）

        // 先に目撃 monitor を登録する。local monitor は新しい順に呼ばれ、被测が
        // nil を返して吞むとこちらへは届かない（= 吞まないことの検査）。
        var witnessed = 0
        let witness = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            witnessed += 1
            return event
        })
        var activity = 0
        let monitor = ControlsActivityMonitor { activity += 1 }
        monitor.start()
        monitor.start()   // 冪等（二重登録しない = 1 event あたり 1 回）
        defer { monitor.stop(); NSEvent.removeMonitor(witness) }

        // 1) mouseMoved が届く（#22 の実測で壊れていた経路そのもの）。
        let moved = try XCTUnwrap(makeMouseEvent(.mouseMoved))
        XCTAssertEqual(moved.type, .mouseMoved)
        NSApp.sendEvent(moved)
        settle()
        XCTAssertEqual(activity, 1, "mouseMoved が control 操作の活動 callback に届かない")
        // 2) イベントを吞んでいない（目撃 monitor にも同じ event が通っている）。
        XCTAssertEqual(witnessed, 1, "mouseMoved が吞まれた（バー自身の操作が壊れる）")

        // 3) マウス操作も活動として数える（rightMouseDown / scrollWheel）。
        var sentMouse = 0
        if let rightDown = makeMouseEvent(.rightMouseDown) { NSApp.sendEvent(rightDown); sentMouse += 1 }
        if let scroll = makeMouseEvent(.scrollWheel) { NSApp.sendEvent(scroll); sentMouse += 1 }
        settle()
        XCTAssertGreaterThanOrEqual(activity, 1 + sentMouse,
                                   "クリック・スクロールが活動として数えられない: \(activity)")

        // 4) 関係無いキー操作では発火しない（拾う event の範囲）。
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                 modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil,
                                                 characters: "x", charactersIgnoringModifiers: "x",
                                                 isARepeat: false, keyCode: 7))
        let beforeKey = activity
        NSApp.sendEvent(key)
        settle()
        XCTAssertEqual(activity, beforeKey, "keyDown が活動に混ざっている")

        // 5) stop 後は発火しない（画面が消えたら入力を切ること）。
        monitor.stop()
        let before = activity
        NSApp.sendEvent(moved)
        settle()
        XCTAssertEqual(activity, before, "stop 後も発火している")
    }

    // MARK: 入力生成側（#22 の二次原因: NSWindow は既定で mouse-moved を生成しない）

    /// 映像面が載る window は mouse-moved を生成する旗を立てる。これが無いと
    /// local monitor も owner 配送も「そもそも届くイベントが無い」状態だった（実測）。
    func testSurfaceEnablesWindowMouseMovedGeneration() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertFalse(window.acceptsMouseMovedEvents, "既定 false の前提（AppKit の既定契約）")
        let surface = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView = surface
        XCTAssertTrue(window.acceptsMouseMovedEvents, "映像面が載る window で mouse-moved が生成されない")

        // 表示環境が後から旗を戻しても、layout 時に再宣言される（fullscreen 等の保险）。
        window.acceptsMouseMovedEvents = false
        surface.layout()
        XCTAssertTrue(window.acceptsMouseMovedEvents, "layout での再宣言が行われない")
    }

    /// 生成された mouse-moved の owner 配送受け口（VideoLayerView.mouseMoved）が
    /// 活動として配線される。local monitor とは独立の経路で、両方届いても冪等。
    func testSurfaceMouseMovedIsWiredAsActivity() {
        var activity = 0
        let surface = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        surface.onControlsActivity = { activity += 1 }
        let cg = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: 8, y: 8), mouseButton: .left)
        let moved = try! XCTUnwrap(cg.flatMap { NSEvent(cgEvent: $0) })
        surface.mouseMoved(with: moved)
        XCTAssertEqual(activity, 1, "mouseMoved の owner 配送が活動に繋がらない")
    }
}
