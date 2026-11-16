import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources
import RVDecode

// MARK: - DVD-Video 再生線の統合テスト（#3。03 §4 の連結が engine 経由で成立すること）
//
// 方針（09 §2）: fixture が無い場合は失敗（silent skip しない）。
// 実時間再生の完走検査は AudioPlaybackTests と同じ形。構造検査（itemKind・item 数・
// warning の存在）は決定的に検査する。ISO 経路はマウントの実測に依存するため
// 装置ゲート（attach 失敗環境では完走の数値を主張しない。音声装置ゲートと同方針）。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-dvd-fixture.sh で生成する）"
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    var positions: [MediaTime] = []
    var sawEnded = false
    var sawFailed: String?

    func handle(_ event: PlayerEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .phaseChanged(let phase):
            if case .ended = phase { sawEnded = true }
            if case .failed(let error) = phase { sawFailed = error.userMessage }
        case .positionUpdated(let position, _, _):
            positions.append(position)
        default:
            break
        }
    }

    var done: Bool { lock.lock(); defer { lock.unlock() }; return sawEnded || sawFailed != nil }
    var failedMessage: String? { lock.lock(); defer { lock.unlock() }; return sawFailed }
    var endedFlag: Bool { lock.lock(); defer { lock.unlock() }; return sawEnded }
    var collectedPositions: [MediaTime] { lock.lock(); defer { lock.unlock() }; return positions }
}

final class VideoTsPlaybackTests: XCTestCase {
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVPlaybackEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("fixtures/generated")
    }

    private func dvdRoot() throws -> URL {
        let url = fixturesDir.appendingPathComponent("dvd-video-ts-01")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFixture(path: url.path)
        }
        return url
    }

    private func playToEnd(_ source: any MediaSource, item: ItemID = ItemID(1))
        async throws -> (PlaybackOutcome, SnapshotBox)
    {
        let engine = EngineCore()
        let events = await engine.events()
        try await engine.load(source, selection: PlaybackSelection(item: item))
        let box = SnapshotBox()
        let consumer = Task {
            for await event in events {
                box.handle(event)
                if box.done { break }
            }
        }
        await engine.play()
        // 6 s 素材 + 連結の一時コピー + prefill。実時間駆動に対する安全側上限。
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !box.done {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        consumer.cancel()
        let outcome = await engine.playbackOutcome() ?? PlaybackOutcome()
        await engine.close()
        return (outcome, box)
    }

    // MARK: - 1. VIDEO_TS フォルダを開いて多重 VOB タイトルを最後まで再生する

    func testVideoTsFolderPlaysThroughMultiVobTitle() async throws {
        let root = try dvdRoot()
        let (outcome, box) = try await playToEnd(VideoTsMediaSource(rootURL: root))

        XCTAssertNil(box.failedMessage, "再生が失敗した: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "phase .ended に到達しない")

        // 兼実測（2026-11-17、segment 経路への差し替え時): VTS_01 は母素材
        // （ntsc480i-ac3-01.mpg 単一ファイル実測 180。#10/#12）の keyframe 整合 2 分割。
        // 無連結 segment 経路の実測は 176 = 86 + 90。境界で落ちる 4 帧は open GOP 素材の
        // forward reference による part 単体復号不能 frame（SegmentPSDemuxerTests §2 で
        // 実測・契約化。実 DVD の closed-GOP cell 分割ではこの喪失は起きない — PICHI
        // 実盤で part 全体が通る実測済み）。
        XCTAssertEqual(outcome.demuxedSampleCount, 176,
                       "多重 VOB 経由の demux 実数が segment 経路の実測（176）と違う（境界退行）")
        XCTAssertEqual(outcome.stats.presented, 176)

        // 位置は part 境界（VTS_01_1 の track 終端 ≈ 3.04 s。実測）を跨いで進む。
        let positions = box.collectedPositions.map(\.seconds)
        XCTAssertFalse(positions.isEmpty, "position イベントが 1 つも届かない（配線されていない）")
        if positions.count >= 2 {
            for i in 1..<positions.count {
                XCTAssertGreaterThanOrEqual(positions[i], positions[i - 1] - 1e-9,
                                           "position \(i) が逆行している（02 §4 の位置契約）")
            }
        }
        XCTAssertGreaterThan(positions.max() ?? -1, 5.5, "終端付近まで進まない")
        let crossed = positions.filter { $0 > 3.1 && $0 < 3.4 }
        XCTAssertFalse(crossed.isEmpty, "part1→part2 の境界区間（3.1〜3.4 s）の位置が無い")
    }

    // MARK: - 2. 構造（dvdTitles）と warning が engine を通って届く

    func testVideoTsStructureReachesEngineWithWarnings() async throws {
        let root = try dvdRoot()
        let engine = EngineCore()
        try await engine.load(VideoTsMediaSource(rootURL: root),
                              selection: PlaybackSelection(item: ItemID(1)))
        defer { Task { await engine.close() } }
        guard let structure = await engine.currentStructure() else {
            return XCTFail("structure が無い")
        }
        XCTAssertEqual(structure.itemKind, .dvdTitles)
        // fixture の実測（2026-11-17 更新）: menu（VMGM・VIDEO_TS.VOB）+ VTS_01（多重）+
        // VTS_02（単一）。menu は titleNumber 0 / ItemID(0) で列の先頭（03 §5 の menu 約束）。
        // IFO は 0 バイト。
        XCTAssertEqual(structure.items.map(\.titleNumber), [0, 1, 2], "タイトル列（menu 先頭）が engine に届かない")
        XCTAssertEqual(structure.items.map(\.id), [ItemID(0), ItemID(1), ItemID(2)])
        let menu = structure.items[0]
        XCTAssertNotNil(menu.videoFormat, "menu の videoFormat が無い（first-play 配線の前提）")
        if let menuDuration = menu.duration {
            XCTAssertGreaterThan(menuDuration.seconds, 3.5, "menu duration が足りない（VIDEO_TS.VOB が probe できていない）: \(menuDuration.seconds)")
            XCTAssertLessThan(menuDuration.seconds, 4.5, "menu duration が過大: \(menuDuration.seconds)")
        } else {
            XCTFail("menu item に duration が無い")
        }
        let vts1 = structure.items[1]
        XCTAssertEqual(vts1.trackTable.filter { $0.kind == .video }.count, 1,
                       "連結後のトラック表に映像が 1 本で無い（03 §4）")
        XCTAssertNotNil(vts1.videoFormat, "wirePipeline が要求する videoFormat が無い")
        // #3 受入基準: 「IFO が読めない」系の警告が列挙されている。
        XCTAssertTrue(structure.warnings.contains { $0.code == .unreadableIFO },
                      "IFO 系の warning が structure に載っていない")
        // duration は連結後の実測（母素材の declared ≈ 5.97 s と同じ量。実測対応）。
        if let duration = vts1.duration {
            XCTAssertGreaterThan(duration.seconds, 5.5, "連結後の duration が足りない: \(duration.seconds)")
            XCTAssertLessThan(duration.seconds, 6.5, "連結後の duration が過大: \(duration.seconds)")
        } else {
            XCTFail("duration が無い（母素材側は付いている）")
        }
    }

    // MARK: - 3. DVD-Video でないフォルダは構造化エラー（「DVD を検出できません」の種）

    func testNonDvdDirectoryFailsStructured() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-dvd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = EngineCore()
        do {
            try await engine.load(VideoTsMediaSource(rootURL: root),
                                  selection: PlaybackSelection(item: ItemID(1)))
            XCTFail("DVD-Video でないフォルダが open できた")
        } catch let error as PlaybackError {
            guard case .source(let kind) = error.kind else {
                return XCTFail("kind が source でない: \(error.kind)")
            }
            XCTAssertEqual(kind, .unsupportedStructure)
            XCTAssertTrue(error.userMessage.contains("DVD-Video"),
                          "userMessage がDVD検出の案内になっていない: \(error.userMessage)")
        }
    }

    // MARK: - 4. 合成 ISO（装置ゲート: diskutil image attach が動くこと）

    func testSynthesizedISOPlaysThroughMountedPath() async throws {
        let isoURL = fixturesDir.appendingPathComponent("dvd-iso-01.iso")
        guard FileManager.default.fileExists(atPath: isoURL.path) else {
            throw MissingFixture(path: isoURL.path)
        }
        let source = DiscImageMediaSource(isoURL: isoURL)
        // どの経路でもマウントを取り残さない（実測: 取り残すと次の実行の /Volumes が混む）。
        defer { Task { await source.close() } }
        // 装置ゲート: マウントできない環境（CI の実行制約等）では完走の数値を主張しない。
        // attach の失敗在这里で分かる（open が unsupportedStructure を投げる）。
        let engine = EngineCore()
        let events = await engine.events()
        do {
            try await engine.load(source, selection: PlaybackSelection(item: ItemID(1)))
        } catch let error as PlaybackError {
            print("ISO device-gate: diskutil attach/open 不可 — \(error.userMessage)")
            return
        }
        let box = SnapshotBox()
        let consumer = Task {
            for await event in events {
                box.handle(event)
                if box.done { break }
            }
        }
        await engine.play()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !box.done {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        consumer.cancel()
        let outcome = await engine.playbackOutcome() ?? PlaybackOutcome()
        await engine.close()
        await source.close()   // マウント解除（テスト後始末。実測: eject が残っていると次実行が汚れる）

        XCTAssertNil(box.failedMessage, "ISO 再生が失敗した: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "ISO 経由で phase .ended に到達しない")
        XCTAssertEqual(outcome.demuxedSampleCount, 176,
                       "ISO 経由の demux 実数が segment 経路の実測（176。§2 の検査と同値）と違う")
    }
    // MARK: - 5. タイトル切り替え: 別素材のタイトル 2 を選ぶとそちらが再生される
    //
    // 実測（2026-11-17、vts2count probe）: VTS_02（truncated-01 複製）は
    // total=122 / valid=120 / lastPTS=3.971s。タイトル 1（母素材単一ファイル 180 /
    // segment 経路 176）と数値で区別できる。この検査が兼実測で、engine 側の厳密値を固定する。

    func testTitleSwitchPlaysSecondTitle() async throws {
        let root = try dvdRoot()
        let engine = EngineCore()
        let events = await engine.events()
        try await engine.load(VideoTsMediaSource(rootURL: root),
                              selection: PlaybackSelection(item: ItemID(1)))
        await engine.select(item: ItemID(2))

        let snap = await engine.snapshot()
        XCTAssertEqual(snap.selected?.item, ItemID(2), "選択が更新されない")
        guard let duration = snap.duration else {
            return XCTFail("duration がタイトル 2 の長さに更新されない（selectedItem 未反映）")
        }
        XCTAssertGreaterThan(duration.seconds, 3.5, "duration が短すぎる: \(duration.seconds)")
        XCTAssertLessThan(duration.seconds, 4.5, "duration が古い item のまま: \(duration.seconds)")

        let box = SnapshotBox()
        let consumer = Task {
            for await event in events {
                box.handle(event)
                if box.done { break }
            }
        }
        await engine.play()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !box.done {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        consumer.cancel()
        let outcome = await engine.playbackOutcome() ?? PlaybackOutcome()
        await engine.close()

        XCTAssertNil(box.failedMessage, "タイトル 2 の再生が失敗: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "タイトル 2 で phase .ended に到達しない")
        // 兼実測で厳密値を固定（2026-11-17 実測）: engine 経由で 120/120 で完走。
        // （raw probe では total=122 — 0 長 marker 2 件は demux 縁の間引きで除かれる OQ-23 の意味論）。
        // タイトル 1 の 180 とは明確に区別される。
        XCTAssertEqual(outcome.demuxedSampleCount, 120,
                       "タイトル 2 の実測（120）と違う: \(outcome.demuxedSampleCount)")
        XCTAssertEqual(outcome.stats.presented, 120)
        print("title-2 e2e: demux=\(outcome.demuxedSampleCount) presented=\(outcome.stats.presented)")
        let positions = box.collectedPositions.map(\.seconds)
        for i in 1..<positions.count {
            XCTAssertGreaterThanOrEqual(positions[i], positions[i - 1] - 1e-9, "position 逆行（02 §4）")
        }
        XCTAssertLessThan(positions.max() ?? 0, 4.4, "タイトル 2 の終端（4.0 s 級）を超えて進む: \(positions.max() ?? -1)")
    }

    // MARK: - 6. open は冪等（タイトル切り替えの再 load で再 probe・再連結・再 attach をしない）

    func testOpenIsIdempotentAndKeepsDemuxerIdentity() async throws {
        let source = VideoTsMediaSource(rootURL: try dvdRoot())
        let first = try await source.open()
        let second = try await source.open()
        XCTAssertEqual(second.structure.items.map(\.id), first.structure.items.map(\.id))
        XCTAssertEqual(second.structure.items.count, 3, "menu + 2 タイトルの冪等列にならない")
        // demuxer の同一实例契約: 再 open をまたいも同じ instance（track id 対応の担保 —
        // DemuxerProviding.swift の注記。切り替え経路で新しい instance になると壊れる）。
        let d1 = await source.makeDemuxer(itemId: ItemID(2))
        let d2 = await source.makeDemuxer(itemId: ItemID(2))
        XCTAssertTrue((d1 as AnyObject) === (d2 as AnyObject), "demuxer の实例が変わった")
    }

    // MARK: - 7. menu（VIDEO_TS.VOB）は通常の VOB チェーンとして engine を通って再生できる
    //
    // first-play の政策（auto-select/auto-play、menu ended → 本体タイトルへ自動進行）は
    // PlayerViewModel 側（PlayerViewModelTests で検査）。ここでは engine 経路の材料
    // （ItemID(0) が選べて最後まで読める）だけ固定する。menu 素材は truncated-01 の
    // 複製（gen-dvd-fixture.sh）で、実測 120 sample（タイトル 2 と同一素材・同一実数。
    // 数値の区別は item 列と duration で立つ — §2 の検査）。
    func testMenuItemPlaysThroughEngineToTheEnd() async throws {
        let root = try dvdRoot()
        let (outcome, box) = try await playToEnd(VideoTsMediaSource(rootURL: root), item: ItemID(0))
        XCTAssertNil(box.failedMessage, "menu 再生が失敗した: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "menu で phase .ended に到達しない")
        XCTAssertEqual(outcome.demuxedSampleCount, 120,
                       "menu の demux 実数が素材実測（truncated-01 同一 = 120）と違う")
        let positions = box.collectedPositions.map(\.seconds)
        XCTAssertFalse(positions.isEmpty, "menu で position イベントが届かない")
        for i in 1..<positions.count {
            XCTAssertGreaterThanOrEqual(positions[i], positions[i - 1] - 1e-9, "position 逆行（02 §4）")
        }
        XCTAssertGreaterThan(positions.max() ?? -1, 3.5, "menu 終端付近まで進まない")
    }
}
