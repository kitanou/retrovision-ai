import CoreMedia
import Foundation
import RVDecode
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore
import RVMediaSources
import RVVideoPipeline

// MARK: - 提示サーフェスへのハンドオフ（OQ-26 の暫定経路。#2 の映像表示への橋渡し）
//
// 検証する不変条件:
//   1. 保存則 — presented = サーフェスへ届いた帧 + displayMissed（取りこぼしは計数で追う）。
//   2. 速いサーフェスでは delivered = presented（欠落・重複なし、PTS 順）。lease は解ける。
//   3. 遅いサーフェス（in-flight 上限 3 で塞がる）でも**再生は止まらない**（INV-1）。
//      presented は全数、届くのは上限ぶんだけ。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-fixtures.sh で生成する）"
    }
}

private actor RecordingSink: VideoPresentSink {
    private var frames: [DecodedVideoFrame] = []
    private var ptsList: [MediaTime] = []

    func receive(_ frame: DecodedVideoFrame) async {
        frames.append(frame)
        ptsList.append(frame.pts)
    }
    var receivedCount: Int { frames.count }
    var receivedPTS: [MediaTime] { ptsList }
    var heldFrames: [DecodedVideoFrame] { frames }
}

/// 受領だけして戻らないサーフェス（装置が遅い状況の模型）。in-flight 上限を実験で固定する。
private actor BlockingSink: VideoPresentSink {
    private var receivedCount = 0
    func receive(_ frame: DecodedVideoFrame) async {
        receivedCount += 1
        await withUnsafeContinuation { (c: UnsafeContinuation<Never, Never>) in }
    }
    var arrived: Int { receivedCount }
}

/// 偶数番目の帧を捨てる presenter（Metal の drawable 喪失・in-flight 超過の模型）。
/// 渡された plan も記録する（engine が昇格済みの plan を presenter へ渡すことの検査）。
private actor DroppingPresenter: VideoFramePresenter {
    private var count = 0
    private var plans: [RenderPlan?] = []
    func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome {
        count += 1
        plans.append(plan)
        return count % 2 == 0 ? .dropped : .delivered
    }
    var seen: Int { count }
    var receivedPlanIDs: [PlanID?] { plans.map { $0?.id } }
}

final class PresentHandoffTests: XCTestCase {
    private var fixturesDir: URL {
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

    private func makeSession(demuxer: AVFoundationDemuxer, track: TrackInfo,
                             format: VideoFormatDescription,
                             time: DeterministicTimeSource,
                             sink: (any VideoPresentSink)?) async -> PlaybackSession {
        let session = PlaybackSession(
            demuxer: demuxer,
            decoder: VideoToolboxDecoder(),
            config: .init(videoTrack: track.id, videoFormat: format),
            time: time)
        if let sink { await session.setVideoSink(sink) }
        return session
    }

    private func driveToEnd(_ session: PlaybackSession, time: DeterministicTimeSource,
                            maxIterations: Int) async {
        var iterations = 0
        while !(await session.isFinished()) && iterations < maxIterations {
            await session.step()
            time.advance(ms: 1)
            iterations += 1
        }
    }

    /// 条件が成立するまで待つ（実時間。決定的時間源の駆動と違い、ハンドオフの Task は
    /// 実時間で回るため）。成立たなければ false（呼び出し側で保存則側の検査に倒す）。
    private func waitUntil(_ condition: @Sendable @escaping () async -> Bool,
                           maxPolls: Int = 1_500) async -> Bool {
        for _ in 0..<maxPolls {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    // MARK: - 1. 速いサーフェス: 提示された帧はすべて届く（保存則の delivered 側）

    func testFastSinkReceivesEveryPresentedFrameInOrder() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let sink = RecordingSink()
        let session = await makeSession(demuxer: demuxer, track: track, format: format,
                                       time: time, sink: sink)
        await driveToEnd(session, time: time, maxIterations: 15_000)

        let outcome = await session.outcomeSnapshot()
        let presented = outcome.stats.presented
        XCTAssertEqual(presented, 180, "fixture 全帧の提示（#11 の回帰）")

        // ハンドオフは Task 経由（実時間で回る）。届き切るまで待つ。
        let arrived = await waitUntil { await sink.receivedCount >= presented }
        let received = await sink.receivedCount
        print("OQ-26 実測: presented=\(presented) delivered=\(received) displayMissed=\(outcome.displayMissed)")

        // 保存則（常に）。
        XCTAssertEqual(received + outcome.displayMissed, presented,
                       "presented = delivered + displayMissed の保存則")
        guard arrived else {
            // 高負荷で取りこぼしが出た場合も、届いた分の順序と lease は検査する。
            XCTAssertGreaterThan(received, 0, "1 帧も届かない（ハンドオフ自体が動いていない）")
            return
        }
        XCTAssertEqual(outcome.displayMissed, 0, "速いサーフェスで取りこぼしは出ない")

        let receivedPTS = await sink.receivedPTS
        XCTAssertEqual(Set(receivedPTS.map { $0.seconds }).count, presented, "重複提示がある")
        for i in 1..<receivedPTS.count {
            XCTAssertEqual(receivedPTS[i - 1].compared(to: receivedPTS[i]), .orderedAscending,
                           "サーフェスへの配送が PTS 順でない")
        }

        // lease: サーフェスが描き終わったら解けていること（01 §4 の診断回路が生きている証明）。
        let released = await waitUntil {
            let frames = await sink.heldFrames
            return frames.allSatisfy { $0.activeLeaseCount == 0 }
        }
        XCTAssertTrue(released, "受領完了後に lease が解けない（display 用の lease 管理の欠陥）")
    }

    // MARK: - 2. 遅いサーフェス: 再生は止まらない（INV-1）。in-flight 上限で取りこぼす

    func testSlowSurfaceDoesNotStallPlaybackAndMissesAreCounted() async throws {
        let url = try fixtureURL("ntsc480i-22-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let sink = BlockingSink()
        let session = await makeSession(demuxer: demuxer, track: track, format: format,
                                       time: time, sink: sink)
        await driveToEnd(session, time: time, maxIterations: 15_000)

        let outcome = await session.outcomeSnapshot()
        let arrived = await sink.arrived
        print("OQ-26 実測（blocking sink）: presented=\(outcome.stats.presented) "
            + "delivered=\(arrived) displayMissed=\(outcome.displayMissed)")

        // 再生側は完全不破（#11 の回帰と同じ）。
        XCTAssertEqual(outcome.stats.presented, 180, "サーフェスが遅くても再生は止まらない（INV-1）")
        XCTAssertTrue(outcome.errors.isEmpty)
        // 上限ぶんだけ届き、残りは計数として取りこぼしに載る（保存則の決定的版）。
        XCTAssertEqual(arrived, 3, "in-flight 上限（00 §5 の 3）まで届く")
        XCTAssertEqual(outcome.displayMissed, 177, "上限超過は displayMissed に数える")
    }

    // MARK: - 3. sink を貼らないと計測のみ提示（#11 の動作の後退なし）

    func testWithoutSinkNothingIsDeliveredOrMissed() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let session = await makeSession(demuxer: demuxer, track: track, format: format,
                                       time: time, sink: nil)
        await driveToEnd(session, time: time, maxIterations: 5_000)
        let outcome = await session.outcomeSnapshot()
        let didFinish = await session.isFinished()
        XCTAssertTrue(didFinish)
        XCTAssertEqual(outcome.stats.presented, 12)
        XCTAssertEqual(outcome.displayMissed, 0, "sink なしでは displayMissed も動かない")
    }

    // MARK: - 4. presenter が捨てた帧も displayMissed に数える（Metal 提示の保存則）

    func testPresenterDropsAreCountedAsDisplayMissedAndPlanIsPassed() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let stream = try await demuxer.probe()
        let (track, format) = try videoTrack(of: stream)

        let time = DeterministicTimeSource(startMS: 10_000)
        let session = await makeSession(demuxer: demuxer, track: track, format: format,
                                       time: time, sink: nil)
        let presenter = DroppingPresenter()
        await session.setVideoPresenter(presenter)
        let aspect = AspectResolution(targetDAR: AspectRatio(w: 4, h: 3),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: 720, height: 480),
                                      source: .dvdAspectFlag)
        let output = OutputContract(displayPixels: PixelSize(width: 720, height: 480), aspect: aspect)
        await session.setRenderPlan(.metalBaseline(id: PlanID(7), output: output))
        await driveToEnd(session, time: time, maxIterations: 5_000)

        let delivered = await waitUntil({ await presenter.seen == 12 })
        XCTAssertTrue(delivered, "presenter に全フレームが届かない")
        let missedSettled = await waitUntil({ await session.outcomeSnapshot().displayMissed == 6 })
        let outcome = await session.outcomeSnapshot()
        XCTAssertEqual(outcome.stats.presented, 12)
        XCTAssertTrue(missedSettled, "presenter の drop が displayMissed に載らない: \(outcome.displayMissed)")
        let ids = await presenter.receivedPlanIDs
        XCTAssertTrue(ids.allSatisfy { $0 == PlanID(7) }, "昇格済みの plan が presenter に渡らない")
    }
}
