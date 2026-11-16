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
        case .position(let pts, _): _positions.append(pts)
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

    // MARK: - 2. 起動準備（prepare / warmup。#12・OQ-18）

    /// prepare() で先頭ぶんを復号済み（保持）にした状態で駆動しても、提示の完全性
    /// （全帧 1 回・PTS 順）は壊れないこと。warmup の復号は warmupStageMS に分離され、
    /// 常時統計（decodeStageMS）に混ざらないこと（#12 の「統計から warmup 分を除外する規則」）。
    func testWarmupPrepareKeepsFullPlaybackAndSeparatesStageStats() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let box = EventBox()
        var config = PlaybackSession.Config(videoTrack: track.id, videoFormat: format)
        config.warmupFrames = 3
        let session = PlaybackSession(
            demuxer: demuxer,
            decoder: VideoToolboxDecoder(),
            config: config,
            time: time,
            report: { box.append($0) })

        // load 相当: 時間を進めずに準備だけ行う（EngineCore の .preparing と同じ形）。
        await session.prepare()
        let afterPrepare = await session.outcomeSnapshot()
        XCTAssertEqual(afterPrepare.warmupStageMS.count, 3,
                       "warmupFrames ぶんの復号が warmupStageMS に記録されていない")
        XCTAssertEqual(afterPrepare.decodeStageMS.count, 0,
                       "warmup の復号が decodeStageMS（常時統計）に混ざった")
        XCTAssertTrue(box.positions.isEmpty, "prepare 中に提示があってはならない")

        // 通常駆動で最後まで（prepare 済みの 3 帧も同じ 1 回だけ提示される）。
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
                       "warmup で先読みした帧が脱落・重複していない")
        XCTAssertEqual(outcome.stats.late, 0)
        XCTAssertEqual(outcome.errors, [])
        XCTAssertEqual(box.positions.count, 12)
        strictlyIncreasing(box.positions)

        // 統計の分離は最後まで保たれる（warmup 3 + 常時 9 = 全 sample）。
        let final = await session.outcomeSnapshot()
        XCTAssertEqual(final.warmupStageMS.count, 3)
        XCTAssertEqual(final.decodeStageMS.count, 12 - 3,
                       "常時統計に warmup 分が混入・または供給が不足")
    }

    /// warmupFrames = 0（warmup なし）では #11 と同じ形になること: 復号統計は全 sample が
    /// decodeStageMS に乗り、分離箱は空。上のテストとの差分で「除外規則」の両辺を固定する。
    func testWithoutWarmupAllDecodesStayInSteadyStats() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        var config = PlaybackSession.Config(videoTrack: track.id, videoFormat: format)
        config.warmupFrames = 0
        let session = PlaybackSession(
            demuxer: demuxer,
            decoder: VideoToolboxDecoder(),
            config: config,
            time: time)

        await session.prepare()               // warmupFrames=0: 復号しない（音声 prefill のみ）
        let afterPrepare = await session.outcomeSnapshot()
        XCTAssertTrue(afterPrepare.warmupStageMS.isEmpty)

        var iterations = 0
        while !(await session.isFinished()) && iterations < 5_000 {
            await session.step()
            time.advance(ms: 1)
            iterations += 1
        }
        let outcome = await session.outcomeSnapshot()
        let didFinish = await session.isFinished()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(outcome.stats.presented, 12)
        XCTAssertTrue(outcome.warmupStageMS.isEmpty)
        XCTAssertEqual(outcome.decodeStageMS.count, 12,
                       "warmup なしの形では全 sample が常時統計に乗る（#11 の形）")
    }

    // MARK: - 3. EngineCore 経由の実時間再生（G1 前半資料の回路そのもの）

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

    // MARK: - 4. seek（#13・OQ-23。決定的駆動）
    /// 実行中のセッションのまま中間 seek: 提示は重複も逆行もなく、target 以上の帧だけが続く。
    /// target 前の帧は復号して捨てる（04 §6 手順 4。dropped(.seekDiscarded) に計上）。
    /// 決定的時間源では 120 帧 = seek 前 30 + target 以降の全 90 帧がちょうど提示される。
    func testSeekMidStreamPresentsTargetOnwardExactlyOnce() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
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

        // 前半: 30 帧提示まで進める（frames 0..29、pts ≤ 0.97 s）。
        var iterations = 0
        var early = false
        while !early && iterations < 5_000 {
            await session.step()
            time.advance(ms: 1)
            iterations += 1
            early = box.positions.count >= 30
        }
        XCTAssertEqual(box.positions.count, 30, "前半が 30 帧まで進まない")

        // seek: target 3.0 s。GOP は 0.5 s（keyframe 2.535 s 側へ着地）。実測では着地直後の
        // 9 sample（frame 76〜88 の一部）を reader 側が届けないため、target 前の破棄は
        // 復号保持ぶん 1 + reader が届けた target 前 6 帧 = 7 になる（実測値は print で残す）。
        let target = CMTime(seconds: 3.0, preferredTimescale: 1_000_000)
        await session.seek(to: target, tolerance: .previousKeyframe)

        // 最後まで続ける（残り 90 帧 ≈ 3.0 s + 安全側）。
        while !(await session.isFinished()) && iterations < 15_000 {
            await session.step()
            time.advance(ms: 1)
            iterations += 1
        }
        let outcome = await session.outcomeSnapshot()
        let didFinish = await session.isFinished()
        XCTAssertTrue(didFinish, "seek 後に有限時間終了しない")
        XCTAssertEqual(outcome.errors, [],
                       "seek 直後に復号・供給の失敗（0 長 buffer は -12902 になる。#13 の間引き）: \(outcome.errors)")

        // 提示の完全性: seek 前 30 + target 以上の fixture 全 90 帧（frame 90 pts = 3.003 s〜）。
        XCTAssertEqual(outcome.stats.presented, 120,
                       "target 以上の帧がすべて 1 回だけ提示され、target 前が再提示されない")
        XCTAssertEqual(box.positions.count, 120)
        strictlyIncreasing(box.positions)   // seek 前後の境界でも PTS は逆行しない
        let afterSeek = box.positions.filter { $0.seconds >= 3.0 }
        XCTAssertEqual(afterSeek.count, 90, "target 以上の 90 帧がすべて提示されていない")
        XCTAssertEqual(Set(box.positions.map { $0.seconds }).count, 120, "重複提示がある")

        // 破棄の計上: 復号の遅延保持ぶん（F13、≥1）は必ず捨てる。加えて reader が届けた
        // target 前 6 帧（frame 75, 78, 81, 84, 87, 89）が seekDiscarded に載る。
        // 着地直後の 9 帧（frame 76〜88）は reader 自体が届けないので計上されない。
        let seekDiscarded = outcome.stats.dropReasons[.seekDiscarded, default: 0]
        XCTAssertGreaterThanOrEqual(seekDiscarded, 1, "復号保持帧が seek で流し切られていない")
        print("04 §6 実測（決定的）: seekDiscarded=\(seekDiscarded)"
            + "（内訳: reader が届けた target 前 6 帧 + 復号の遅延保持ぶん）")

        // 提示間隔は seek 後も pts 間隔に追随（#11 と同じ ±2 ms 契約）。
        // seek 境界の 1 本はインデックスに現れない（初回提示は lastPresentHost を立てるだけで
        // 間隔を append しない。04 §9 と同じ理由で境界は検査しない）。
        XCTAssertEqual(outcome.presentIntervalMS.count, 29 + (120 - 31),
                       "seek 境界の間引き込み（間隔の append 構造）が壊れている")
        for j in 31..<box.positions.count {
            let expectedMS = (box.positions[j].seconds - box.positions[j - 1].seconds) * 1_000
            let interval = outcome.presentIntervalMS[j - 2]   // 境界ぶん -1 のインデックス
            XCTAssertGreaterThanOrEqual(interval, expectedMS - 2, "seek 後の提示が詰めすぎ")
            XCTAssertLessThanOrEqual(interval, expectedMS + 2, "seek 後の提示が遅れすぎ")
        }
    }

    /// seek の最中に close する競合（#2 で実測した reentrancy 不具合の回帰）。
    /// EngineCore は actor なので seek の await 中に close が割り込める。line generation が
    /// なければ、遅れて復帰した seek が phase を playing/ended に復活させて .empty に戻らない。
    func testCloseDuringInFlightSeekLeavesPhaseEmpty() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
        let engine = EngineCore()
        try await engine.load(FileMediaSource(url: url),
                              selection: PlaybackSelection(item: ItemID(1)))
        await engine.play()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let target = CMTime(seconds: 3.0, preferredTimescale: 1_000_000)
        let seekTask = Task { await engine.seek(to: target) }
        // seek（preroll 復号で数十 ms）が生きている窓で close をぶつける。
        try? await Task.sleep(nanoseconds: 10_000_000)
        await engine.close()
        await seekTask.value

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.phase, .empty,
                       "close 後の seek 復帰が phase を復活させた（line generation ガードの後退）")
        await engine.close()
    }
}
