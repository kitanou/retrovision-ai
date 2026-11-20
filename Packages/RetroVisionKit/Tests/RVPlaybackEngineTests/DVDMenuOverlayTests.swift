import Foundation
import XCTest

@testable import RVPlaybackEngine
import RVMediaSources
import RVVideoPipeline

/// 合成メニュー素材（Scripts/gen-menu-fixture.py の生成物）で、読み込みとオーバーレイ画の合成を確かめる。
final class DVDMenuOverlayTests: XCTestCase {
    private var dir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/generated/dvd-menu-01/VIDEO_TS")
    }

    private func load() throws -> DVDMenuData {
        let vob = dir.appendingPathComponent("VTS_01_0.VOB")
        guard FileManager.default.fileExists(atPath: vob.path) else {
            throw XCTSkip("fixture が無い（python3 Scripts/gen-menu-fixture.py で生成する）")
        }
        return try XCTUnwrap(DVDMenuData.load(vobURL: vob,
                                              ifoURL: dir.appendingPathComponent("VTS_01_0.IFO"),
                                              canvasWidth: 720, canvasHeight: 480))
    }

    private func pixel(_ img: OverlayImage, _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let o = (y * img.width + x) * 4
        return (img.bgra[o], img.bgra[o + 1], img.bgra[o + 2], img.bgra[o + 3])
    }

    func testLoadsButtonsSubpictureAndTitles() throws {
        let data = try load()
        XCTAssertEqual(data.pci.highlight.buttons.count, 3)
        XCTAssertEqual(data.subpicture.width, 100)
        XCTAssertEqual(data.subpicture.height, 240)
        XCTAssertEqual(data.titleSet.titles.count, 2)
        XCTAssertEqual(data.palette.count, 16)
    }

    func testOnlySelectedButtonIsVisible() throws {
        let data = try load()
        let state = DVDMenuState(highlight: data.pci.highlight)
        let img = DVDMenuOverlayRenderer.render(data, state: state)
        // 選択中（ボタン 1: y 100…139）の内側は不透明。他のボタン（y 200…239）は透明。
        XCTAssertGreaterThan(pixel(img, 150, 120).a, 0)
        XCTAssertEqual(pixel(img, 150, 220).a, 0)
        XCTAssertEqual(pixel(img, 10, 10).a, 0)
    }

    func testMovingSelectionMovesHighlight() throws {
        let data = try load()
        var state = DVDMenuState(highlight: data.pci.highlight)
        _ = state.move(.down)
        let img = DVDMenuOverlayRenderer.render(data, state: state)
        XCTAssertEqual(pixel(img, 150, 120).a, 0)
        XCTAssertGreaterThan(pixel(img, 150, 220).a, 0)
    }
}
