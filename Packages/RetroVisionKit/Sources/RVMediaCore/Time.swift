import CoreMedia
import Darwin
import Foundation

/// メディア側の時刻（PTS / DTS）。設計: docs/design/01-core-types.md §1。
///
/// 不変条件:
///   - `CMTime.valid == true` を常に満たすこと（sentinel に invalid を使わない）。
///   - timescale はストリーム単位で固定。変換は必ず `converted(to:)` を通す。
public typealias MediaTime = CMTime

/// メディア区間（seek 範囲、chapter 区間など）。
public typealias MediaRange = CMTimeRange

extension MediaTime {
    /// timescale の変更。丸めは half-even に固定する（01 §1）。
    /// CoreMedia の `CMTimeConvertScale` には half-even が無いため、整数演算で自力で求める。
    public func converted(to timescale: Int32) -> MediaTime {
        precondition(self.timescale != 0 && timescale != 0, "zero timescale")
        let value = MediaMath.roundHalfEvenDivide(CMTimeValue(self.value) * CMTimeValue(timescale),
                                                  CMTimeValue(self.timescale))
        return CMTime(value: value, timescale: timescale)
    }

    /// 整数比較（除算を伴わない比較）。時刻比較ではこれを使う。
    public func compared(to other: MediaTime) -> ComparisonResult {
        switch CMTimeCompare(self, other) {
        case let x where x < 0: return .orderedAscending
        case let x where x > 0: return .orderedDescending
        default: return .orderedSame
        }
    }

    /// ± milliseconds の幅を持つ区間（同期判定用）。
    public func range(aroundMS: Double) -> MediaRange {
        let half = CMTime(value: CMTimeValue(aroundMS.rounded(.toNearestOrEven)), timescale: 1_000)
        return CMTimeRange(start: self - half, end: self + half)
    }

    public var ms: Double {
        guard timescale != 0 else { return .nan }
        return CMTimeGetSeconds(self) * 1_000
    }
}

/// 有理数のフレームレート。double で 29.97 を持つかたちは 30000/1001 を持つかのどちらかだが、
/// 本プロジェクトでは必ず後者を使う（01 §2）。
public struct FrameRate: Sendable, Hashable, CustomStringConvertible {
    public var numerator: Int32
    public var denominator: Int32

    public init(numerator: Int32, denominator: Int32) {
        precondition(numerator > 0 && denominator > 0, "frame rate must be positive")
        let g = Self.gcd(Int64(numerator), Int64(denominator))
        self.numerator = Int32(Int64(numerator) / g)
        self.denominator = Int32(Int64(denominator) / g)
    }

    public static let ntscFilm = FrameRate(numerator: 24_000, denominator: 1_001)     // 23.976
    public static let ntsc = FrameRate(numerator: 30_000, denominator: 1_001)        // 29.97
    public static let pal = FrameRate(numerator: 25, denominator: 1)
    public static let film24 = FrameRate(numerator: 24, denominator: 1)

    public var description: String { "\(numerator)/\(denominator)" }

    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }

    /// n 帧めのフレーム先頭にあるべき時刻。丸めを積算しないため、長尺でも_drift_が出ない（01 §2）。
    public func presentationTime(frameIndex n: Int64, timescale: Int32) -> MediaTime {
        let num = CMTimeValue(n) * CMTimeValue(timescale) * CMTimeValue(denominator)
        let den = CMTimeValue(numerator)
        let value = Self.divideRoundHalfEven(num, den)
        return CMTime(value: value, timescale: timescale)
    }

    /// 指定時刻を含むフレーム番号の近似（`presentationTime(frameIndex:)` の逆関数）。
    /// 整数演算のみで求め、浮動小数の丸め誤差を混入させない。表示計画はこれに依存しない（05 §5.3）。
    public func frameIndex(containing time: MediaTime) -> Int64 {
        precondition(time.timescale != 0, "invalid media time")
        return Self.floorDiv(CMTimeValue(time.value) * CMTimeValue(numerator),
                             CMTimeValue(time.timescale) * CMTimeValue(denominator))
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b, r = a % b
        if r != 0 && ((r < 0) != (b < 0)) { return q - 1 }
        return q
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = Swift.abs(a), y = Swift.abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }

    static func divideRoundHalfEven(_ num: Int64, _ den: Int64) -> Int64 { MediaMath.roundHalfEvenDivide(num, den) }
}

/// ホスト時刻。mach absolute time 基準で、変換係数は初期化時に 1 度だけ取得する。
public struct HostTime: Sendable, Hashable, Comparable {
    public var machTime: UInt64

    public init(machTime: UInt64) { self.machTime = machTime }

    public static func now() -> HostTime { HostTime(machTime: mach_absolute_time()) }

    public static func < (lhs: HostTime, rhs: HostTime) -> Bool { lhs.machTime < rhs.machTime }

    public func ms(since other: HostTime) -> Double {
        HostTime.ms(from: other.machTime, to: machTime)
    }

    public static func ms(from: UInt64, to: UInt64) -> Double {
        let info = mach_timebase_info_data_t.numer_and_den
        let delta = Int64(to) - Int64(from)
        return Double(delta) * Double(info.numer) / Double(info.denom) / 1_000_000
    }
}

extension mach_timebase_info_data_t {
    fileprivate static let numer_and_den: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()
}

/// 計測可能な時間源。テストでは `DeterministicTimeSource` を注入する（09 §3）。
public protocol TimeSource: Sendable {
    func now() -> HostTime
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> HostTime { HostTime.now() }
}

/// 手動で進められる時間源。単体テスト用（09 §3）。
/// actor にしない理由: `TimeSource.now()` は nonisolated 要件のため、Swift 6 では
/// actor 準拠がデータ競合扱いになる（ロックで守る）。
public final class DeterministicTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: HostTime
    private let ticksPerMS: UInt64

    public init(startMS: Double = 0) {
        let info = mach_timebase_info_data_t.numer_and_den
        let ticks = max(1, UInt64(1_000_000 * Double(info.denom) / Double(info.numer)))
        self.ticksPerMS = ticks
        self.current = HostTime(machTime: UInt64(startMS) * ticks)
    }

    public func now() -> HostTime {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        let delta = UInt64((ms * Double(ticksPerMS)).rounded(.toNearestOrEven))
        current = HostTime(machTime: current.machTime + delta)
    }
}

/// 再生クロックのスナップショット（01 §1）。audio master clock を正とする（04 §5）。
public struct PlaybackClock: Sendable, Hashable {
    public var media: MediaTime
    public var host: HostTime
    public var rate: Double
    /// + = 映像が遅れている（04 §5 の drift と同じ符号系）。
    public var driftMS: Double

    public init(media: MediaTime, host: HostTime, rate: Double, driftMS: Double) {
        self.media = media
        self.host = host
        self.rate = rate
        self.driftMS = driftMS
    }
}

/// 時刻・周期計算に使う整数演算のみ。浮動小数を混入させないための道具立て（01 §2）。
public enum MediaMath {
    /// half-even 整数除算。
    public static func roundHalfEvenDivide(_ num: Int64, _ den: Int64) -> Int64 {
        precondition(den != 0, "zero divisor")
        let negative = (num < 0) != (den < 0)
        let n = Swift.abs(num), d = Swift.abs(den)
        var q = n / d
        let r = n % d
        let twice = r * 2
        if twice > d || (twice == d && q % 2 == 1) { q += 1 }
        return negative ? -q : q
    }

    public static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        precondition(b != 0, "zero divisor")
        let q = a / b, r = a % b
        if r != 0 && ((r < 0) != (b < 0)) { return q - 1 }
        return q
    }

    public static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 {
        precondition(b != 0, "zero divisor")
        let q = a / b, r = a % b
        if r != 0 && ((r > 0) == (b > 0)) { return q + 1 }
        return q
    }
}
