import Foundation
import RVMediaCore

// MARK: - キャデンス解析（05 §5.1 の CadenceAnalyzer。GPU 非依存の純粋ロジック）
//
// 入力は frame ごとの comb スコア（`rv_fieldMatch_sad_v1` の 8x8 block SAD から host 側が作る
// 「1 frame 内の 2 field の不一致量」。0 に近い = 2 field が同じ瞬間、大きい = 別の瞬間 = 縞が出る）。
// しきい値を超えた frame を「縞あり（combed）」と数える。
//
// 3:2 pulldown（telecine）の field 配置は AA BB BC CD DD なので、5 frame を 1 周期として
//   [clean, clean, combed, combed, clean]
// が繰り返される。連続 10 frame の縞あり/なしが、このパターンのどれかの位相に完全一致したら
// telecine32 と判定する（一致の位相 = inverse telecine で「どの frame が復元に使えるか」の基準）。
// 一旦 telecine に入った後は、パターンの予測と 2 frame 連続で食い違ったら即座に抜ける
// （hysteresis 2 frame。静止場面の 1 frame だけの食い違いでは抜けない）。
// 誤検出による 24p 化は表示が引っかかるので、確信度が低いとき（窓が満ちていない等）は
// telecine を宣言しない。

public struct CadenceDecision: Sendable, Hashable {
    public var cadence: Cadence
    /// 0...1。telecine は窓が満ちて完全一致しているとき 1.0、ロック中の予測一致は 0.9。
    public var confidence: Double
    /// telecine のとき、直近 frame の周期内位置（0...4。パターン [clean, clean, combed, combed, clean]）。
    public var telecinePhase: Int?
    /// 判定の根拠（直近窓の縞あり/なしのビット列の FNV-1a 64 を 16 進で。画像比較で後から検証する — 09 §5）。
    public var evidence: String
}

public struct CadenceAnalyzer: Sendable {
    public static let windowSize = 10
    private static let pattern: [Bool] = [false, false, true, true, false]   // true = combed

    public let combThreshold: Double
    /// 非 nil なら、縞ありの判定を「直近窓の中央値の `relativeFactor` 倍を超える」相対しきい値にする
    /// （縞なしの基準値が内容で 0.0065〜0.0155 と動くため、絶対値だけでは実素材に使えない — 実測）。
    /// 絶対値の `combThreshold` は下限として残す（平坦な画面の揺らぎを縞と見なさない）。
    public let relativeFactor: Double?
    private var window: [Bool] = []
    private var recentScores: [Double] = []
    private var lockedPhase: Int?            // 次に来る frame の周期内位置（telecine ロック中のみ）
    private var consecutiveMismatches = 0

    public init(combThreshold: Double = 0.02, relativeFactor: Double? = nil) {
        self.combThreshold = combThreshold
        self.relativeFactor = relativeFactor
    }

    /// 1 frame 分の comb スコアを取り込み、現在の判定を返す。
    public mutating func ingest(combScore: Double) -> CadenceDecision {
        recentScores.append(combScore)
        if recentScores.count > Self.windowSize { recentScores.removeFirst(recentScores.count - Self.windowSize) }
        let combed: Bool
        if let relativeFactor {
            // telecine の縞ありは 5 frame に 2（< 半数）なので、窓の中央値は縞なしの水準になる。
            let sorted = recentScores.sorted()
            let median = sorted[(sorted.count - 1) / 2]   // 下側の中央値（窓が浅い間も縞あり値を拾わない）
            combed = combScore > max(combThreshold, relativeFactor * median)
        } else {
            combed = combScore > combThreshold
        }
        window.append(combed)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }

        if let expectedPhase = lockedPhase {
            let expected = Self.pattern[expectedPhase]
            consecutiveMismatches = (combed == expected) ? 0 : consecutiveMismatches + 1
            if consecutiveMismatches >= 2 {
                lockedPhase = nil            // 一致が崩れたら即座に telecine を抜ける（hysteresis 2 frame）
                consecutiveMismatches = 0
            } else {
                lockedPhase = (expectedPhase + 1) % 5
                return decision(.telecine32, confidence: 0.9, phase: expectedPhase)
            }
        }

        if window.count == Self.windowSize, let phase = Self.matchingPhase(window) {
            lockedPhase = (phase + 1) % 5
            consecutiveMismatches = 0
            return decision(.telecine32, confidence: 1.0, phase: phase)
        }
        return classifyWithoutTelecine()
    }

    /// 窓全体がパターンに完全一致する位相（直近 frame の周期内位置）。無ければ nil。
    /// 一致が複数ある場合（全て同じ値のとき等）は起こらない（パターンは 2/5 が combed）。
    private static func matchingPhase(_ flags: [Bool]) -> Int? {
        let n = flags.count
        for offset in 0..<5 {
            // flags[k] は周期内位置 (offset + k) % 5 の frame と仮定する。
            if (0..<n).allSatisfy({ flags[$0] == pattern[(offset + $0) % 5] }) {
                return (offset + n - 1) % 5
            }
        }
        return nil
    }

    private func classifyWithoutTelecine() -> CadenceDecision {
        let n = window.count
        let combedCount = window.filter { $0 }.count
        guard n >= 5 else { return decision(.unknown, confidence: 0, phase: nil) }
        if combedCount == 0 { return decision(.progressive, confidence: 1.0, phase: nil) }
        if Double(combedCount) >= 0.8 * Double(n) { return decision(.interlaced22, confidence: 0.9, phase: nil) }
        return decision(.mixed, confidence: 0.5, phase: nil)
    }

    private func decision(_ cadence: Cadence, confidence: Double, phase: Int?) -> CadenceDecision {
        CadenceDecision(cadence: cadence, confidence: confidence, telecinePhase: phase, evidence: evidenceHash())
    }

    private func evidenceHash() -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for flag in window {
            hash ^= flag ? 1 : 0
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
