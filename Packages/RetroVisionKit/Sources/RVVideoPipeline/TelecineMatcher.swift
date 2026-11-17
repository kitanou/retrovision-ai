import CoreVideo
import Foundation

// MARK: - telecine の field matching の判断（画面・GPU に依存しない部品）
//
// frame ごとの縞スコアと PTS を受け、`CadenceAnalyzer` の判定から「この frame をどう扱うか」を返す。
//   - telecine32 に**確信してロックしている間だけ**動く。周期内位置 2・3（縞あり）は前 frame と織って
//     映画コマを復元（weaveWithPrevious）、それ以外（元から progressive）は deinterlace せず
//     weave のまま（keepWoven）。ロックしていない間は従来どおり（none）— 誤った weave は
//     現状の motion-adaptive より悪く見えるため。
//   - PTS が連続でない（seek・落とした frame・menu のループ・item 切替）と判定と前 frame を捨てる
//     （`previousIsContinuous = false`。呼び出し側は前 frame を渡さない）。

public enum CombMetric {
    /// 「歯」指標: 輝度が上下の両隣に対して同符号で 12 階調超外れる画素の割合（縞の櫛歯）。
    /// 縞なしの基準値は内容で動く（実測 0.0065〜0.0155）ので、絶対値ではなく相対しきい値で使う。
    /// 列は 1 つおきに間引く（割合なので尺度は変わらない）。NV12 の輝度面だけを読む。
    public static func toothScore(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard h >= 3, w >= 1 else { return 0 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var teeth = 0, total = 0
        for y in 1..<(h - 1) {
            let row = y * stride, up = (y - 1) * stride, down = (y + 1) * stride
            var x = 0
            while x < w {
                let c = Int(p[row + x])
                let a = c - Int(p[up + x]), b = c - Int(p[down + x])
                if (a > 12 && b > 12) || (a < -12 && b < -12) { teeth += 1 }
                total += 1
                x += 2
            }
        }
        return total == 0 ? 0 : Double(teeth) / Double(total)
    }
}

public struct TelecineMatcher: Sendable {
    public struct Result: Sendable, Hashable {
        public var request: RenderFrameInput.FieldMatchRequest
        /// 直前に渡した frame が PTS 上で連続か。false なら前 frame を graph に渡してはならない。
        public var previousIsContinuous: Bool
        public var decision: CadenceDecision
    }

    private var analyzer = CadenceAnalyzer(combThreshold: 0.004, relativeFactor: 2.5)
    private var lastPTS: Double?
    private var lastDecision = CadenceDecision(cadence: .unknown, confidence: 0, telecinePhase: nil, evidence: "")

    public init() {}

    /// 1 frame を取り込む。`duration` は frame の表示長（秒）。
    public mutating func match(score: Double, pts: Double, duration: Double) -> Result {
        var continuous = false
        if let lastPTS, duration > 0 {
            continuous = abs((pts - lastPTS) - duration) < duration * 0.25
        }
        lastPTS = pts
        if !continuous {
            // 連続でない: 判定を捨てて取り直す（この frame は新しい列の先頭として取り込む）。
            analyzer = CadenceAnalyzer(combThreshold: analyzer.combThreshold, relativeFactor: analyzer.relativeFactor)
        }
        let decision = analyzer.ingest(combScore: score)
        lastDecision = decision
        guard continuous, decision.cadence == .telecine32, decision.confidence >= 0.9,
              let phase = decision.telecinePhase else {
            return Result(request: .none, previousIsContinuous: continuous, decision: decision)
        }
        return Result(request: (phase == 2 || phase == 3) ? .weaveWithPrevious : .keepWoven,
                      previousIsContinuous: continuous, decision: decision)
    }

    /// close・item 切替・surface の付け替えで状態を捨てる。
    public mutating func reset() {
        analyzer = CadenceAnalyzer(combThreshold: analyzer.combThreshold, relativeFactor: analyzer.relativeFactor)
        lastPTS = nil
    }
}
