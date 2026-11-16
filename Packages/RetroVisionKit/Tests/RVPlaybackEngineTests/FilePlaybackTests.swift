import CoreMedia
import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources
import RVDecode

// MARK: - 再生線の統合テスト（#11。02 §2 の実行系・04 §9 の計測点）
//
// 方針（09 §2）: fixture が無い場合は失敗（silent skip で環境差を隠さない）。
// 1 本目は時間源を注入して決定的に（DeterministicTimeSource）、
// 2 本目は EngineCore を通した実時間再生（SystemTimeSource）を検査する。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-fixtures.sh で生成する）"
    }
}

/// セッションイベントの受け取り箱（report 口は @Sendable 同期コールバックのため、
/// actor を跨がない可変状態をロックで守る）。
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _positions: [MediaTime] = []
    private var _outcome: PlaybackOutcome?

    func append(_ event: PlaybackSession.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .position(let pts): _positions.append(pts)
        case .finished(let outcome): _outcome = outcome
        }
    }

    var positions: [MediaTime] { lock.lock(); defer { lock.unlock() }; return _positions }
    var outcome: PlaybackOutcome? { lock.lock(); defer { lock.unlock() }; return _outcome }
}

final class FilePlaybackTests: XCTestCase {
    private var fixturesDir: URL {
        // Tests/RVPlaybackEngineTests/ ← Packages/RetroVisionKit/ ← リポジトリルート
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVPlaybackEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // RetroVisionKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("fixtures/generated")
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let url = fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFixture(path: url.path)
        }
        return url
    }

    private func videoTrack(of stream: ProbedStream) throws -> (TrackInfo, VideoFormatDescription) {
        guard let track = stream.tracks.first(where: { $0.kind == .video }),
              case let .video(format) = track.format else {
            throw MissingFixture(path: "video track not found")
        }
        return (track, format)
    }

    private func strictlyIncreasing(_ times: [MediaTime], _ file: StaticString = #filePath,
                                   _ line: UInt = #line) {
        for i in 1..<times.count {
            // times[i-1] < times[i] であること（ascending は「self < other」の意味）。
            XCTAssertEqual(times[i - 1].compared(to: times[i]), .orderedAscending,
                           "position \(i) が PTS 順（strictly increasing）でない",
                           file: file, line: line)
        }
    }

    // MARK: - 1. PlaybackSession 単体（決定的時間源）

    /// 1 ms ずつ時間を進めて step() を回す駆動で、全帧が PTS 順に 1 回だけ提示されること。
    /// late は 0（1 ms 解像度の取り分、遅延は lateThresholdMS=2 ms に収まる）。
    func testSessionStepsThroughFixtureInPTSOrder() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let box = EventBox()
        let session = PlaybackSession(
            demuxer: demuxer,
            decoder: VideoToolboxDecoder(),
            config: .init(videoTrack: track.id, videoFormat: format),
            time: time,
            report: { box.append($0) })

        // 12 帧 × 33.37 ms ≈ 400 ms。安全側に 5000 呼吸（1 ms × 5 s 相当）で打ち切る。
        var iterations = 0
        while !(await session.isFinished()) && iterations < 5_000 {
            await session.step()
            time.advance(ms: 1)
            iterations += 1
        }

        let outcome = await session.outcomeSnapshot()
        let didFinish = await session.isFinished()
        XCTAssertTrue(didFinish, "有限時間で終了しない")
        XCTAssertEqual(outcome.demuxedSampleCount, 12)
        XCTAssertEqual(outcome.stats.presented, 12,
                       "demux した全帧が提示される（late でも presented に数える）")
        XCTAssertEqual(outcome.stats.late, 0, "決定的駆動で late は出てはならない")
        XCTAssertEqual(outcome.stats.dropped, 0)
        XCTAssertEqual(outcome.errors, [])

        // 提示順序は PTS 順（F13 の順序保証がセッションでも壊れていないこと）。
        XCTAssertEqual(box.positions.count, 12)
        strictlyIncreasing(box.positions)

        // 提示間隔はメディアの pts 間隔に追随していること（±2 ms 以内: 1 ms 量子と
        // lateThresholdMS の取り分）。素材自体の pts 穴あき（切り詰め素材の後半に
        // 1 帧分の欠落がある）はそのまま間隔に出るため、固定値では検査しない。
        XCTAssertEqual(outcome.presentIntervalMS.count, box.positions.count - 1)
        for i in 0..<outcome.presentIntervalMS.count {
            let expectedMS = (box.positions[i + 1].seconds - box.positions[i].seconds) * 1_000
            let interval = outcome.presentIntervalMS[i]
            XCTAssertGreaterThanOrEqual(interval, expectedMS - 2,
                                       "提示が締切より詰めすぎ（間隔 \(interval) < 期待 \(expectedMS)）")
            XCTAssertLessThanOrEqual(interval, expectedMS + 2,
                                    "提示が締切から遅れすぎ（間隔 \(interval) > 期待 \(expectedMS)）")
        }
    }

    /// pause/resume でクロックの基点がずれていないこと（停止区間が後方遅延に積算されない）。
    func testPauseResumesWithoutAccumulatingDelay() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let session = PlaybackSession(
            demuxer: demuxer,
            decoder: VideoToolboxDecoder(),
            config: .init(videoTrack: track.id, videoFormat: format),
            time: time)

        await session.step()                     // 先頭帧を提示（基点確定）
        await session.pause()
        time.advance(ms: 5_000)                  // 停止中（進めないこと）
        for _ in 0..<10 { await session.step() }
        let paused = await session.outcomeSnapshot()
        XCTAssertEqual(paused.stats.presented, 1, "停止中は進行しない")

        await session.resume()
        // 再開から 1 帧分進めれば次帧が来る（停止中の 5 s は遅延として効かない）。
        for _ in 0..<40 {
            await session.step()
            time.advance(ms: 1)
        }
        let afterResume = await session.outcomeSnapshot()
        XCTAssertGreaterThanOrEqual(afterResume.stats.presented, 2)
        XCTAssertLessThan(afterResume.stats.late, 2, "停止区間が late に積算されていない")
    }

    // MARK: - 2. EngineCore 経由の実時間再生（G1 前半資料の回路そのもの）

    /// truncated-01-cut を EngineCore で最初まで再生し、phase .ended と全帧提示を検査する。
    func testEnginePlaysTruncatedFixtureToEnd() async throws {
        final class EngineEventBox: @unchecked Sendable {
            private let lock = NSLock()
            var positions: [MediaTime] = []
            var sawEnded = false
            var sawFailed: String?
            var statisticsFrames: FrameStats?

            func handle(_ event: PlayerEvent) {
                lock.lock(); defer { lock.unlock() }
                switch event {
                case .phaseChanged(let phase):
                    if case .ended = phase { sawEnded = true }
                    if case .failed(let error) = phase { sawFailed = error.userMessage }
                case .positionUpdated(let position, _, _):
                    positions.append(position)
                case .statisticsUpdated(let summary):
                    statisticsFrames = summary.frames
                default:
                    break
                }
            }

            var done: Bool { lock.lock(); defer { lock.unlock() }; return sawEnded || sawFailed != nil }
            var failedMessage: String? { lock.lock(); defer { lock.unlock() }; return sawFailed }
            var endedFlag: Bool { lock.lock(); defer { lock.unlock() }; return sawEnded }
            var frames: FrameStats? { lock.lock(); defer { lock.unlock() }; return statisticsFrames }
            var collectedPositions: [MediaTime] { lock.lock(); defer { lock.unlock() }; return positions }
        }

        let url = try fixtureURL("truncated-01-cut.mpg")
        let engine = EngineCore()
        let events = await engine.events()
        try await engine.load(FileMediaSource(url: url),
                              selection: PlaybackSelection(item: ItemID(1)))

        let box = EngineEventBox()
        let consumer = Task {
            for await event in events {
                box.handle(event)
                if box.done { break }
            }
        }

        await engine.play()
        // 0.4 s 素材。実時間駆動 + 安全側の上限で終了を待つ。
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !box.done {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        consumer.cancel()

        XCTAssertNil(box.failedMessage, "再生が失敗した: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "phase .ended に到達しない")

        let outcome = await engine.playbackOutcome()
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.demuxedSampleCount, 12)
        XCTAssertEqual(outcome?.stats.presented, 12)
        // statisticsUpdated は同じ統計を運ぶ（UI の診断表示の回路）。
        XCTAssertEqual(box.frames?.presented, 12)
        // 実時間係数は 1.0 近傍（G1 の基準: 29.97 fps が破綻しない）。
        if let outcome, outcome.totalWallMS > 0 {
            let factor = outcome.mediaDurationMS / outcome.totalWallMS
            XCTAssertGreaterThan(factor, 0.9, "realTimeFactor 低すぎ: \(factor)")
            XCTAssertLessThan(factor, 1.1)
        }
        strictlyIncreasing(box.collectedPositions)
    }

    /// snapshot の position が再生中に進行すること（UI 向けの位置表示の回路）。
    func testEngineSnapshotPositionAdvances() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let engine = EngineCore()
        try await engine.load(FileMediaSource(url: url),
                              selection: PlaybackSelection(item: ItemID(1)))
        await engine.play()
        var observed: [Double] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let position = await engine.snapshot().position.seconds
            if position > 0 { observed.append(position) }
            let outcome = await engine.playbackOutcome()
            if outcome != nil { break }   // finished 後は snapshot.position が進まない
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await engine.close()
        XCTAssertFalse(observed.isEmpty, "position が一度も進行しなかった")
        XCTAssertGreaterThan(observed.max() ?? 0, 0.2,
                             "0.4 s 素材の最後まで位置が進まない")
    }
}
