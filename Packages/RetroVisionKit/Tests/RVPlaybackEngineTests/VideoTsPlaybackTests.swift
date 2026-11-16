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

        // 兼実測: VTS_01 は母素材（ntsc480i-ac3-01.mpg）の 2 分割で、連結後はバイト一致。
        // engine 経由の demux 実数は母素材の単一ファイル実測（180。#10/#12 の続測）と一致する。
        XCTAssertEqual(outcome.demuxedSampleCount, 180,
                       "多重 VOB 経由の demux 実数が母素材の実測（180）と違う（境界で落ちている可能性）")
        XCTAssertEqual(outcome.stats.presented, 180)

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
        // fixture の実測: VTS_01（多重）と VTS_02（単一）の 2 タイトル。IFO は 0 バイト。
        XCTAssertEqual(structure.items.map(\.titleNumber), [1, 2], "タイトル列が engine に届かない")
        let vts1 = structure.items[0]
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
        XCTAssertEqual(outcome.demuxedSampleCount, 180,
                       "ISO 経由の demux 実数が母素材の実測（180）と違う")
    }
    // MARK: - 5. タイトル切り替え: 別素材のタイトル 2 を選ぶとそちらが再生される
    //
    // 実測（2026-11-17、vts2count probe）: VTS_02（truncated-01 複製）は
    // total=122 / valid=120 / lastPTS=3.971s。タイトル 1（母素材連結 = 180）と
    // 数値で区別できる。この検査が兼実測で、engine 側の厳密値を固定する。

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
        XCTAssertEqual(second.structure.items.count, 2)
        // demuxer の同一实例契約: 再 open をまたいも同じ instance（track id 対応の担保 —
        // DemuxerProviding.swift の注記。切り替え経路で新しい instance になると壊れる）。
        let d1 = await source.makeDemuxer(itemId: ItemID(2))
        let d2 = await source.makeDemuxer(itemId: ItemID(2))
        XCTAssertTrue((d1 as AnyObject) === (d2 as AnyObject), "demuxer の实例が変わった")
    }
}
