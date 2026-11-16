import AVFoundation
import CoreMedia
import Foundation
import RVMediaCore

// MARK: - AVAudioEngine による音声出力（04 §4）
//
// schedule は (framePosition, PTS) の対応表を内部に持つ。`scheduleBuffer(at: nil)` は
// 順次連結なので開始位置の予測は決定的（nextPosition の加算で追える）。
// rendered frame 位置 → PTS の解決と、出力装置の遅延補正を clock の原料にする（04 §5）。
//
// actor にしない理由: AudioSink の契約（start/renderedFramePosition…）は同期要件で、
// clock が each tick から同期で読む（actor 適合できない。DeterministicTimeSource と同じ
// 「ロックで守る class」の形式を選ぶ）。AVAudioEngine / AVAudioPlayerNode の該当 API は
// スレッドセーフな使用が想定されている（render thread 由来の値は読むだけ）。

public final class AVFoundationAudioSink: AudioSink, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let avFormat: AVAudioFormat
    private let pcm: AudioFormatDescription
    private let lock = NSLock()

    private struct Entry {
        var start: Int64
        var end: Int64          // 排他的
        var pts: MediaTime
    }

    private var table: [Entry] = []
    private var nextPosition: Int64 = 0
    private var running = false

    /// 対応表の保持長（再生位置より古い項目から捨てる）。
    private static let tableTrimMS: Double = 5_000

    public init(pcmFormat: AudioFormatDescription) throws {
        guard pcmFormat.sampleRate > 0, pcmFormat.channelCount > 0 else {
            throw PlaybackError.decode(.formatRejected, message: "PCM 仕様から AVAudioFormat を作れません",
                                       recovery: .giveUp(reason: "audio"))
        }
        // 復号器が要求する形式（16bit packed interleaved）と一致する。EXP-002 でこの形式が
        // 返ることを実測済み。将来 float 等を受け取るときはここで分岐を追加する。
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(pcmFormat.sampleRate),
                                         channels: AVAudioChannelCount(pcmFormat.channelCount),
                                         interleaved: true) else {
            throw PlaybackError.decode(.formatRejected, message: "AVAudioFormat が作れません",
                                       recovery: .giveUp(reason: "audio"))
        }
        self.avFormat = format
        self.pcm = pcmFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: AudioSink 契約

    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        lock.unlock()
        engine.prepare()
        try engine.start()        // 出力装置が無い環境では throw。縮退は呼び出し側で扱う。
        player.play()
        lock.lock(); running = true; lock.unlock()
    }

    public func stop() {
        player.stop()
        lock.lock(); running = false; lock.unlock()
        resetTable()
    }

    /// 停止は再生位置を凍らせる（AVAudioPlayerNode.pause の契約）。対応表と nextPosition は
    /// 不変のままなので、再開後も framePosition↔PTS の対応は壊れない（04 §5）。
    public func pause() {
        guard isRunning else { return }
        player.pause()
    }

    public func resume() {
        guard isRunning else { return }
        player.play()
    }

    public func flush() {
        player.reset()
        resetTable()
    }

    public func schedule(_ pcm: AudioPCM) throws {
        let buffer = pcm.buffer
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            throw PlaybackError.decode(.formatRejected, message: "PCM の format description が読めません",
                                       recovery: .giveUp(reason: "audio"))
        }
        let bytesPerFrame = Int(pointer.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0,
              let block = CMSampleBufferGetDataBuffer(buffer) else {
            throw PlaybackError.decode(.corruptStream, message: "PCM block が読めません",
                                       recovery: .giveUp(reason: "audio"))
        }
        // PCM の mFramesPerPacket は 1（実測）。frame 数は byte 長から求める。
        let frames = CMBlockBufferGetDataLength(block) / bytesPerFrame
        guard frames > 0 else { return }
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: nil, dataPointerOut: &base) == noErr,
              let base else {
            throw PlaybackError.decode(.corruptStream, message: "PCM data に到達できません",
                                       recovery: .giveUp(reason: "audio"))
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat,
                                               frameCapacity: AVAudioFrameCount(frames)) else {
            throw PlaybackError(kind: .internalFailure("audio-buffer"),
                                recovery: .giveUp(reason: "audio"),
                                userMessage: "PCM バッファを確保できません")
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frames)
        let avBytesPerFrame = Int(avFormat.streamDescription.pointee.mBytesPerFrame)
        guard avBytesPerFrame == bytesPerFrame else {
            throw PlaybackError.decode(.formatRejected, message: "PCM 仕様不一致（frame 長）",
                                       recovery: .giveUp(reason: "audio"))
        }
        // packed interleaved int16 の単一 buffer へそのまま写す（render thread では呼ばれない）。
        // AVAudioPCMBuffer の int16ChannelData は interleaved で 1 項目（本 SDK で実測形）。
        guard let destination = pcmBuffer.int16ChannelData?[0] else {
            throw PlaybackError(kind: .internalFailure("audio-buffer"),
                                recovery: .giveUp(reason: "audio"),
                                userMessage: "PCM buffer list が取れません")
        }
        memcpy(destination, base, frames * avBytesPerFrame)

        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock()
        table.append(Entry(start: nextPosition, end: nextPosition + Int64(frames),
                           pts: pts.isValid ? pts : .invalid))
        nextPosition += Int64(frames)
        trimTable()
        lock.unlock()
        // 順次連結（at: nil, options: []）。player は prefill 後に start する（session 側）。
        player.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
    }

    public func scheduledAheadMS() -> Double {
        let rendered = renderedFramePosition()
        lock.lock()
        let ahead = nextPosition - rendered
        lock.unlock()
        guard ahead > 0 else { return 0 }
        return Double(ahead) / avFormat.sampleRate * 1_000
    }

    public func renderedFramePosition() -> Int64 {
        guard running, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        // player 文脈の sampleTime = 再生済み frame 位置（playerTime(forNodeTime:) の契約）。
        return playerTime.sampleTime
    }

    public func renderedPTS() -> MediaTime? {
        let position = renderedFramePosition() - Int64((outputLatencyMS / 1_000 * avFormat.sampleRate).rounded())
        guard position >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = table.first(where: { $0.start <= position && position < $0.end }),
              entry.pts.isValid else { return nil }
        let offset = Double(position - entry.start) / avFormat.sampleRate
        return CMTimeAdd(entry.pts, CMTime(seconds: offset, preferredTimescale: 1_000_000))
    }

    /// 出力経路の遅延（ms）。AVAudioNode.outputPresentationLatency は「この node の出力が
    /// 装置に到達するまでの pipeline の遅延（秒）」（AVAudioNode.h の定義）。player について
    /// 読めば mixer + 装置の遅延までを含む。装置未 start では 0 を返す。
    /// 値の当否は e2e の drift 実測で検証する（04 §9）。本 SDK に outputLatency は無い。
    public var outputLatencyMS: Double {
        max(0, player.outputPresentationLatency) * 1_000
    }

    public var outputFormat: AudioFormatDescription? { pcm }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: 内部

    private func resetTable() {
        lock.lock(); table.removeAll(); nextPosition = 0; lock.unlock()
    }

    /// lock は呼び出し側で保持済み（schedule の critical section から呼ばれる）。
    private func trimTable() {
        let rendered = renderedFramePosition()
        let cutoff = rendered - Int64(Self.tableTrimMS / 1_000 * avFormat.sampleRate)
        while let first = table.first, first.end < cutoff { table.removeFirst() }
    }
}
