import CoreMedia
import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources

/// タイトルメニュー（VTS_nn_0.VOB。静止画 1 枚）が、構造の項目として並ぶこと。
/// 実盤の並び: VMGM（ロゴ）→ タイトルメニュー（静止画）→ 本体。
final class VideoTsTitleMenuTests: XCTestCase {
    private var generated: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/generated")
    }

    /// VIDEO_TS.VOB（ロゴ）= truncated-01、VTS_01_0.VOB（タイトルメニュー）= menu-still-01、VTS_01_1.VOB（本体）= truncated-01。
    private func makeDisc() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("videots-menu-\(UUID().uuidString)")
        let ts = root.appendingPathComponent("VIDEO_TS")
        try FileManager.default.createDirectory(at: ts, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: generated.appendingPathComponent("truncated-01.mpg"), to: ts.appendingPathComponent("VIDEO_TS.VOB"))
        try fm.copyItem(at: generated.appendingPathComponent("menu-still-01.vob"), to: ts.appendingPathComponent("VTS_01_0.VOB"))
        try fm.copyItem(at: generated.appendingPathComponent("truncated-01.mpg"), to: ts.appendingPathComponent("VTS_01_1.VOB"))
        return root
    }

    func testStructureListsTheLogoThenTheTitleMenuStillThenTheTitle() async throws {
        let root = try makeDisc()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VideoTsMediaSource(rootURL: root)
        let structure = try await source.open().structure

        XCTAssertEqual(structure.items.map(\.id), [ItemID(0), ItemID(1_001), ItemID(1)], "並びは VMGM → タイトルメニュー → 本体")
        XCTAssertEqual(structure.items.map { $0.titleNumber ?? -1 }, [0, 0, 1], "menu は titleNumber 0")
        XCTAssertEqual(structure.items.map(\.stillImage), [false, true, false], "静止画はタイトルメニューだけ")
        let still = structure.items[1]
        XCTAssertEqual(still.duration?.seconds ?? 0, 1001.0 / 30000.0, accuracy: 1e-6, "静止画の長さは 1 frame")
        XCTAssertNotNil(still.videoFormat)
        XCTAssertFalse(structure.warnings.contains { $0.code == .containerUnreadable }, "タイトルメニューが読めない警告が出た: \(structure.warnings)")
        await source.close()
    }

    func testTheDemuxerForTheTitleMenuIsTheStillDemuxerAndYieldsASample() async throws {
        let root = try makeDisc()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VideoTsMediaSource(rootURL: root)
        _ = try await source.open()
        let demuxer = await source.makeDemuxer(itemId: ItemID(1_001))
        let stream = try await demuxer.probe()
        let track = try XCTUnwrap(stream.tracks.first { $0.kind == .video })
        var count = 0
        for try await _ in await demuxer.samples(for: track.id) { count += 1 }
        XCTAssertEqual(count, 1, "タイトルメニューから sample が 1 枚取り出せない")
        await source.close()
    }
}
