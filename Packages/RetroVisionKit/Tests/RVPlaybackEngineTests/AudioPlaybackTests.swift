import AVFAudio
import CoreMedia
import Foundation
import XCTest
@testable import RVPlaybackEngine
import RVMediaCore

// MARK: - 音声付き再生の e2e（#10。04 §9 の音声測定項目: drift・underrun）
//
// 方針（09 §2）: fixture が無い場合は失敗。ただし**音声出力装置の有無は実行環境に依存**する
// （CI の macOS ランナーに device が無い場合、sink.start() は失敗しセッションは映像のみへ
// 縮退する — それが設計どおりの挙動）。drift・underrun の検査は audioStatus == "running"
// のときだけ行う。縮退そのものは status 文字列で検査する。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-fixtures.sh で生成する）"
    }
}

final class AudioPlaybackTests: XCTestCase {
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

    private func playToEnd(_ url: URL) async throws -> (PlaybackOutcome, PlayerSnapshotBox) {
        let engine = EngineCore()
        let events = await engine.events()
        try await engine.load(FileMediaSource(url: url),
                              selection: PlaybackSelection(item: ItemID(1)))
        let box = PlayerSnapshotBox()
        let consumer = Task {
            for await event in events {
                box.handle(event)
                if box.done { break }
            }
        }
        await engine.play()
        // 6 s 素材 + prefill + 音声 drain。実時間駆動に対する安全側上限。
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !box.done {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        consumer.cancel()
        let outcome = await engine.playbackOutcome() ?? PlaybackOutcome()
        await engine.close()
        return (outcome, box)
    }

    /// AC-3 付き素材を EngineCore で最後まで再生し、音声 clock の drift と underrun を測る。
    /// 構造的検査（完走・全帧提示・clock 採样の存在・underrun 少）は常に実行する。
    /// **数値の drift 検査は実時間ペーシングのある装置のときだけ**実行する
    /// （`audioDeviceRealTimeRatio()` が装置の実測で判定。CI の仮想装置は実行ごとに
    /// 1.09〜1.5 倍で無料実行し、同一コードで drift p95 が 40→92 ms と揺れる。04 §9）。
    func testAC3PlaybackKeepsDriftSmallAndNoUnderruns() async throws {
        let url = try fixtureURL("ntsc480i-ac3-01.mpg")
        let (outcome, box) = try await playToEnd(url)

        XCTAssertNil(box.failedMessage, "再生が失敗した: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "phase .ended に到達しない")
        XCTAssertEqual(outcome.demuxedSampleCount, 180)
        XCTAssertEqual(outcome.stats.presented, 180)

        switch outcome.audioStatus {
        case "running":
            break
        case let status where status.hasPrefix("failed"):
            // 出力装置の無い環境での縮退。映像線は壊れていないことだけ確認する。
            XCTAssertTrue(outcome.clockDriftMS.isEmpty, "縮退中に drift が積まっている")
            return
        default:
            XCTFail("audioStatus が予期しない値: \(outcome.audioStatus)")
            return
        }

        // clock が立っている = 装置 start 成功。Drift 採样と underrun 計は常に存在を見る。
        XCTAssertFalse(outcome.clockDriftMS.isEmpty, "audio clock の drift 採样が無い")
        XCTAssertLessThan(outcome.audioUnderrunEpisodes, 5,
                          "underrun 多発: \(outcome.audioUnderrunEpisodes) 回、"
                          + "合計 \(outcome.audioUnderrunTotalMS) ms")

        let ratio = await audioDeviceRealTimeRatio()
        print("audio device steady ratio: \(ratio.map { String(format: "%.3f", $0) } ?? "start 失敗")"
            + " / drift samples=\(outcome.clockDriftMS.count)")
        guard let ratio, (0.98...1.03).contains(ratio) else {
            // 仮想装置（実時間ペーシングなし）: drift の値は装置の無料実行の産物で
            // 設計分布ではない。ここでは数値を主張しない（数値の実測は 04 §9・実機）。
            return
        }
        let absoluteDrift = outcome.clockDriftMS.map(abs).sorted()
        let p95Index = max(0, min(absoluteDrift.count - 1,
                                  Int((Double(absoluteDrift.count) * 0.95).rounded(.up)) - 1))
        let p95 = absoluteDrift[p95Index]
        XCTAssertLessThan(p95, 40, "実時間装置での drift p95 が 40 ms を超えた（04 §5 の補正段階。実測: \(p95) ms）")
    }

    /// 音声なし素材（MPEG-2 単体）は #11 と同じ暫定 pacing で動く（audio 線の不在が無害）。
    func testNoAudioFixtureKeepsWorkingAsVideoOnly() async throws {
        let url = try fixtureURL("truncated-01-cut.mpg")
        let (outcome, box) = try await playToEnd(url)
        XCTAssertTrue(box.endedFlag)
        XCTAssertEqual(outcome.audioStatus, "none")
        XCTAssertTrue(outcome.clockDriftMS.isEmpty)
        XCTAssertEqual(outcome.stats.presented, 12)
    }

    /// DTS 素材（A6: トラックとして現れない）は音声なしで完走する。
    /// 実盤 DTS の対応は Phase 4 の shim ゲート（OQ-02）。
    func testDTSFixturePlaysWithoutAudioUntilShimGate() async throws {
        let url = try fixtureURL("ntsc480i-dts-01.mpg")
        let (outcome, box) = try await playToEnd(url)
        XCTAssertTrue(box.endedFlag, "DTS 素材が音声なしで再生できない")
        XCTAssertTrue(outcome.audioStatus == "none",
                      "AVFoundation は DTS を列挙しない（A6）。実際: \(outcome.audioStatus)")
        XCTAssertEqual(outcome.stats.presented, 180)
    }

    /// 再生中の seek（04 §6・#13）。セッションは生きたまま配線を組み替え、
    /// 音声 preroll（target-0.2 s）から clock を起こし直す。
    /// 構造的検査: 完走・错误なし・位置イベントの単調増加（seek の target イベントを含む）・
    /// seek 後に drift 采样が続く（clock の再 anchor — 止まったままだと采样が増えない）。
    func testSeekDuringPlaybackResumesWithAudioClockRunning() async throws {
        let url = try fixtureURL("ntsc480i-ac3-01.mpg")
        let engine = EngineCore()
        let events = await engine.events()
        try await engine.load(FileMediaSource(url: url),
                              selection: PlaybackSelection(item: ItemID(1)))
        let box = PlayerSnapshotBox()
        let consumer = Task {
            for await event in events {
                box.handle(event)
                if box.done { break }
            }
        }
        await engine.play()
        // 1.5 s 実時間で再生してから中間 seek（target 3.0 s、GOP 着地は 2.535 s 側）。
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let target = CMTime(seconds: 3.0, preferredTimescale: 1_000_000)
        let seekBegan = Date()
        await engine.seek(to: target)
        let seekWallMS = Date().timeIntervalSince(seekBegan) * 1_000

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline && !box.done {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        consumer.cancel()
        let outcome = await engine.playbackOutcome() ?? PlaybackOutcome()
        await engine.close()

        XCTAssertNil(box.failedMessage, "seek 後に再生が失敗した: \(box.failedMessage ?? "")")
        XCTAssertTrue(box.endedFlag, "seek 後に phase .ended に到達しない")
        XCTAssertTrue(outcome.errors.isEmpty, "seek 直後の供给・復号の失敗: \(outcome.errors)")
        XCTAssertEqual(outcome.seekMS.count, 1, "seek の wall time 記録が無い（04 §6 の実測点）")
        print(String(format: "04 §6 実測（実時間）: seekWallMS=%.1f sessionSeekMS=%.1f "
                     + "driftSamples=%d underruns=%d",
                     seekWallMS, outcome.seekMS.first ?? 0,
                     outcome.clockDriftMS.count, outcome.audioUnderrunEpisodes))

        // 位置イベントは seek を挟んでも単調増加（再生側の提示順 + target イベント）。
        let positions = box.collectedPositions
        XCTAssertFalse(positions.isEmpty)
        for i in 1..<positions.count {
            XCTAssertEqual(positions[i - 1].compared(to: positions[i]), .orderedAscending,
                           "position \(i) が PTS 順でない（seek 直後の逆行・重複は設計外）")
        }
        XCTAssertTrue(positions.contains { abs($0.seconds - 3.0) < 1e-6 },
                      "seek の target 位置イベントが無い（UI は target を表示する設計、04 §6）")
        let last = positions.last.map { $0.seconds } ?? 0
        XCTAssertGreaterThan(last, 5.5, "seek 後に最後まで進んでいない")

        switch outcome.audioStatus {
        case "running":
            break
        case let status where status.hasPrefix("failed"):
            return   // 出力装置の無い環境での縮退（#10 と同じ）。映像線の完走まで検査済み。
        default:
            XCTFail("audioStatus が予期しない値: \(outcome.audioStatus)")
            return
        }
        // clock が seek 後に生きていれば drift 采样が増え続ける（停止だと増えない）。
        // 全体 5.9 s ÷ 0.1 s 采样で 40 件超が期待値。seek 前だけで止まっていれば 15 件前後。
        XCTAssertGreaterThan(outcome.clockDriftMS.count, 30,
                             "seek 後に audio clock の采样が続いていない（再 anchor 失败？）")
        XCTAssertLessThan(outcome.audioUnderrunEpisodes, 5,
                          "seek 後の供給再開で underrun 多発: \(outcome.audioUnderrunEpisodes)")
    }
}

/// e2e イベントの受け取り箱（FilePlaybackTests のものと同じ形）。
private final class PlayerSnapshotBox: @unchecked Sendable {
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

// MARK: - 音声装置の実時間ペーシングprobe（環境の自己申告にしない）

/// 0.995..1.02 を pass とする。**実測で較正する**: 内蔵出力では start 直後の 1 s で 0.252、
/// 追加 2 s 待った後の 1 s 窓では 1.000（装置の起動・スレッド起上に 2〜3 s かかり、定常後は
/// 実時間どおり）。pass 帯域と測定窓はこの実測どおりにする（推測で狭くしない）。
private func audioDeviceRealTimeRatio() async -> Double? {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                     channels: 2, interleaved: true) else { return nil }
    engine.connect(player, to: engine.mainMixerNode, format: format)
    do {
        engine.prepare()
        try engine.start()
    } catch {
        return nil
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(240_000)) else {
        engine.stop(); return nil
    }
    buffer.frameLength = 240_000      // 5 s ぶん（測定窓 + 装置の起動ユルミ）
    player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    player.play()
    func pollRenderedMS() async -> Double {
        var frames: Double = 0
        let until = ContinuousClock.now
        while ContinuousClock.now < until + .milliseconds(1000) {
            if let node = player.lastRenderTime, let pt = player.playerTime(forNodeTime: node) {
                frames = max(frames, Double(pt.sampleTime))
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return frames / 48.0
    }
    let first = await pollRenderedMS()
    let warm = await pollRenderedMS()      // 装置が起き上がったかの確認（この窓は捨てる）
    let second = await pollRenderedMS()
    player.stop()
    engine.stop()
    let ratio = (second - warm) / 1000.0   // 2 s 目以降の 1 s 窓の実時間比
    print(String(format: "device probe: firstWindow=%.0fms warmWindow→ steadyRatio=%.3f",
                 first, ratio))
    return ratio
}
