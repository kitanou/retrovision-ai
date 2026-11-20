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

    func testInputIsIgnoredWithoutAMenu() async {
        let engine = DefaultPlayerEngine()
        let handled = await engine.menuInput(.activate)
        XCTAssertFalse(handled)
    }
}
