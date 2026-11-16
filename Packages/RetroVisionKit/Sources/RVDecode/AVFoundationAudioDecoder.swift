import AVFoundation
import CoreMedia
import Foundation
import RVMediaCore

// MARK: - AVFoundation 経路の音声復号（04 §4、EXP-002 A1/A2 の実装）
//
// 実測で確定した形: AC-3 等は demuxer の PCM 変換 outputSettings でシステムに復号させ、
// 復号器側の仕事は (a) 目標仕様の決定、(b) 変換 chunk（~8192 帧＝A2）の 480 帧 quantum
// への分割、(c) 実出力仕様の確定と診断、である。DTS のように AVFoundation がトラックを
// 列挙しない素材（A6）はそもそもここへ到達しない（Phase 4 の shim ゲート、OQ-02）。

public actor AVFoundationAudioDecoder: AudioDecoderProtocol {
    /// 04 §4 の quantum（10 ms @48 kHz）。render thread で確保しない前制として小さく刻む。
    public static let quantumFrames = 480

    private let source: any PCMSampleSource
    private var sourceFormat: AudioFormatDescription?
    private var target: PCMTargetSettings?
    /// 最初の chunk の format description から実仕様を確定させる（probe の実測と同じ手順）。
    private let observation = FormatObservation()

    public init(source: any PCMSampleSource) {
        self.source = source
    }

    public var pathInfo: DecodePathInfo {
        DecodePathInfo(path: .software,
                       reason: "AVFoundation linear-PCM transform（EXP-002 A1。追加依存なし）",
                       codecName: sourceFormat?.codec.rawValue)
    }

    public var outputFormat: AudioFormatDescription? { observation.format }

    public func configure(_ format: AudioFormatDescription, policy: DecodePolicy) async throws {
        sourceFormat = format
        target = Self.target(for: format)
    }

    public func pcm(for track: TrackID) async -> AsyncThrowingStream<AudioPCM, any Error> {
        guard let target else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: PlaybackError.decode(.formatRejected,
                                                                  message: "音声が設定されていません",
                                                                  recovery: .giveUp(reason: "audio")))
            }
        }
        let source = self.source
        let observation = self.observation
        let track = track
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await chunk in await source.pcmSamples(for: track, target: target) {
                        if observation.format == nil,
                           let description = CMSampleBufferGetFormatDescription(chunk.buffer) {
                            observation.format = AudioFormatDescription(sampleFormatDescription: description)
                        }
                        for quantum in Self.quanta(of: chunk) {
                            continuation.yield(quantum)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 仕様と分割

    /// 変換の目標仕様。音声クロックの正は PCM なので 48 kHz 基準に寄せる（04 §5）。
    /// mono ソースでも 2ch に寄って返ることは実測済み（EXP-002 §3。5.1 配置は実盤で再測＝OQ-16）。
    private static func target(for format: AudioFormatDescription) -> PCMTargetSettings {
        let resolved = pcmFormat(for: format)
        return PCMTargetSettings(sampleRate: Double(resolved.sampleRate),
                                 channelCount: Int(resolved.channelCount))
    }

    /// 変換が返すことになっている PCM の記述。AudioSink を組む側もこれを使う
    /// （規則を二重化しない。sink と decoder は同じ实例仕様でつながる）。
    public static func pcmFormat(for format: AudioFormatDescription) -> AudioFormatDescription {
        var rate = Int(format.sampleRate)
        if !(8_000...192_000).contains(rate) { rate = 48_000 }
        let channels = max(2, Int(format.channelCount))
        return AudioFormatDescription(codec: .lpcm16, rawFormatType: FourCC.code("lpcm"),
                                     sampleRate: Int32(rate), channelCount: Int32(channels),
                                     bitDepth: 16)
    }

    /// PCM chunk を quantum に分割する。ソースの block は reader に再利用されうるため、
    /// 各 quantum は独立した block にコピーする（3840 B/10 ms。呼び出し側は再生スレッドではない）。
    /// 分割できない形（想定外のレイアウト）は無理せずそのまま通す（再生を止めない）。
    static func quanta(of chunk: AudioPCM) -> [AudioPCM] {
        let buffer = chunk.buffer
        let total = CMSampleBufferGetNumSamples(buffer)
        guard total > quantumFrames,
              let format = CMSampleBufferGetFormatDescription(buffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return [chunk] }
        let asbd = pointer.pointee
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0, asbd.mSampleRate > 0 else { return [chunk] }
        guard let block = CMSampleBufferGetDataBuffer(buffer),
              CMBlockBufferGetDataLength(block) >= total * bytesPerFrame
        else { return [chunk] }

        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let audioTimescale = Int32(asbd.mSampleRate)
        var output: [AudioPCM] = []
        var offset = 0
        while offset < total {
            let frames = min(quantumFrames, total - offset)
            let byteCount = frames * bytesPerFrame
            // 自前で確保した memory へ圧縮コピーし、その ownership を新 block に渡す。
            // （CMBlockBufferCopyDataBytes は source の非連続配置も吸収する。04 §4）
            let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset * bytesPerFrame,
                                             dataLength: byteCount,
                                             destination: memory) == kCMBlockBufferNoErr else {
                memory.deallocate()
                return [chunk]
            }
            var newBlock: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                     memoryBlock: memory,
                                                     blockLength: byteCount,
                                                     blockAllocator: nil,
                                                     customBlockSource: nil,
                                                     offsetToData: 0,
                                                     dataLength: byteCount,
                                                     flags: 0,
                                                     blockBufferOut: &newBlock) == kCMBlockBufferNoErr,
                  let destination = newBlock
            else {
                memory.deallocate()
                return [chunk]   // 分割失敗。チャンクのまま渡す（quantum 約束は崩れるが音声は止まらない）
            }

            // PTS は帧数に応じて進める。PCM は sample 数 = frame 数（実測: EXP-002 で
            // GetNumSamples が 8192 を返した）。duration は 1 sample（1 frame）分。
            let startOffset = CMTime(value: CMTimeValue(Int64(offset)), timescale: audioTimescale)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: audioTimescale),
                presentationTimeStamp: pts.timescale > 0 ? CMTimeAdd(pts, startOffset) : .invalid,
                decodeTimeStamp: .invalid)
            var sliced: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                       dataBuffer: destination,
                                       dataReady: true,
                                       makeDataReadyCallback: nil,
                                       refcon: nil,
                                       formatDescription: format,
                                       sampleCount: frames,
                                       sampleTimingEntryCount: 1,
                                       sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 0,
                                       sampleSizeArray: nil as UnsafePointer<CMItemIndex>?,
                                       sampleBufferOut: &sliced) == noErr,
                  let sliced
            else { return [chunk] }
            output.append(AudioPCM(track: chunk.track, buffer: sliced))
            offset += frames
        }
        return output
    }

    /// 実 PCM 仕様の共有箱（stream の Task から設定し、actor 側 getter が読む）。
    /// actor 隔離をまたがない @unchecked の共有可変状態（単一 writer、読むだけ）。
    private final class FormatObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var _format: AudioFormatDescription?
        var format: AudioFormatDescription? {
            get { lock.lock(); defer { lock.unlock() }; return _format }
            set { lock.lock(); defer { lock.unlock() }; _format = newValue }
        }
    }
}

extension AVFoundationDemuxer: PCMSampleSource {}
