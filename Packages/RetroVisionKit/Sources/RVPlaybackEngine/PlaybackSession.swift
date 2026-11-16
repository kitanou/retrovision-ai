import Foundation
import RVMediaCore
import RVDecode

// MARK: - 再生セッション（02 §2 の実行系・#11 の映像-only 再生線）
//
// Phase 1 のスコープ: 映像のみ。クロックはメディア PTS の等倍進行（t0 + pts差分）で、
// 提示は「時刻になったフレームを消費する」形（Metal 提示は Phase 2/#5 で同じスロットに
// 差し替える。INV-2 の非 AI 経路はそのまま）。音声クロック（04 §5）は #10 の残り。
//
// 設計上の選択（実測契約に依存）:
// - decoder は提示順（PTS 順）のフレームだけを返す（EXP-001 F13）。セッションは
//   キュー先頭をそのまま出す。
// - 遅れて届いたフレームは**捨てるのではなく遅延提示する**（再生の連続性最優先、02 §1）。
//   late に数えるが presented も増やす。フレーム間隔の履歴は G1 の資料になる。
// - 時間源は注入する（TimeSource）。単体テストは DeterministicTimeSource で進める。

public struct PlaybackOutcome: Sendable {
    public var stats = FrameStats()
    /// 提示の成功間隔（ms）。G1 のフレーム間隔ヒストグラムの原料。
    public var presentIntervalMS: [Double] = []
    /// 復号段の wall time（sample ごと）。
    public var decodeStageMS: [Double] = []
    public var firstPresentDelayMS: Double = 0
    public var totalWallMS: Double = 0
    public var mediaDurationMS: Double = 0
    public var demuxedSampleCount: Int = 0
    public var errors: [String] = []

    public init() {}
}

public actor PlaybackSession {
    public struct Config: Sendable {
        public var videoTrack: TrackID
        public var videoFormat: VideoFormatDescription
        /// 遅延提示の閾値（ms）。これを超えて届いたら late に数える。
        public var lateThresholdMS: Double = 2.0
        /// 復号済みキューの上限。
        public var maxQueuedFrames: Int = 4
        public init(videoTrack: TrackID, videoFormat: VideoFormatDescription) {
            self.videoTrack = videoTrack
            self.videoFormat = videoFormat
        }
    }

    public enum Event: Sendable {
        case position(MediaTime)
        case finished(PlaybackOutcome)
    }

    private let demuxer: any Demuxer
    private let decoder: any VideoDecoder
    private let config: Config
    private let time: any TimeSource
    private let report: (@Sendable (Event) -> Void)?

    private var queue: [DecodedVideoFrame] = []
    /// iterator を進める呼び出しは mutating なので、actor のプロパティ直呼びができない
    /// （Swift 6 の規則）。参照ボックス経由で進める（actor 内だけで触る）。
    private final class SampleCursor: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<CompressedSample, any Error>.Iterator
        init(_ iterator: AsyncThrowingStream<CompressedSample, any Error>.Iterator) { self.iterator = iterator }
        func next() async throws -> CompressedSample? { try await iterator.next() }
    }
    private var cursor: SampleCursor?
    private var configured = false
    private var streamDone = false
    private var flushDone = false
    private var finished = false
    private var outcome = PlaybackOutcome()
    private var startHost: HostTime?
    private var firstPTS: MediaTime?
    private var lastPresentHost: HostTime?
    private var lastPresentedPTS: MediaTime?
    private var pauseHost: HostTime?

    public init(demuxer: any Demuxer, decoder: any VideoDecoder, config: Config,
                time: any TimeSource, report: (@Sendable (Event) -> Void)? = nil) {
        self.demuxer = demuxer
        self.decoder = decoder
        self.config = config
        self.time = time
        self.report = report
    }

    public func isFinished() -> Bool { finished }
    public func outcomeSnapshot() -> PlaybackOutcome { outcome }

    /// 1 呼吸: 復号を少し進め、時刻が来ていれば 1 帧消費する。
    /// 呼び手（driver）が時間を進めてから呼ぶ。テストはこれで決定的に進められる。
    /// 停止中は復号も消費も行わない（停止区間の先読みでメモリを増やさない）。
    public func step() async {
        guard !finished, pauseHost == nil else { return }
        await topUpDecode()
        presentDue()
        if streamDone && flushDone && queue.isEmpty {
            finish()
        }
    }

    /// 実時間駆動で完了まで走らせる（probe・実測用）。
    /// 待ちは次の帧の締切（キュー先頭の PTS）から逆算する。固定ポーリングと違い
    /// 時刻ぴったり（タイマの超過分だけ）に起きるため、late の計上が
    /// 「ポーリング量子の産物」にならない（#11 の実測で late=5 の主因だった）。
    public func run() async -> PlaybackOutcome {
        while !finished {
            if !isPaused() { await step() }
            if finished { break }
            try? await Task.sleep(nanoseconds: nextWakeNS())
        }
        return outcome
    }

    /// 次の step までの待ち時間（ns）。キューが空（枯渇）なら 1 ms の間隔で再試行。
    private func nextWakeNS() -> UInt64 {
        guard let start = startHost, let first = firstPTS, let head = queue.first else {
            return 1_000_000
        }
        let remainingMS = Self.mediaMS(first, head.pts) - time.now().ms(since: start)
        if remainingMS <= 0 { return 500_000 }              // 満了待ち（復号待ち）。短めに再試行
        let clampedMS = min(max(remainingMS, 0.5), 4.0)     // 応答性と起動の両立
        return UInt64(clampedMS * 1_000_000)
    }

    /// 一時停止: 消費を止める。再開時、クロックの基点を paused 区間だけ進める
    /// （停止中の wall time が後方遅延として積算されないようにする）。
    public func pause() {
        guard pauseHost == nil else { return }
        pauseHost = time.now()
    }

    public func resume() {
        guard let pausedAt = pauseHost else { return }
        pauseHost = nil
        if let start = startHost {
            startHost = HostTime(machTime: start.machTime + (time.now().machTime &- pausedAt.machTime))
        }
    }

    public func isPaused() -> Bool { pauseHost != nil }

    // MARK: 内部

    private func topUpDecode() async {
        if cursor == nil {
            if !configured {
                configured = true
                do {
                    try await decoder.configure(config.videoFormat, policy: DecodePolicy(),
                                               formatDescriptionHint: nil)
                } catch {
                    outcome.errors.append("configure: \(String(describing: error))")
                    streamDone = true
                    return
                }
            }
            cursor = SampleCursor((await demuxer.samples(for: config.videoTrack)).makeAsyncIterator())
        }
        guard !streamDone else { return }
        var decodedThisRound = 0
        while queue.count < config.maxQueuedFrames, decodedThisRound < config.maxQueuedFrames {
            do {
                guard let sample = try await cursor?.next() else {
                    streamDone = true
                    break
                }
                guard sample.hasSampleData else { continue }
                outcome.demuxedSampleCount += 1
                lastSamplePTS = sample.pts
                let began = time.now()
                do {
                    if let frame = try await decoder.decode(sample) {
                        queue.append(frame)
                    }
                } catch {
                    outcome.errors.append("decode: \(String(describing: error))")
                }
                outcome.decodeStageMS.append(time.now().ms(since: began))
                decodedThisRound += 1
            } catch {
                streamDone = true
                outcome.errors.append("demux: \(String(describing: error))")
                break
            }
        }
        if streamDone && !flushDone {
            queue.append(contentsOf: await decoder.flush())
            flushDone = true
        }
    }
    private var lastSamplePTS: MediaTime?

    private func presentDue() {
        guard let head = queue.first else { return }
        let now = time.now()
        if startHost == nil { startHost = now }
        guard let start = startHost else { return }
        if firstPTS == nil { firstPTS = head.pts }
        guard let first = firstPTS else { return }
        let targetMS = Self.mediaMS(first, head.pts)
        let elapsedMS = now.ms(since: start)
        guard elapsedMS >= targetMS else { return }

        let frame = queue.removeFirst()
        if elapsedMS > targetMS + config.lateThresholdMS {
            outcome.stats.late += 1
            outcome.stats.dropReasons[.late, default: 0] += 1
        }
        outcome.stats.presented += 1
        if lastPresentHost == nil {
            outcome.firstPresentDelayMS = elapsedMS
        } else if let previous = lastPresentHost {
            outcome.presentIntervalMS.append(now.ms(since: previous))
        }
        lastPresentHost = now
        lastPresentedPTS = frame.pts
        outcome.stats.total = max(outcome.stats.total, outcome.demuxedSampleCount)
        report?(.position(frame.pts))
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let start = startHost {
            outcome.totalWallMS = time.now().ms(since: start)
        }
        if let first = firstPTS, let last = lastPresentedPTS ?? lastSamplePTS {
            outcome.mediaDurationMS = Self.mediaMS(first, last)
        }
        report?(.finished(outcome))
    }

    /// メディア時間の経過（ms）。PTS は timescale 違いを気にせず seconds 経由で十分正確（記録用途）。
    private static func mediaMS(_ from: MediaTime, _ to: MediaTime) -> Double {
        (to.seconds - from.seconds) * 1_000
    }
}
