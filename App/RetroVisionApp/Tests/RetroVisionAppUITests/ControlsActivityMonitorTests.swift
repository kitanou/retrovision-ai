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
}
