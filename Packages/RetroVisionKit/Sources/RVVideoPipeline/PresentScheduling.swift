import Foundation
import RVMediaCore

// MARK: - 表示スケジュール（05 §5.3）
//
// 表示は vsync の整数個単位で「何本同じ帧を出すか」を決める。整数演算のみで求め、
// 丸め誤差が毎秒同じ位置に集中しないよう分散させる。

/// 表示系のリフレッシュレート。実測値を使う（08 §3 の signal で想定と突き合わせる）。
public struct DisplayRefresh: Sendable, Hashable, CustomStringConvertible {
    public var numerator: Int64
    public var denominator: Int64

    public init(hz: Int64) { self.numerator = hz; self.denominator = 1 }
    public init(numerator: Int64, denominator: Int64) {
        precondition(numerator > 0 && denominator > 0)
        let g = Self.gcd(numerator, denominator)
        self.numerator = numerator / g
        self.denominator = denominator / g
    }

    public static let hz60 = DisplayRefresh(numerator: 60, denominator: 1)
    public static let hz59_94 = DisplayRefresh(numerator: 60_000, denominator: 1_001)
    public static let hz50 = DisplayRefresh(numerator: 50, denominator: 1)
    public static let hz120 = DisplayRefresh(numerator: 120, denominator: 1)

    public var description: String { "\(numerator)/\(denominator)" }

    /// 実数値（Hz）。検出した refresh を既知標準に丸める比較に使う（05 §5.3）。
    public var hertzValue: Double { Double(numerator) / Double(denominator) }

    /// vsync 1 本の周期（秒）。提示予約の時間計算はここでやる（CA host clock は秒単位 —
    /// `MTLDrawable.present(at:)` と同一単位。ms にしない注意は呼び出し側で扱う）。
    public var periodSeconds: Double { Double(denominator) / Double(numerator) }

    /// n 番目の vsync の時刻（秒、有理数の分子分母のまま）。
    public func vsyncTime(n: Int64) -> (num: Int64, den: Int64) { (n * denominator, numerator) }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = Swift.abs(a), y = Swift.abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}

/// 帧番号 → 提示すべき vsync 番号の計画。
public struct PresentSchedule: Sendable, Hashable {
    public let sourceFrameRate: FrameRate
    public let refresh: DisplayRefresh
    /// 源と表示が名目上ロックされている場合の整列猶予（vsync の 1/1000）。
    /// これが無いと、59.94→59.94 で毎帧わずかに遅れて drift が積算される。
    public let alignTolerancePerMille: Int64

    public init(sourceFrameRate: FrameRate, refresh: DisplayRefresh, alignTolerancePerMille: Int64 = 1) {
        self.sourceFrameRate = sourceFrameRate
        self.refresh = refresh
        self.alignTolerancePerMille = max(0, alignTolerancePerMille)
    }

    /// n 帧目の提示先 vsync。
    ///
    /// 方針: 提示予定時刻に**遅れる側**（ceil）を既定とし、整列猶予内のずれは同じ vsync として扱う。
    /// 提前提示（早出し）は A/V 同期の予測を壊すため取らない。
    public func vsyncIndex(forFrame n: Int64) -> Int64 {
        // 提示予定時刻（秒）= n * den / num。vsync 数 = 時刻 × refresh。
        let num = n * Int64(sourceFrameRate.denominator) * refresh.numerator
        let den = Int64(sourceFrameRate.numerator) * refresh.denominator
        let whole = MediaMath.floorDiv(num, den)
        let frac = num - whole * den
        if frac == 0 { return whole }
        // 名目上同一レート（59.94 → 59.94 など）は整列扱い。ずれが vsync の 0.1% 未満なら同じ vsync に寄せる。
        if frac * 1_000 <= den * alignTolerancePerMille { return whole }
        if (den - frac) * 1_000 <= den * alignTolerancePerMille { return whole + 1 }
        return whole + 1
    }

    /// n 帧目を何 vsync 保持するか。
    public func holdCount(forFrame n: Int64) -> Int {
        Int(vsyncIndex(forFrame: n + 1) - vsyncIndex(forFrame: n))
    }

    /// 保持パターンの分布（診断・ベンチに載せる。08 §7.2）。
    public func holdDistribution(first n: Int) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for i in 0..<n { counts[holdCount(forFrame: Int64(i)), default: 0] += 1 }
        return counts
    }

    /// 保持長の幅。2 以上の開きがある場合は表示が不均等になっている（jitter の予兆）。
    public func holdSpread(first n: Int) -> Int {
        let holds = (0..<n).map { Int64(holdCount(forFrame: Int64($0))) }
        guard let lo = holds.min(), let hi = holds.max() else { return 0 }
        return Int(hi - lo)
    }

    /// 源と表示の組み合わせが長期的に安定か（総 vsync 数がフレームレート比と一致するか）。
    public func isPeriodicallyConsistent(first n: Int) -> Bool {
        guard n > 0 else { return false }
        let totalVsyncs = vsyncIndex(forFrame: Int64(n)) - vsyncIndex(forFrame: 0)
        let expected = MediaMath.roundHalfEvenDivide(
            Int64(n) * refresh.numerator * Int64(sourceFrameRate.denominator),
            refresh.denominator * Int64(sourceFrameRate.numerator))
        return abs(totalVsyncs - expected) <= 1
    }
}

// MARK: - plan hash

/// plan の正準表現から安定した ID を作る（08 §7.2）。
/// 一致性の検査に使うだけで、衝突耐性しかない非暗号ハッシュである点に注意する。
public enum PlanHash {
    public static func hex(_ canonical: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x100_0000_01b3
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "fnv1a64-%016llx", hash)
    }
}
