import Foundation
import XCTest
@testable import RVMediaSources
import RVMediaCore

// MARK: - VIDEO_TS 走査の検査（03 §3、§4。#3 v1 = ファイル名列挙）
//
// 方針（09 §2）: 合成 fixture（Git に載る dvd-video-ts-01）に対する検査と、
// 一時ディレクトリへの合成構造に対する検査の両方を行う。fixture が無ければ失敗。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-dvd-fixture.sh で生成する）"
    }
}

final class VideoTsNavigatorTests: XCTestCase {
    private var fixturesDir: URL {
        // Tests/RVMediaSourcesTests/ ← Packages/RetroVisionKit/ ← リポジトリルート
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVMediaSourcesTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("fixtures/generated")
    }

    private func tempTree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videots-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("VIDEO_TS"),
                                               withIntermediateDirectories: true)
        for name in files {
            FileManager.default.createFile(atPath: root.appendingPathComponent("VIDEO_TS/\(name)").path,
                                          contents: Data())
        }
        return root
    }

    // MARK: 1. DVD-Video でないものは nil（呼び出し側が「開けない」を構成できる）

    func testNoVideoTsReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videots-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("movie.mpg").path, contents: Data())
        XCTAssertNil(VideoTsNavigator.chains(in: root))
    }

    // MARK: 2. 合成 fixture のタイトル列（実素材配置での兼実測）

    func testFixtureTitleEnumeration() throws {
        let root = fixturesDir.appendingPathComponent("dvd-video-ts-01")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MissingFixture(path: root.path)
        }
        guard let found = VideoTsNavigator.chains(in: root) else {
            return XCTFail("VIDEO_TS が見付からない（fixture 配置の実測）")
        }
        // fixture の実測配置（2026-11-17 更新）: menu（VIDEO_TS.VOB）+ VTS_01（2 part）+
        // VTS_02（1 part）。IFO は 0 バイトダミー。menu は列の先頭（03 §5 の menu 約束）。
        XCTAssertEqual(found.chains.map(\.vtsNumber), [0, 1, 2], "タイトル列が menu 先頭・昇順で決定的でない")
        XCTAssertTrue(found.chains[0].isMenu, "先頭が menu チェーンとして立っていない（VMGM 検出）")
        XCTAssertEqual(found.chains[0].partURLs.map(\.lastPathComponent), ["VIDEO_TS.VOB"])
        let vts1 = found.chains[1]
        XCTAssertFalse(vts1.isMenu)
        XCTAssertEqual(vts1.partURLs.map(\.lastPathComponent),
                       ["VTS_01_1.VOB", "VTS_01_2.VOB"], "多重 VOB の順序が連結順でない（03 §4）")
        XCTAssertEqual(found.chains[2].partURLs.map(\.lastPathComponent), ["VTS_02_1.VOB"])
        // IFO は 0 バイト（gen-dvd-fixture.sh の実測）。v1 は「読めない」として warning を要求する。
        XCTAssertTrue(found.warnings.contains { $0.code == .unreadableIFO },
                      "IFO が読めない/無いことの warning が無い（#3 受入基準）")
        XCTAssertFalse(vts1.hasIfo, "0 バイトの VTS IFO が存在扱いになっている（VTS_nn_0/1.IFO は作らない配置）")
    }

    // MARK: 3. VIDEO_TS を直接選ばれた場合も使える（App のディレクトリ選択の実運用）

    func testVideoTsFolderGivenDirectly() throws {
        let root = fixturesDir.appendingPathComponent("dvd-video-ts-01/VIDEO_TS")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw MissingFixture(path: root.path)
        }
        let found = VideoTsNavigator.chains(in: root)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.chains.count, 3, "menu + VTS 01 + VTS 02 の列にならない")
    }

    // MARK: 4. 構造の異常は warning で残す（#3 受入基準の最初の項）

    func testPartGapIsTrimmedWithWarning() throws {
        let root = try tempTree(["VTS_03_1.VOB", "VTS_03_3.VOB", "VTS_03_0.IFO"])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let found = VideoTsNavigator.chains(in: root) else { return XCTFail("VIDEO_TS が見付からない") }
        XCTAssertEqual(found.chains.count, 1)
        XCTAssertEqual(found.chains[0].partURLs.count, 1,
                       "飛んだ part 以降を連結範囲に含めている（繋がらない素材を繋がない）")
        XCTAssertTrue(found.warnings.contains { $0.code == .missingVOB },
                      "part 飛びの warning が無い")
        XCTAssertTrue(found.chains[0].hasIfo, "VTS_03_0.IFO があるのに hasIfo でない")
    }

    func testChainWithoutFirstPartIsDroppedWithWarning() throws {
        let root = try tempTree(["VTS_04_2.VOB"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = VideoTsNavigator.chains(in: root)
        XCTAssertEqual(found?.chains.count, 0, "先頭 part の無い VTS をタイトルにしている")
        XCTAssertTrue(found?.warnings.contains { $0.code == .missingVOB } == true)
    }

    func testZeroByteVtsIfoWarns() throws {
        let root = try tempTree(["VTS_05_1.VOB", "VTS_05_0.IFO"])   // createFile(contents: Data()) = 0 バイト
        defer { try? FileManager.default.removeItem(at: root) }
        let found = VideoTsNavigator.chains(in: root)
        XCTAssertTrue(found?.chains.first?.hasIfo == true, "0 バイトでも IFO の「存在」は事実として立つ")
        XCTAssertTrue(found?.warnings.contains { $0.code == .unreadableIFO } == true,
                      "0 バイト IFO を「読めない」として残していない")
    }

    // MARK: 5. menu（VMGM）検出（03 §5 のメニュー増分。VIDEO_TS.VOB の有無で列が変わる）

    func testMenuChainDetectedFirstWhenPresent() throws {
        let root = try tempTree(["VIDEO_TS.VOB", "VIDEO_TS.IFO", "VTS_07_1.VOB"])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let found = VideoTsNavigator.chains(in: root) else { return XCTFail("VIDEO_TS が見付からない") }
        XCTAssertEqual(found.chains.map(\.vtsNumber), [0, 7], "menu が先頭、続いて VTS の順でない")
        XCTAssertTrue(found.chains[0].isMenu)
        XCTAssertTrue(found.chains[0].hasIfo, "VIDEO_TS.IFO があるのに menu chain の hasIfo でない")
        XCTAssertEqual(found.chains[0].partURLs.map(\.lastPathComponent), ["VIDEO_TS.VOB"])
        XCTAssertFalse(found.chains[1].isMenu)
    }

    // MARK: 5b. タイトルメニュー（VTS_nn_0.VOB。実盤の「本当のメニュー」の静止画）

    private func tempTree(sized files: [(name: String, bytes: Int)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("videots-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("VIDEO_TS"),
                                               withIntermediateDirectories: true)
        for f in files {
            FileManager.default.createFile(atPath: root.appendingPathComponent("VIDEO_TS/\(f.name)").path,
                                          contents: Data(count: f.bytes))
        }
        return root
    }

    func testTitleMenuIsEnumeratedAfterVMGMAndBeforeTheTitles() throws {
        let root = try tempTree(sized: [("VIDEO_TS.VOB", 100), ("VTS_01_0.VOB", 50), ("VTS_01_0.IFO", 10),
                                        ("VTS_01_1.VOB", 200), ("VTS_02_1.VOB", 200)])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let found = VideoTsNavigator.chains(in: root) else { return XCTFail("VIDEO_TS が見付からない") }
        // 並び: VMGM → タイトルメニュー → タイトル本体（昇順）。
        XCTAssertEqual(found.chains.map(\.vtsNumber), [0, 1, 1, 2])
        XCTAssertEqual(found.chains.map(\.isMenu), [true, true, false, false])
        XCTAssertFalse(found.chains[0].isTitleMenu, "VMGM はタイトルメニューではない")
        XCTAssertTrue(found.chains[1].isTitleMenu)
        XCTAssertEqual(found.chains[1].partURLs.map(\.lastPathComponent), ["VTS_01_0.VOB"])
        XCTAssertTrue(found.chains[1].hasIfo, "VTS_01_0.IFO があるのに hasIfo でない")
        XCTAssertEqual(found.chains[1].label, "VTS_01 menu (VTS_01_0.VOB)")
        // 本体のチェーンにメニューの VOB は混ざらない（part 1 から始まる）。
        XCTAssertEqual(found.chains[2].partURLs.map(\.lastPathComponent), ["VTS_01_1.VOB"])
    }

    func testTitleMenuWithoutTitlesIsStillEnumeratedAndAZeroByteOneIsNot() throws {
        let root = try tempTree(sized: [("VTS_03_0.VOB", 50),          // メニューだけの VTS（本体無し）
                                        ("VTS_04_0.VOB", 0),           // 0 バイト（再生できない）
                                        ("VTS_04_1.VOB", 200)])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let found = VideoTsNavigator.chains(in: root) else { return XCTFail("VIDEO_TS が見付からない") }
        XCTAssertEqual(found.chains.map(\.vtsNumber), [3, 4])
        XCTAssertTrue(found.chains[0].isTitleMenu, "メニューだけの VTS が列挙されない")
        XCTAssertFalse(found.chains[1].isMenu, "0 バイトの VTS_04_0.VOB をメニューとして列挙した")
    }

    func testNoMenuMeansNoMenuChain() throws {
        // menu の無い盘（VTS だけ）では menu 項を作らない（first-play は従来どおり先頭タイトル）。
        let root = try tempTree(["VTS_08_1.VOB"])
        defer { try? FileManager.default.removeItem(at: root) }
        guard let found = VideoTsNavigator.chains(in: root) else { return XCTFail("VIDEO_TS が見付からない") }
        XCTAssertEqual(found.chains.map(\.vtsNumber), [8])
        XCTAssertFalse(found.chains.contains { $0.isMenu })
    }

    func testTitleMenuVOBNeverJoinsTheTitleBodyAndAnEmptyOneIsNotAMenu() throws {
        // VTS_nn_0.VOB（タイトルメニュー）は title 本体の連結に入らない。0 バイトのときは menu 項にもならない
        // （中身のある VTS_nn_0.VOB は menu チェーンとして別に列挙される — 5b）。
        let root = try tempTree(["VTS_09_0.VOB", "VTS_09_1.VOB"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = VideoTsNavigator.chains(in: root)
        XCTAssertEqual(found?.chains.count, 1)
        XCTAssertEqual(found?.chains.first?.partURLs.count, 1, "VTS_09_0.VOB が連結に入っている")
    }
}
