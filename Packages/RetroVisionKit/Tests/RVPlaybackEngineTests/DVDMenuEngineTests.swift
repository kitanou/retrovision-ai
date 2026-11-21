import CoreMedia
import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources

/// 合成メニュー盤（fixtures/generated/dvd-menu-01）で、メニューの選択から本編への移動までを通す。
@MainActor
final class DVDMenuEngineTests: XCTestCase {
    private var disc: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/generated/dvd-menu-01")
    }

    private func openMenu() async throws -> (DefaultPlayerEngine, VideoTsMediaSource) {
        guard FileManager.default.fileExists(atPath: disc.appendingPathComponent("VIDEO_TS/VTS_01_0.IFO").path) else {
            throw XCTSkip("fixture が無い（python3 Scripts/gen-menu-fixture.py で生成する）")
        }
        let source = VideoTsMediaSource(rootURL: disc)
        let engine = DefaultPlayerEngine()
        _ = try await engine.load(source, selection: PlaybackSelection(item: ItemID(1_001)))
        for _ in 0..<100 where !engine.isMenuActive { try await Task.sleep(nanoseconds: 50_000_000) }
        return (engine, source)
    }

    func testMenuBecomesActiveOnTheTitleMenuItem() async throws {
        let (engine, source) = try await openMenu()
        XCTAssertTrue(engine.isMenuActive)
        await engine.close()
        await source.close()
        XCTAssertFalse(engine.isMenuActive)
    }

    func testActivatingTheThirdButtonPlaysTitle2AndLeavesTheMenu() async throws {
        let (engine, source) = try await openMenu()
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.activate)
        XCTAssertEqual(engine.stateSnapshot.selected?.item, ItemID(1), "本体の item に移る")
        XCTAssertFalse(engine.isMenuActive, "本編に移ったらメニューは外れる")
        await engine.close()
        await source.close()
    }

    /// 本編を最後まで再生すると、PGC の POST（GPRM12 = 1 → 自分へ Link）→ PRE（GPRM12 == GPRM15 でメニューを呼ぶ）で
    /// タイトルメニューへ戻る。レジスタはメニュー・本編を通して持ち回る。
    private func waitForMenu(_ engine: DefaultPlayerEngine, seconds: Double = 20) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if engine.isMenuActive, engine.stateSnapshot.selected?.item == ItemID(1_001) { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func testPlayingATitleToTheEndReturnsToTheTitleMenu() async throws {
        let (engine, source) = try await openMenu()
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.activate)       // タイトル 2 を再生
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(engine.isMenuActive, "再生中はメニューが外れている")
        let back = try await waitForMenu(engine)
        XCTAssertTrue(back, "本編の終わりでメニューに戻る（POST → PRE の条件つき CallSS）")
        await engine.close()
        await source.close()
    }

    /// 戻ったメニューでもう一度選んで再生できる（レジスタが残っていても、PRE の GPRM15 = 1 が先に走る）。
    func testTheMenuCanStartAnotherTitleAfterReturning() async throws {
        let (engine, source) = try await openMenu()
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.activate)
        let first = try await waitForMenu(engine)
        XCTAssertTrue(first)
        _ = await engine.menuInput(.activate)       // 選択は 1 番（タイトル 1 の先頭）
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(engine.isMenuActive, "2 回目も本編に入る（メニューに戻されっぱなしにならない）")
        let second = try await waitForMenu(engine)
        XCTAssertTrue(second, "2 回目の終わりでもメニューに戻る")
        await engine.close()
        await source.close()
    }

    func testShowMenuDuringPlaybackReturnsToTheTitleMenu() async throws {
        let (engine, source) = try await openMenu()
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.down)
        _ = await engine.menuInput(.activate)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(engine.isMenuActive, "本編の再生中")
        await engine.showMenu()
        let back = try await waitForMenu(engine, seconds: 5)
        XCTAssertTrue(back, "再生中の「メニュー」操作でメニューに戻る")
        await engine.close()
        await source.close()
    }

    func testInputIsIgnoredWithoutAMenu() async {
        let engine = DefaultPlayerEngine()
        let handled = await engine.menuInput(.activate)
        XCTAssertFalse(handled)
    }
}
