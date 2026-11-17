import Foundation

// MARK: - 障害分離（06 §6）: failure breaker と遅延統計
//
// 純粋な値型ロジック（時刻は呼び出し側が秒で渡す — テストで決定的に動かせる）。
// 実際の推論（Core ML 呼び出し）はこの上に載る。モデル実行は再生を止めてはならない
// （INV-1）ので、breaker は「AI を使うか」を決めるだけで、音声・運送には影響しない。

/// 直近 `windowSize` 回の結果のうち `failureThreshold` 回以上失敗したら open（既定 5 中 3）。
/// open は `openDuration`（既定 10 分）保ち、その後 half-open で試行を 1 本だけ通す。
/// 試行が成功したら closed（履歴を空に）、失敗したら再び open。
public struct FailureBreaker: Sendable {
    public struct Config: Sendable, Hashable {
        public var windowSize: Int
        public var failureThreshold: Int
        public var openDurationSeconds: Double
        public init(windowSize: Int = 5, failureThreshold: Int = 3, openDurationSeconds: Double = 600) {
            self.windowSize = max(1, windowSize)
            self.failureThreshold = max(1, failureThreshold)
            self.openDurationSeconds = max(0, openDurationSeconds)
        }
    }

    public let config: Config
    public private(set) var state: ModelHealth.BreakerState = .closed
    private var recent: [Bool] = []          // true = 失敗。直近 windowSize 件
    private var openedAtSeconds: Double?
    private var trialInFlight = false

    public init(config: Config = .init()) { self.config = config }

    /// 直近窓の失敗率（0...1）。履歴が無ければ 0。
    public var failureRatio: Double {
        recent.isEmpty ? 0 : Double(recent.filter { $0 }.count) / Double(recent.count)
    }

    /// 推論を投入してよいか。closed は常に可、open は期間内なら不可、期間を過ぎたら
    /// half-open に移り**1 本だけ**可（結果を `record` するまで次は不可）。
    public mutating func allowRequest(atSeconds now: Double) -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            guard let openedAtSeconds, now - openedAtSeconds >= config.openDurationSeconds else { return false }
            state = .halfOpen
            trialInFlight = true
            return true
        case .halfOpen:
            guard !trialInFlight else { return false }
            trialInFlight = true
            return true
        }
    }

    /// 推論結果を記録する。half-open の試行は成功で closed、失敗で再 open。
    public mutating func record(success: Bool, atSeconds now: Double) {
        switch state {
        case .halfOpen:
            trialInFlight = false
            if success {
                state = .closed
                recent.removeAll()
                openedAtSeconds = nil
            } else {
                state = .open
                openedAtSeconds = now
            }
        case .closed:
            recent.append(!success)
            if recent.count > config.windowSize { recent.removeFirst(recent.count - config.windowSize) }
            if recent.filter({ $0 }).count >= config.failureThreshold {
                state = .open
                openedAtSeconds = now
                recent.removeAll()
            }
        case .open:
            break   // open 中は投入されないはず。遅れて届いた結果は無視する
        }
    }
}

/// モデル 1 本の健全性（遅延 p50/p95・失敗率・breaker）。遅延は直近 `capacity` 件。
public struct ModelHealthTracker: Sendable {
    public private(set) var breaker: FailureBreaker
    private var latenciesMS: [Double] = []
    private let capacity: Int

    public init(breaker: FailureBreaker = .init(), capacity: Int = 120) {
        self.breaker = breaker
        self.capacity = max(1, capacity)
    }

    public mutating func allowRequest(atSeconds now: Double) -> Bool {
        breaker.allowRequest(atSeconds: now)
    }

    public mutating func recordSuccess(latencyMS: Double, atSeconds now: Double) {
        latenciesMS.append(latencyMS)
        if latenciesMS.count > capacity { latenciesMS.removeFirst(latenciesMS.count - capacity) }
        breaker.record(success: true, atSeconds: now)
    }

    public mutating func recordFailure(atSeconds now: Double) {
        breaker.record(success: false, atSeconds: now)
    }

    public var health: ModelHealth {
        ModelHealth(p50MS: percentile(0.5), p95MS: percentile(0.95),
                    failureRatio: breaker.failureRatio, breakerState: breaker.state)
    }

    private func percentile(_ q: Double) -> Double {
        guard !latenciesMS.isEmpty else { return 0 }
        let sorted = latenciesMS.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))
        return sorted[index]
    }
}
