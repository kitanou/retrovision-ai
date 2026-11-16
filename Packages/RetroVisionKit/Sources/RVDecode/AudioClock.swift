import CoreMedia
import Foundation
import RVMediaCore

// MARK: - audio master clock（04 §5）
//
// 権威は音声側。sink の rendered frame 位置は schedule 時の (framePosition, PTS) 対応表で
// PTS に解決される（対応は decoder が帧数を保証することで成立する — 04 §5）。
// 権威サンプル（rendered PTS）のあいだは壁時計から等倍で補間し、次のサンプルで更新する。
// 補間はサンプル間隔（数 ms）以内に限定されるので、rate のずれは累積しない。
//
// actor にしない理由: `TimeSource.now()` は nonisolated 同期要件のため（DeterministicTimeSource
// の注記と同じ。ロックで守る）。

public final class AudioClock: MediaClock, @unchecked Sendable {
    private struct Sample {
        var host: HostTime
        var media: MediaTime
    }

    private let sink: any AudioSink
    private let time: any TimeSource
    private let lock = NSLock()
    private var anchor: Sample?
    private var latest: Sample?

    public init(sink: any AudioSink, time: any TimeSource) {
        self.sink = sink
        self.time = time
    }

    public func now() -> HostTime { time.now() }

    /// sink の再生位置をクロックに採り込む。再生駆動の each tick から呼ぶ（1〜4 ms 間隔）。
    /// 最初の採り込みがクロックの開始（anchor）になる。
    @discardableResult
    public func sample() -> Bool {
        guard let pts = sink.renderedPTS() else { return false }
        let host = time.now()
        lock.lock(); defer { lock.unlock() }
        latest = Sample(host: host, media: pts)
        if anchor == nil { anchor = Sample(host: host, media: pts) }
        return true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        anchor = nil
        latest = nil
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return latest != nil
    }

    public func mediaTime(at host: HostTime) -> MediaTime {
        lock.lock(); defer { lock.unlock() }
        guard let reference = latest ?? anchor else { return .zero }
        let deltaMS = host.ms(since: reference.host)
        return CMTimeAdd(reference.media, CMTime(seconds: deltaMS / 1_000, preferredTimescale: 1_000_000))
    }

    public func hostTime(for media: MediaTime) -> HostTime {
        lock.lock(); defer { lock.unlock() }
        guard let reference = latest ?? anchor else { return time.now() }
        let deltaMS = (media.seconds - reference.media.seconds) * 1_000
        return reference.host.advancing(ms: deltaMS)
    }

    /// クロック自身の補間誤差（ms）。+ = 壁時計補間が権威より先へ進んでいる。
    /// SyncController が使う映像 drift（04 §5）は再生側が測る（PlaybackOutcome.clockDriftMS）。
    public var currentDriftMS: Double {
        get async {
            let host = time.now()
            let estimated = mediaTime(at: host)
            guard let fresh = sink.renderedPTS() else { return 0 }
            return (estimated.seconds - fresh.seconds) * 1_000
        }
    }
}
