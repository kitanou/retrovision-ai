import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import RVDecode
import RVMediaCore

// MARK: - 音声線の単体テスト（#10。04 §4・§5、EXP-002 A1/A2/A6 の回帰固定）
//
// 方針（09 §2）: fixture が無い場合は失敗（silent skip で環境差を隠さない）。
// 1. AC-3 → PCM: 480 帧 quantum に分割されていること・実 PCM 仕様の確定・PTS の連続。
// 2. AudioClock: rendered frame 位置 ↔ PTS の対応と、host 補間が権威に追随すること。
// 3. DTS: AVFoundation はトラックを列挙しない（A6）。shim ゲートまで音声なしで再生する
//    設計の根拠をここで固定する。

private struct MissingFixture: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "fixture が存在しない: \(path)（sh Scripts/gen-fixtures.sh で生成する）"
    }
}

/// PCM の帧数（= 線形 PCM では sample 数。実測: GetNumSamples と一致するが byte 長から取る）。
private func pcmFrameCount(_ buffer: CMSampleBuffer) throws -> Int {
    guard let format = CMSampleBufferGetFormatDescription(buffer),
          let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
        throw MissingFixture(path: "PCM format description")
    }
    let bytesPerFrame = Int(pointer.pointee.mBytesPerFrame)
    guard bytesPerFrame > 0, let block = CMSampleBufferGetDataBuffer(buffer) else {
        throw MissingFixture(path: "PCM data block")
    }
    return CMBlockBufferGetDataLength(block) / bytesPerFrame
}

/// clock テスト用の架空 sink（再生位置をテストが直接動かせる。04 §5 の対応表と同じ形）。
private final class FakeAudioSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private struct Entry { var start: Int64; var end: Int64; var pts: MediaTime }
    private var table: [Entry] = []
    private var nextPosition: Int64 = 0
    private var rendered: Int64 = 0
    private var running = false
    let sampleRate: Double
    var startError: Error?

    init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }

    func start() throws {
        if let startError { throw startError }
        lock.lock(); running = true; lock.unlock()
    }
    func stop() { lock.lock(); running = false; lock.unlock() }
    func pause() {}
    func resume() {}
    func flush() { lock.lock(); table.removeAll(); nextPosition = 0; lock.unlock() }

    func setVolume(_ gain: Double) { lock.lock(); volume = gain; lock.unlock() }
    var currentVolume: Double { lock.lock(); defer { lock.unlock() }; return volume }
    private var volume = 1.0

    func schedule(_ pcm: AudioPCM) throws {
        let frames = Int64(try pcmFrameCount(pcm.buffer))
        lock.lock()
        table.append(Entry(start: nextPosition, end: nextPosition + frames, pts: pcm.pts))
        nextPosition += frames
        lock.unlock()
    }

    func scheduledAheadMS() -> Double {
        lock.lock(); let ahead = nextPosition - rendered; lock.unlock()
        guard ahead > 0 else { return 0 }
        return Double(ahead) / sampleRate * 1_000
    }

    func renderedFramePosition() -> Int64 { lock.lock(); defer { lock.unlock() }; return rendered }

    func renderedPTS() -> MediaTime? {
        lock.lock(); defer { lock.unlock() }
        guard running,
              let entry = table.first(where: { $0.start <= rendered && rendered < $0.end }),
              entry.pts.isValid else { return nil }
        return CMTimeAdd(entry.pts, CMTime(seconds: Double(rendered - entry.start) / sampleRate,
                                           preferredTimescale: 1_000_000))
    }

    var outputLatencyMS: Double { 0 }
    var outputFormat: AudioFormatDescription? {
        AudioFormatDescription(codec: .lpcm16, sampleRate: Int32(sampleRate), channelCount: 2, bitDepth: 16)
    }

    // テストフック
    func setRenderedFrames(_ frames: Int64) { lock.lock(); rendered = frames; lock.unlock() }
    var scheduledFrames: Int64 { lock.lock(); defer { lock.unlock() }; return nextPosition }
    var isRunningForTest: Bool { lock.lock(); defer { lock.unlock() }; return running }
}

final class AudioPathTests: XCTestCase {
    private var fixturesDir: URL {
        // Tests/RVDecodeTests/ ← Packages/RetroVisionKit/ ← リポジトリルート
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVDecodeTests
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

    private func audioTrack(of stream: ProbedStream) throws -> (TrackInfo, AudioFormatDescription) {
        guard let track = stream.tracks.first(where: { $0.kind == .audio }),
              case let .audio(format) = track.format else {
            throw MissingFixture(path: "audio track not found")
        }
        return (track, format)
    }

    // MARK: - 1. AC-3 → PCM（A1 の実経路 + A2 の quantum 分割）

    func testAC3ToPCMYieldsBoundedQuantaWithContinuousPTS() async throws {
        let url = try fixtureURL("ntsc480i-ac3-01.mpg")
        let demuxer = AVFoundationDemuxer(url: url)
        let probed = try await demuxer.probe()
        let (track, format) = try audioTrack(of: probed)
        XCTAssertEqual(format.codec, .ac3, "fixture の声明（AC-3）")

        let decoder = AVFoundationAudioDecoder(source: demuxer)
        try await decoder.configure(format, policy: DecodePolicy())

        // 2 秒ぶんだけ読む（全長確認は e2e に委ね、量子・仕様・PTS の契約をここで固定する）。
        var quantaCount = 0
        var maxFrames = 0
        var totalFrames = 0
        var previousPTS: MediaTime?
        var previousFrames = 0
        var observedFirstFormat: AudioFormatDescription?
        for try await quantum in await decoder.pcm(for: track.id) {
            quantaCount += 1
            let frames = try pcmFrameCount(quantum.buffer)
            maxFrames = max(maxFrames, frames)
            totalFrames += frames
            XCTAssertLessThanOrEqual(frames, AVFoundationAudioDecoder.quantumFrames,
                                    "quantum が 480 帧を超えた（A2 の分割が効いていない）")

            let pts = quantum.pts
            XCTAssertTrue(pts.isValid, "quantum の PTS が無い（clock の原料が壊れる）")
            if let previous = previousPTS {
                XCTAssertEqual(previous.compared(to: pts), .orderedAscending, "quantum PTS が単調増加でない")
                // 帧数と PTS の対応（clock が frame↔PTS 対応表を作る前提。04 §5）
                let gapMS = (pts.seconds - previous.seconds) * 1_000
                XCTAssertEqual(gapMS, Double(previousFrames) / 48.0, accuracy: 0.1,
                               "帧数と PTS 進みが一致しない（対応表がずれる）")
            }
            previousPTS = pts
            previousFrames = frames
            if observedFirstFormat == nil,
               let description = CMSampleBufferGetFormatDescription(quantum.buffer) {
                observedFirstFormat = AudioFormatDescription(sampleFormatDescription: description)
            }
            if totalFrames >= 96_000 || quantaCount >= 1_000 { break }
        }
        XCTAssertGreaterThanOrEqual(quantaCount, 100, "2 秒 ≈ 200 quantum のはず")
        XCTAssertEqual(maxFrames, AVFoundationAudioDecoder.quantumFrames,
                       "480 帧に割めた証拠（max = quantum）が必要")

        let outputFormat = await decoder.outputFormat
        XCTAssertNotNil(outputFormat, "最初の chunk から実仕様を確定させる")
        XCTAssertEqual(outputFormat?.codec, .lpcm16)
        XCTAssertEqual(outputFormat?.sampleRate, 48_000)
        XCTAssertEqual(outputFormat?.channelCount, 2)
        XCTAssertEqual(observedFirstFormat, outputFormat,
                       "getter が返す仕様は実際に流れた仕様と一致する")
    }

    // MARK: - 2. AudioClock（04 §5 の frame↔PTS↔host 対応）

    func testAudioClockResolvesRenderedPositionAndInterpolates() throws {
        let sink = FakeAudioSink()
        let time = DeterministicTimeSource(startMS: 1_000)
        let clock = AudioClock(sink: sink, time: time)
        XCTAssertFalse(clock.isRunning, "採样前は稼働扱いにしない（映像側は暫定 pacing で動く）")

        // 1 秒ぶんを schedule（先頭 PTS = 10.0 s）し、再生位置 0.5 s 地点を採る。
        let builder = PCMBuilder(sampleRate: 48_000)
        let first = builder.make(frames: 48_000, ptsSeconds: 10.0)
        try sink.schedule(first)
        try sink.start()
        sink.setRenderedFrames(24_000)
        XCTAssertTrue(clock.sample(), "rendered PTS が取れるときは採样成功")
        XCTAssertTrue(clock.isRunning)

        // 同一 host なら mediaTime = 権威そのもの（10.5 s）。
        XCTAssertEqual(clock.mediaTime(at: time.now()).seconds, 10.5, accuracy: 0.001)

        // host を 250 ms 進めた補間は等倍（10.75 s）。
        time.advance(ms: 250)
        XCTAssertEqual(clock.mediaTime(at: time.now()).seconds, 10.75, accuracy: 0.001)

        // hostTime(for:) は逆関数: 11.0 s の提示締切は +250 ms の地点。
        let host = clock.hostTime(for: CMTime(seconds: 11.0, preferredTimescale: 1_000_000))
        XCTAssertEqual(host.ms(since: time.now()), 250, accuracy: 0.001)

        // 権威が進めば補間はその値から続く（rate ズレが累積しない）。
        sink.setRenderedFrames(24_480)               // 10.51 s
        XCTAssertTrue(clock.sample())
        time.advance(ms: 240)
        XCTAssertEqual(clock.mediaTime(at: time.now()).seconds, 10.75, accuracy: 0.001)

        // 停止ではクロックも止まる。
        clock.stop()
        XCTAssertFalse(clock.isRunning)
    }

    func testAudioClockStopsWhenSinkHasNoDevice() throws {
        let sink = FakeAudioSink()
        sink.startError = PlaybackError.decode(.formatRejected, message: "device", recovery: .giveUp(reason: "audio"))
        let time = DeterministicTimeSource(startMS: 0)
        let clock = AudioClock(sink: sink, time: time)
        let builder = PCMBuilder(sampleRate: 48_000)
        try sink.schedule(builder.make(frames: 4_800, ptsSeconds: 0))
        XCTAssertFalse(clock.sample(), "start 前は rendered 位置が無い（sample 失敗）")
        XCTAssertFalse(clock.isRunning)
    }

    // MARK: - 3. DTS は列挙されない（EXP-002 A6。OQ-02 のゲート根拠）

    func testDTSIsNotEnumeratedAsTrackByAVFoundation() async throws {
        let url = try fixtureURL("ntsc480i-dts-01.mpg")
        let stream = try await AVFoundationDemuxer(url: url).probe()
        let audio = stream.tracks.filter { $0.kind == .audio }
        XCTAssertTrue(audio.isEmpty,
                      "AVFoundation は DTS をトラックとして現さない（A6 の実測）。"
                      + "現れた場合は経路が変わったので OQ-02 の判断を更新する")
    }
}

// MARK: - テスト用 PCM の作り手（lpcm16 interleaved の線形 PCM chunk）

private final class PCMBuilder {
    let sampleRate: Int32
    init(sampleRate: Int32) { self.sampleRate = sampleRate }

    func make(frames: Int, ptsSeconds: Double) -> AudioPCM {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Double(sampleRate)
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = UInt32(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 4
        asbd.mBytesPerPacket = 4
        asbd.mChannelsPerFrame = 2
        asbd.mBitsPerChannel = 16
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let format = description else {
            preconditionFailure("テスト用の CMAudioFormatDescription が作れない: \(status)")
        }
        let byteCount = frames * 4
        // 自前確保した memory を block に渡す（internal allocation だと「empty」状態で
        // GetDataPointer に到達できない。CMBlockBuffer.h の外部データ契約）。
        let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        memset(memory, 0, byteCount)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: memory,
                                                 blockLength: byteCount,
                                                 blockAllocator: nil,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let dataBlock = block
        else {
            memory.deallocate()
            preconditionFailure("テスト用の CMBlockBuffer が作れない")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(frames),
                                                         timescale: sampleRate),
                                        presentationTimeStamp: CMTime(seconds: ptsSeconds,
                                                                      preferredTimescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: dataBlock,
                                   dataReady: true,
                                   makeDataReadyCallback: nil,
                                   refcon: nil,
                                   formatDescription: format,
                                   sampleCount: frames,
                                   sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil as UnsafePointer<CMItemIndex>?,
                                   sampleBufferOut: &buffer) == noErr,
              let sampleBuffer = buffer
        else {
            preconditionFailure("テスト用の PCM sample buffer が作れない")
        }
        return AudioPCM(track: TrackID(900), buffer: sampleBuffer)
    }
}
