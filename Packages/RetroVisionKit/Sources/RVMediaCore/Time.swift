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

    public init(numerator: Int64, denominator: Int64) {
        precondition(numerator > 0 && denominator > 0, "frame rate must be positive")
        let g = Self.gcd(numerator, denominator)
        let n = numerator / g, d = denominator / g
        precondition(n <= Int64(Int32.max) && d <= Int64(Int32.max), "frame rate does not fit Int32")
        self.numerator = Int32(n)
        self.denominator = Int32(d)
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
        let value = MediaMath.roundHalfEvenDivide(num, CMTimeValue(numerator))
        return CMTime(value: value, timescale: timescale)
    }

    /// 2 つの有理数の積。既約に保つ（MPEG-2 の frame_rate = code × (extension+1) の導出に使う）。
    public func multiplying(_ other: FrameRate) -> FrameRate {
        FrameRate(numerator: Int64(numerator) * Int64(other.numerator),
                  denominator: Int64(denominator) * Int64(other.denominator))
    }

    /// 符号なし整数値から作る（MPEG-2 の frame_rate_code など既知の小さい値からの構築）。
    public init(value: Int32) {
        self.init(numerator: Int64(value), denominator: 1)
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

/// ビット列の小さなリーダ。MPEG-2 のヘッダ解析など、byte 境界に落ちない語を読むために使う（01 §2）。
/// 境界外読みは nil を返す（例外を投げない。壊れたストリームは「読めなかった」扱う）。
public struct BitReader: Sendable {
    private let bytes: [UInt8]
    private var bitIndex: Int = 0

    public init(_ data: Data) { bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var bitsRead: Int { bitIndex }
    public var remainingBits: Int { bytes.count * 8 - bitIndex }

    /// 先頭から 32 bit 先読みする（start code 探索用。消費しない）。
    public func peekBits(_ count: Int) -> UInt32? {
        guard count >= 0, count <= 32, remainingBits >= count else { return nil }
        var value: UInt32 = 0
        for i in 0..<count {
            let bit = bitIndex + i
            let byte = bytes[bit / 8]
            let flag = UInt32((byte >> UInt8(7 - (bit % 8))) & 1)
            value = (value << 1) | flag
        }
        return value
    }

    public mutating func readBits(_ count: Int) -> UInt32? {
        guard let v = peekBits(count) else { return nil }
        bitIndex += count
        return v
    }

    public mutating func skipBits(_ count: Int) -> Bool {
        guard remainingBits >= count else { return false }
        bitIndex += count
        return true
    }

    /// byte 境界まで進める（MPEG-2 の user_data / extension_and_user_data の後に必要）。
    public mutating func alignToByte() -> Bool {
        let pad = (8 - (bitIndex % 8)) % 8
        return skipBits(pad)
    }

    /// MPEG-2 の start code（24 bit の 0x000001 + 6 bit の stream_id）を探す。
    /// 見つけた位置（次の payload の先頭 bit）を返す。見つからなければ nil。
    public mutating func advanceToStartCode() -> Int? {
        while remainingBits >= 32 {
            if let v = peekBits(32), v & 0xFFFFFF00 == 0x0000_0100 {
                bitIndex += 32
                return bitIndex
            }
            bitIndex += 8
        }
        return nil
    }

    /// `picture_start_code` の直後など、32 bit を読み飛ばす。
    public mutating func readStartCode() -> UInt8? {
        guard let v = readBits(24), v == 0x0000_01 else { return nil }
        return UInt8(truncatingIfNeeded: readBits(8) ?? 0)
    }
}

extension MediaMath {
    /// 16 bit の 2 の補数を Int に直す（MPEG-2 の offset / extension の符号付き語）。
    public static func signed16(_ value: UInt32) -> Int {
        let v = Int(value & 0xFFFF)
        return v >= 0x8000 ? v - 0x1_0000 : v
    }
}

/// 既知の標準レートに一致する場合だけ、その有理数値を返す（01 §2）。
/// 容器が frame rate を渡さない素材（MPEG-PS など）で、PTS の積算から特定する用途。
/// 標準に一致しない場合は nil を返す（推測で近い標準に倒さない。呼び出し側が `.formatRejected` で断る）。
/// sample の PTS 列からフレームレート特定する（01 §2 の追加経路）。
///
/// 実測（docs/experiments/EXP-001）: AVFoundation の sample 列は **decode 順**（B 帧のある素材では
/// PTS が昇順ではない）。先頭と末尾の差分で割ると GOP 構造で値が壊れる。PTS を重複除去して整列させ、
/// 中央値ではなく「フレーム間隔の分布」ではなく **総フレーム数 / 総時間** で測る
/// （GOP 内で間隔が不均一でも平均はレートに収束するため）。
public func frameRate(fromPTSs pts: [MediaTime]) -> FrameRate? {
    guard pts.count >= 8, let scale = pts.first?.timescale, scale != 0 else { return nil }
    let unique = Set(pts.filter { $0.timescale == scale }.map(\.value)).sorted()
    guard unique.count >= 8 else { return nil }
    let frameCount = unique.count - 1
    let spanSeconds = Double(unique.last! - unique.first!) / Double(scale)
    guard spanSeconds > 0, spanSeconds.isFinite else { return nil }
    let measuredFPS = Double(frameCount) / spanSeconds
    guard measuredFPS > 0, measuredFPS.isFinite else { return nil }
    let thousandth = FrameRate(numerator: 1_000, denominator: 1_001)
    let candidates = [
        FrameRate.film24,
        FrameRate.film24.multiplying(thousandth),
        FrameRate.pal,
        FrameRate(value: 25).multiplying(thousandth),
        FrameRate(value: 30).multiplying(thousandth),
        FrameRate(value: 30),
    ]
    for candidate in candidates where abs(measuredFPS - candidate.framesPerSecond) / candidate.framesPerSecond < 2e-4 {
        return candidate
    }
    return nil
}
