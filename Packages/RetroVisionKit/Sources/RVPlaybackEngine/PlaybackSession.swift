import CoreMedia
import Foundation
import RVMediaCore
import RVDecode

// MARK: - 再生セッション（02 §2 の実行系・#11/#10 の再生線）
//
// 映像＋音声。音声があるときは audio master clock（04 §5）が提示時刻の権威になる:
//   sink の rendered PTS を AudioClock が採样し、frame→host の対応でフレームの締切を決める。
//   音声が無い・失敗した場合は #11 の暫定クロック（壁時計基点 + PTS 差分）で動く（INV-2 と同じ
//   「縮退経路は常に存在する」の系譜。device の無い CI でも映像再生は破綻しない）。
//
// 設計上の選択（実測契約に依存）:
// - decoder は提示順（PTS 順）のフレームだけを返す（EXP-001 F13）。セッションは
//   キュー先頭をそのまま出す。
// - 遅れて届いたフレームは**捨てるのではなく遅延提示する**（再生の連続性最優先、02 §1）。
//   late に数えるが presented も増やす。フレーム間隔の履歴は G1 の資料になる。
// - 時間源は注入する（TimeSource）。単体テストは DeterministicTimeSource で進める。
// - 音声の prefill は既定 120 ms（04 §9 の underrun 測定開始前に十分）。sink.start() は
//   prefill 完了後に行う（AVAudioPlayerNode は schedule 済 buffer を順次再生する）。

public struct PlaybackOutcome: Sendable {
    public var stats = FrameStats()
    /// 提示の成功間隔（ms）。G1 のフレーム間隔ヒストグラムの原料。
    public var presentIntervalMS: [Double] = []
    /// 復号段の wall time（sample ごと）。
    public var decodeStageMS: [Double] = []
    /// audio clock が有効なあいだ、提示時に採った映像遅延（ms。+ = 映像が遅れている、04 §5）。
    public var clockDriftMS: [Double] = []
    public var firstPresentDelayMS: Double = 0
    public var totalWallMS: Double = 0
    public var mediaDurationMS: Double = 0
    public var demuxedSampleCount: Int = 0
    /// 音声線の状態（"none" = 音声なし/未接続、"running"、"failed:<理由>"）。
    public var audioStatus: String = "none"
    /// 音声出力の実仕様（"48000Hz/2ch/lpcm16" 形式。未 start なら nil）。
    public var audioOutputFormat: String?
    /// 音声 underrun の発生回数と合計長さ（04 §9 の音声測定項目）。
    public var audioUnderrunEpisodes: Int = 0
    public var audioUnderrunTotalMS: Double = 0
    /// 起動準備（prepare）にかけた wall time。0 = 未実行（#12・OQ-18 の測定項目）。
    public var warmupMS: Double = 0
    /// warmup で復号した sample の wall time（decodeStageMS を warmup で汚さないための分離箱）。
    public var warmupStageMS: [Double] = []
    /// seek 1 回の wall time（preroll 込み。04 §6 の 0.2〜1.5 s 設計に対する実測点、#13）。
    public var seekMS: [Double] = []
    public var errors: [String] = []

    public init() {}
}

/// 音声線の配線（セッションが持つ clock/sink/decoder の束）。
/// EngineCore の composition 層で組み立てる（02 §4 の依存方向）。
public struct AudioLine: Sendable {
    public var decoder: any AudioDecoderProtocol
    public var sink: any AudioSink

    public init(decoder: any AudioDecoderProtocol, sink: any AudioSink) {
        self.decoder = decoder
        self.sink = sink
    }
}

public actor PlaybackSession {
    public struct Config: Sendable {
        public var videoTrack: TrackID
        public var videoFormat: VideoFormatDescription
        /// 音声トラック（nil = 映像のみ = #11 の動作をそのまま保つ）。
        public var audioTrack: TrackID?
        public var audioFormat: AudioFormatDescription?
        /// 遅延提示の閾値（ms）。これを超えて届いたら late に数える。
        public var lateThresholdMS: Double = 2.0
        /// 復号済みキューの上限。
        public var maxQueuedFrames: Int = 4
        /// 起動準備（prepare）で先に復号する帧数（#12・OQ-18。0 にすると warmup なし＝
        /// #11 の動作。初回復号スパイク 44〜70 ms を .ready 側に移す目的）。
        public var warmupFrames: Int = 3
        /// 再生開始前に sink へ積む量（ms）。04 §9 の underrun -free 開始のための値。
        public var audioPrefillMS: Double = 120
        /// 稼働中に維持する積量（ms）。供給はこの下限割れで追う。
        public var audioRefillMS: Double = 150
        /// 映像が尽きた後に音声 drain を待つ上限（ms）。進行停止の環境での打ち切り。
        public var audioDrainTimeoutMS: Double = 2_000
        public init(videoTrack: TrackID, videoFormat: VideoFormatDescription,
                    audioTrack: TrackID? = nil, audioFormat: AudioFormatDescription? = nil) {
            self.videoTrack = videoTrack
            self.videoFormat = videoFormat
            self.audioTrack = audioTrack
            self.audioFormat = audioFormat
        }
    }

    public enum Event: Sendable {
        case position(MediaTime)
        case finished(PlaybackOutcome)
    }

    private let demuxer: any Demuxer
    private let decoder: any VideoDecoder
    private let audio: AudioLine?
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
    private final class AudioCursor: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<AudioPCM, any Error>.Iterator
        init(_ iterator: AsyncThrowingStream<AudioPCM, any Error>.Iterator) { self.iterator = iterator }
        func next() async throws -> AudioPCM? { try await iterator.next() }
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

    // 音声線
    private var audioClock: AudioClock?
    private var audioCursor: AudioCursor?
    private var audioConfigured = false
    private var audioStreamDone = false
    private var audioRunning = false
    private var audioFailed = false
    private var underrunSince: HostTime?
    private var lastDriftSampleHost: HostTime?

    public init(demuxer: any Demuxer, decoder: any VideoDecoder, config: Config,
                time: any TimeSource, audio: AudioLine? = nil,
                report: (@Sendable (Event) -> Void)? = nil) {
        self.demuxer = demuxer
        self.decoder = decoder
        self.config = config
        self.time = time
        self.audio = audio
        self.report = report
        if audio != nil, let format = config.audioFormat {
            outcome.audioStatus = "prefilling"
            outcome.audioOutputFormat = "\(format.sampleRate)Hz/\(format.channelCount)ch/\(format.codec.rawValue)"
        }
    }

    public func isFinished() -> Bool { finished }
    public func outcomeSnapshot() -> PlaybackOutcome { outcome }

    /// 起動準備（#12・OQ-18）。load 完了後に呼ぶ: 復号器を configure し、先頭ぶん（既定 3 帧）を
    /// 復号してキューに置く — **捨てない**（初帧提示にそのまま使う。VT の初回スパイク 44〜70 ms を
    /// .ready の待ち時間に吸収するのが目的で、reset は呼ばない = VT session を壊さない）。
    /// 音声は prefill まで積んで start しない（再生開始の瞬間にずらし、initial の無音すき間を
    /// 作らない）。run()/step() と並行に呼んでよい（`producing` で復号供給の重複を防ぐ）。
    public func prepare() async {
        guard !finished, !prepared else { return }
        prepared = true
        let began = time.now()
        await topUpDecode(kind: .warmup)
        await prefillAudio()
        outcome.warmupMS = time.now().ms(since: began)
    }
    private var prepared = false
    /// 復号・音声供給が進行中か（prepare と run の並行で iterator を二重に進めないための闸门）。
    private var producing = false
    /// 供給世代のカウント。seek は配線を組み替える際これを増やし、進行中の供給ループを
    /// ガードで自分終りにする（古い reader のキャンセル・错误を縮退として扱わないため）。
    private var generation = 0

    /// 1 呼吸: 音声供給と復号を少し進め、時刻が来ていれば 1 帧消費する。
    /// 呼び手（driver）が時間を進めてから呼ぶ。テストはこれで決定的に進められる。
    /// 停止中は復も消費も行わない（停止区間の先読みでメモリを増やさない）。
    public func step() async {
        guard !finished, !seeking, pauseHost == nil else { return }
        await topUpAudio()
        audioTick()
        await topUpDecode()
        presentDue()
        if streamDone && flushDone && queue.isEmpty {
            if !audioPending() {
                finish()
            } else {
                // 音声の drain を待つ。ただし進行が見えなくなった環境（エンジンが
                // 動かない・rendered が進まない）で止まらないよう、上限で打ち切る。
                if videoDrainedHost == nil { videoDrainedHost = time.now() }
                if let drained = videoDrainedHost,
                   time.now().ms(since: drained) > config.audioDrainTimeoutMS {
                    outcome.errors.append("audio-drain-timeout: 映像終了後 \(config.audioDrainTimeoutMS) ms 待っても音声が終わらない")
                    finish()
                }
            }
        }
    }
    private var videoDrainedHost: HostTime?

    /// 実時間駆動で完了まで走らせる（probe・実測用）。
    /// 待ちは次の帧の締切（audio clock が権威。無いときはキュー先頭 PTS の暫定基点）から
    /// 逆算する。固定ポーリングと違い時刻ぴったり（タイマの超過分だけ）に起きるため、
    /// late の計上が「ポーリング量子の産物」にならない（#11 の実測で late=5 の主因だった）。
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
        guard let head = queue.first else { return 1_000_000 }
        let due: HostTime
        if let clock = audioClock, clock.isRunning {
            due = clock.hostTime(for: head.pts)
        } else if let start = startHost, let first = firstPTS {
            due = start.advancing(ms: Self.mediaMS(first, head.pts))
        } else {
            return 1_000_000
        }
        let remainingMS = due.ms(since: time.now())
        if remainingMS <= 0 { return 500_000 }              // 満了待ち（復号待ち）。短めに再試行
        let clampedMS = min(max(remainingMS, 0.5), 4.0)     // 応答性と起動の両立
        return UInt64(clampedMS * 1_000_000)
    }

    /// 一時停止: 消費を止める（音声も凍結）。再開時、映像クロックの基点を paused 区間だけ
    /// 進める（停止中の wall time が後方遅延に積算されない）。audio clock は sink の再生位置が
    /// 凍るため、再開後の最初の sample() で自然に再アンカーされる（04 §5）。
    public func pause() {
        guard pauseHost == nil else { return }
        pauseHost = time.now()
        audio?.sink.pause()
    }

    public func resume() {
        guard let pausedAt = pauseHost else { return }
        pauseHost = nil
        if let start = startHost {
            startHost = HostTime(machTime: start.machTime + (time.now().machTime &- pausedAt.machTime))
        }
        audio?.sink.resume()
    }

    public func isPaused() -> Bool { pauseHost != nil }

    /// seek（04 §6、#13）。セッションが生きたまま復号配線を組み替える —
    /// VT session は生かす（初回复号スパイクを再払しない。#12 と同じ設計思想）。
    /// 手順: ① clock を止め sink を flush → ② 音声を target-0.2 s 前に寄せて prefill
    /// （実音 preroll。対応表で PTS が解決されるので clock はそこから再アンカーされる）→
    /// ③ 映像を target に寄せる（実際の着地は直前 keyframe。AVFoundation が編集表で寄せる）→
    /// ④ target までの帧は復号して捨てる（acceptFrame の闸门。復号負荷は計上）→
    /// ⑤ clock の再開は最初の提示完了ではなく最初の採样（rendered PTS が取れた時点。
    /// AudioClock の初回 sample が anchor になる — #10 と同じ機構）。
    /// seek 中（`seeking`）は step() が何もしない（run() ループの途中差し込みで二重進行しない）。
    public func seek(to target: MediaTime, tolerance: SeekTolerance) async {
        guard !finished, !seeking else { return }
        seeking = true
        let began = time.now()
        defer {
            outcome.seekMS.append(time.now().ms(since: began))
            seeking = false
        }
        // 進行中の供給（step 経由の topUp*）があれば、その回合を終えさせてから組み替える
        // （generation ガードで古い reader は自分から終る。待ちすぎても壊れないが、
        // 組み替え後の topUpDecode が producing で空振りしない利点だけ待つ）。
        generation &+= 1
        for _ in 0..<200 where producing { try? await Task.sleep(nanoseconds: 1_000_000) }
        // ① 音声クロックと出力を止める（rendered の追補をやめる — 04 §6 手順 1）。
        audioClock?.stop()
        audio?.sink.flush()
        audioRunning = false
        audioPrefilled = false
        audioStreamDone = false
        underrunSince = nil
        videoDrainedHost = nil
        // 復号の遅延保持（F13 の組み替えが保持する直前帧）を流し切って捨てる。
        // flush は保持分の消化で、VT session は壊さない（reset と違い再 warmup が起きない）。
        for frame in await decoder.flush() {
            outcome.stats.dropped += 1
            outcome.stats.dropReasons[.seekDiscarded, default: 0] += 1
        }
        // ② 音声: target より 0.2 s 前から（04 §6 手順 2・3。PREROLL_MS 相当）。
        //    iterator は生成時に reader 位置を capture するので、音声の prefill を先に作る。
        let audioAnchor = CMTimeCompare(target, CMTime(seconds: 0.2, preferredTimescale: 1_000_000)) > 0
            ? CMTimeSubtract(target, CMTime(seconds: 0.2, preferredTimescale: 1_000_000))
            : .zero
        if config.audioTrack != nil {
            do { _ = try await demuxer.seek(to: audioAnchor, tolerance: .previousKeyframe) }
            catch { outcome.errors.append("seek-audio: \(String(describing: error))") }
            await prefillAudio()
        }
        // ③ 映像: target そのものへ（着地は keyframe 側）。再生アンカーとキューを初期化し、
        //    target までの帧は捨てて進む（④ は topUpDecode の seekPreroll 内）。
        do { _ = try await demuxer.seek(to: target, tolerance: tolerance) }
        catch { outcome.errors.append("seek: \(String(describing: error))") }
        queue.removeAll()
        cursor = nil
        streamDone = false
        flushDone = false
        discardBefore = target
        startHost = nil; firstPTS = nil; lastPresentHost = nil; lastPresentedPTS = nil
        lastDriftSampleHost = nil
        // ⑤ 音声開始（実音 preroll を鳴らしながら映像は target まで進む）。停止中は prefill のみ
        // （再開時の topUpAudio が start する。停止中に preroll を鳴らさない）。
        if pauseHost == nil {
            startAudioSink()
        } else if !audioFailed, config.audioTrack != nil {
            outcome.audioStatus = "prefilling"
        }
        await topUpDecode(kind: .seekPreroll)
    }
    private var seeking = false

    /// セッションを閉じるときの後始末（音声装置を解放し、クロックを止める）。
    public func shutdown() {
        audio?.sink.stop()
        audioClock?.stop()
        audioRunning = false
    }

    // MARK: 音声供給とクロック（04 §4・§5）

    /// prefill のみ（start しない）。prepare() が .ready のあいだに、topUpAudio は play 後の
    /// 初回 tick で呼ぶ（どちらも冪等）。
    private func prefillAudio() async {
        guard let audio, !audioFailed, !audioPrefilled, let audioTrack = config.audioTrack else { return }
        audioPrefilled = true   // 失敗しても再実行しない（縮退が正）
        if !audioConfigured {
            audioConfigured = true
            do {
                try await audio.decoder.configure(config.audioFormat ?? AudioFormatDescription(
                    codec: .unknown, sampleRate: 48_000, channelCount: 2), policy: DecodePolicy())
            } catch {
                failAudio("configure", error)
                return
            }
        }
        audioClock = AudioClock(sink: audio.sink, time: time)
        audioCursor = AudioCursor((await audio.decoder.pcm(for: audioTrack)).makeAsyncIterator())
        // prefill: start 前に audioPrefillMS 分積む。素材が短い場合は最後まで読む。
        // generation ガード: 待ち中に別の seek が入ったら、この古い reader は静かに終る
        // （次の prefill が新しい位置で作られた iterator を使う）。
        let myGen = generation
        var safety = 0
        while audio.sink.scheduledAheadMS() < config.audioPrefillMS, safety < 2_000 {
            guard generation == myGen else { return }
            do {
                let next = try await audioCursor?.next()
                guard generation == myGen else { return }
                guard let quantum = next else {
                    audioStreamDone = true
                    break
                }
                try audio.sink.schedule(quantum)
            } catch {
                if generation != myGen { return }
                failAudio("prefill", error)
                return
            }
            safety += 1
        }
    }
    private var audioPrefilled = false

    /// 稼働中の補給（play 後の初回 tick で start も行う）。供給は 480 帧 quantum（10 ms）単位。
    /// AVFoundation の PCM 変換は realtimeFactor ≈1100（EXP-002）なので、ここで同期に
    /// 引く時間は再生時間に対して無視できる。
    private func topUpAudio() async {
        guard let audio, !audioFailed, config.audioTrack != nil else { return }
        if !audioRunning {
            await prefillAudio()
            if audioFailed { return }
            startAudioSink()
            return
        }
        guard !audioStreamDone else { return }
        let myGen = generation
        var safety = 0
        while audio.sink.scheduledAheadMS() < config.audioRefillMS, safety < 60 {
            guard generation == myGen else { return }
            do {
                let next = try await audioCursor?.next()
                guard generation == myGen else { return }
                guard let quantum = next else {
                    audioStreamDone = true
                    break
                }
                try audio.sink.schedule(quantum)
            } catch {
                if generation != myGen { return }   // seek 中の reader キャンセルは想定どおり
                failAudio("refill", error)
                return
            }
            safety += 1
        }
    }

    /// 出力装置を start する（play 初回 tick と、seek の preroll から呼ぶ。どちらも冪等）。
    /// 失敗は「音声なしの暫定 pacing へ縮退」（#10。出力装置の無い環境では throw）。
    private func startAudioSink() {
        guard let audio, !audioFailed, !audioRunning, config.audioTrack != nil else { return }
        do {
            try audio.sink.start()      // 出力装置の無い環境（CI 等）では throw → 映像のみへ縮退
        } catch {
            failAudio("start(\(String(describing: error)))", nil)
            return
        }
        if let format = audio.sink.outputFormat {
            outcome.audioOutputFormat =
                "\(format.sampleRate)Hz/\(format.channelCount)ch/\(format.codec.rawValue)"
        }
        audioRunning = true
        outcome.audioStatus = "running"
    }

    private func failAudio(_ stage: String, _ error: (any Error)?) {
        audioFailed = true
        audioRunning = false
        audioClock?.stop()
        audio?.sink.stop()
        outcome.audioStatus = "failed:\(stage)"
        if let error {
            outcome.errors.append("audio-\(stage): \(String(describing: error))")
        }
    }

    /// 毎呼吸の clock 採样と underrun 監視（再生駆動と同じ間隔 = 数 ms）。
    private func audioTick() {
        guard let audio, audioRunning, !audioFailed else { return }
        _ = audioClock?.sample()
        let ahead = audio.sink.scheduledAheadMS()
        if ahead <= 0 {
            if underrunSince == nil, !audioStreamDone {
                underrunSince = time.now()
            }
        } else if let began = underrunSince, ahead > 20 {
            outcome.audioUnderrunTotalMS += time.now().ms(since: began)
            outcome.audioUnderrunEpisodes += 1
            underrunSince = nil
        }
    }

    private func audioPending() -> Bool {
        guard let audio, audioRunning, !audioFailed else { return false }
        if !audioStreamDone { return true }
        return audio.sink.scheduledAheadMS() > 0    //  drain（最後まで積んだ分の再生残り）を待つ
    }

    // MARK: 映像供給

    /// 供給の目的。warmup は #12 の統計分離（warmupStageMS）、seekPreroll は 04 §6 の
    /// 捨てながら進む（復号負荷は常時統計に計上する）。
    private enum SupplyKind { case steady, warmup, seekPreroll }

    /// 映像の復号供給。`producing` 闸门で prepare と run の並行実行でも iterator を
    /// 二重に進めない（actor の一時停止中に別の呼が入るため、flag で守る）。
    private func topUpDecode(kind: SupplyKind = .steady) async {
        guard !producing else { return }
        producing = true
        defer { producing = false }
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
        let myGen = generation
        // warmup は既定帧数ぶんだけ復号する（prepare）。seekPreroll は目標位置まで
        // 捨てながら進む（04 §6 手順 4。長い GOP のための上限で打ち切り、次 tick で続く）。
        let roundLimit: Int
        switch kind {
        case .steady: roundLimit = config.maxQueuedFrames
        case .warmup: roundLimit = config.warmupFrames
        case .seekPreroll: roundLimit = 600
        }
        var decodedThisRound = 0
        while queue.count < config.maxQueuedFrames, decodedThisRound < roundLimit {
            guard generation == myGen else { return }   // seek が配線を引き継いだ（この世代は終り）
            do {
                let next = try await cursor?.next()
                guard generation == myGen else { return }  // 待ち中に seek: この sample は捨て、新しい位置から続く
                guard let sample = next else {
                    streamDone = true
                    break
                }
                guard sample.hasSampleData else { continue }
                outcome.demuxedSampleCount += 1
                lastSamplePTS = sample.pts
                let began = time.now()
                do {
                    if let frame = try await decoder.decode(sample) {
                        acceptFrame(frame)
                    }
                } catch {
                    outcome.errors.append("decode: \(String(describing: error))")
                }
                let tookMS = time.now().ms(since: began)
                if kind == .warmup {
                    outcome.warmupStageMS.append(tookMS)
                } else {
                    outcome.decodeStageMS.append(tookMS)   // seekPreroll も復号負荷として計上（04 §6）
                }
                decodedThisRound += 1
            } catch {
                if generation != myGen { return }   // seek 中の reader キャンセルは想定どおり（错误にしない）
                streamDone = true
                outcome.errors.append("demux: \(String(describing: error))")
                break
            }
        }
        if streamDone && !flushDone {
            for frame in await decoder.flush() { acceptFrame(frame) }
            flushDone = true
        }
    }

    /// 復号帧の受け口。seek の preroll 中（`discardBefore` が生きている間）は目標位置前の
    /// 帧を**復号だけして提示しない**（04 §6 手順 4。dropped に数えるが presentation には出さない）。
    /// decoder は提示順（PTS 順）に返す（F13）ので、最初の target 以上で闸门を解く。
    private func acceptFrame(_ frame: DecodedVideoFrame) {
        if let floor = discardBefore,
           frame.pts.isValid, frame.pts.compared(to: floor) == .orderedAscending {
            outcome.stats.dropped += 1
            outcome.stats.dropReasons[.seekDiscarded, default: 0] += 1
            return
        }
        discardBefore = nil
        queue.append(frame)
    }
    private var discardBefore: MediaTime?
    private var lastSamplePTS: MediaTime?

    private func presentDue() {
        guard let head = queue.first else { return }
        let now = time.now()
        if startHost == nil { startHost = now }
        if firstPTS == nil { firstPTS = head.pts }
        guard let start = startHost, let first = firstPTS else { return }

        // 締刻: audio clock が立っているなら clock の frame→host 対応（04 §5 の権威）。
        // 立っていない（音声なし・失敗・起動前）は #11 の暫定基点（壁時計 + PTS 差分）。
        let delayMS: Double
        if let clock = audioClock, clock.isRunning {
            delayMS = now.ms(since: clock.hostTime(for: head.pts))
        } else {
            delayMS = now.ms(since: start) - Self.mediaMS(first, head.pts)
        }
        guard delayMS >= 0 else { return }

        let frame = queue.removeFirst()
        if delayMS > config.lateThresholdMS {
            outcome.stats.late += 1
            outcome.stats.dropReasons[.late, default: 0] += 1
        }
        outcome.stats.presented += 1
        if lastPresentHost == nil {
            outcome.firstPresentDelayMS = delayMS
        } else if let previous = lastPresentHost {
            outcome.presentIntervalMS.append(now.ms(since: previous))
        }
        lastPresentHost = now
        lastPresentedPTS = frame.pts
        outcome.stats.total = max(outcome.stats.total, outcome.demuxedSampleCount)
        sampleDrift(at: now, presentedPTS: frame.pts)
        report?(.position(frame.pts))
    }

    /// drift 采样（04 §5 の符号系: + = 映像が遅れている）。100 ms 間隔で十分（UI 表示・
    /// 測定用途。SyncController の逐次判定は Phase 2 の #5/#6 で同じ原料を使う）。
    private func sampleDrift(at host: HostTime, presentedPTS: MediaTime) {
        guard let clock = audioClock, clock.isRunning else { return }
        if let previous = lastDriftSampleHost, host.ms(since: previous) < 100 { return }
        let audioPosition = clock.mediaTime(at: host)
        let driftMS = (audioPosition.seconds - presentedPTS.seconds) * 1_000
        outcome.clockDriftMS.append(driftMS)
        lastDriftSampleHost = host
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
        if let underrunBegan = underrunSince {
            outcome.audioUnderrunTotalMS += time.now().ms(since: underrunBegan)
            outcome.audioUnderrunEpisodes += 1
            underrunSince = nil
        }
        audio?.sink.stop()
        audioClock?.stop()
        audioRunning = false
        report?(.finished(outcome))
    }

    /// メディア時間の経過（ms）。PTS は timescale 違いを気にせず seconds 経由で十分正確（記録用途）。
    private static func mediaMS(_ from: MediaTime, _ to: MediaTime) -> Double {
        (to.seconds - from.seconds) * 1_000
    }
}
