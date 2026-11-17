import CoreVideo
import Foundation
import Metal
import QuartzCore
import RVEnhancement
import RVMediaCore
import RVMLRuntime
import RVVideoPipeline

// MARK: - 提示の出口（05 §7 / OQ-26 の置換）
//
// engine は「提示時刻に達した frame」を `VideoFramePresenter` へ渡す。結果（`FrameDeliveryOutcome`）で
// 渡せたか・捨てられたかが engine に戻り、捨てた場合は `PlaybackOutcome.displayMissed` に数える
// （保存則: presented = delivered + displayMissed。PresentHandoffTests で固定）。
// 提示時刻の権威は engine（音声 clock）のままで、presenter は時刻を作らない。

public enum FrameDeliveryOutcome: Sendable {
    /// 提示面が frame を受理した（Metal では drawable へ描いて present 予約済み）。
    case delivered
    /// 提示面が受理できなかった（in-flight 上限・drawable 喪失・描画失敗）。再生は止めない（INV-1）。
    case dropped
}

public protocol VideoFramePresenter: Sendable {
    /// `plan` は engine が昇格済みの描画計画（frame 境界で差し替わる）。nil は計画未確定。
    func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome
}

/// 既存の `VideoPresentSink`（暫定の AVSampleBufferDisplayLayer 経路）を常に受理する presenter に包む。
/// Metal 経路が実画面で確認できるまでの切替可能なフォールバック。
struct LegacySinkPresenter: VideoFramePresenter {
    let sink: any VideoPresentSink
    func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome {
        await sink.receive(frame)
        return .delivered
    }
}

/// Metal 提示（RVVideoPipeline）を engine の presenter 契約に載せる。
/// CAMetalLayer は UI が供給する（RVVideoPipeline も engine も AppKit を知らない）。
public final class MetalFramePresenter: VideoFramePresenter, @unchecked Sendable {
    private let graph: MetalRenderGraph
    private let presenter: MetalPresenter
    private let lock = NSLock()
    private var lastAspect: AspectRatio?
    /// 直前に渡した frame の pixel buffer（motion-adaptive の動き検出用）。
    private var previousBuffer: CVPixelBuffer?
    /// telecine の field matching の判断（確信してロックしている間だけ動く）。
    private var matcher = TelecineMatcher()
    private var onAspectResolved: (@Sendable (Double) -> Void)?

    /// Metal デバイスが無い環境では nil（呼び出し側は暫定経路へ戻す）。
    public init?() {
        guard let context = try? MetalRenderContext(),
              let graph = try? MetalRenderGraph(context: context) else { return nil }
        self.graph = graph
        presenter = MetalPresenter(graph: graph)
        presenter.timing = .immediate   // 提示時刻は engine（音声 clock）が決める
    }

    // MARK: AI 段（06 §3。tier が lightML 以上で plan に superResolution 段があるときだけ使う）
    //
    // 再生を止めない（INV-1）ための方針:
    //  - 推論は同時に 1 つだけ。実行中なら、その間の frame は待たず非強調のまま提示する
    //    （待たせて frame を捨てるより、強調を諦めて提示する方を選ぶ — 06 §7）。
    //  - 失敗（breaker open・shape 不一致・期限超過・描画失敗・未 load）も、その frame を非強調で提示する。
    //  - 期限は frame の表示長（予算）。超えた結果は捨てる（古い画像を保持するとフリーズに見える）。

    public struct EnhancementStatistics: Sendable, Hashable {
        /// AI 段を通して提示した frame 数。
        public var enhanced = 0
        /// 推論が実行中だったため非強調で提示した frame 数。
        public var skippedBusy = 0
        /// AI 段が失敗して非強調で提示した frame 数。
        public var fellBack = 0
        public var lastError: String?
    }

    private var enhancer: MLEnhancementStage?
    private var enhancementInFlight = false
    private var enhancementStatistics = EnhancementStatistics()
    /// 推論の期限（ms）。nil なら frame の表示長（29.97 fps で約 33 ms）。
    public var enhancementBudgetMS: Double? {
        get { lock.withLock { _enhancementBudgetMS } }
        set { lock.withLock { _enhancementBudgetMS = newValue } }
    }
    private var _enhancementBudgetMS: Double?

    public var statistics: EnhancementStatistics { lock.withLock { enhancementStatistics } }

    /// AI 段を設定する。render graph は presenter のものを共有する（同じ command queue・texture cache）。
    public func setEnhancement(runtime: any ModelRuntimeProtocol, model: ModelID, tiling: MLEnhancementStage.Tiling) {
        lock.withLock {
            enhancer = MLEnhancementStage(graph: graph, runtime: runtime, model: model, tiling: tiling)
            enhancementStatistics = EnhancementStatistics()
        }
    }

    public func clearEnhancement() { lock.withLock { enhancer = nil } }

    /// 推論を 1 つだけ走らせるための取得。取れなければ false（その frame は非強調で提示する）。
    private func claimEnhancement() -> Bool {
        lock.withLock {
            if enhancementInFlight { enhancementStatistics.skippedBusy += 1; return false }
            enhancementInFlight = true
            return true
        }
    }
    private func releaseEnhancement() { lock.withLock { enhancementInFlight = false } }

    public func attachLayer(_ layer: CAMetalLayer?) {
        presenter.attachLayer(layer)
        if layer == nil {
            presenter.clearLast()
            lock.withLock { previousBuffer = nil; matcher.reset() }
        }
    }

    /// 表示比率（targetDAR）が決まる・変わるたびに通知する（UI が view の枠を決める）。
    public func setAspectHandler(_ handler: (@Sendable (Double) -> Void)?) {
        lock.withLock {
            onAspectResolved = handler
            lastAspect = nil
        }
    }

    /// 窓リサイズ・一時停止中の再描画（最後の frame を現在の drawable 寸法で描き直す）。
    public func redraw() { presenter.redrawLast() }

    public func present(_ frame: DecodedVideoFrame, plan: RenderPlan?) async -> FrameDeliveryOutcome {
        guard let plan else { return .dropped }
        notifyAspect(plan.output.aspect.targetDAR)
        // telecine の判断: interlaced 素材だけ縞スコアを測る（progressive では不要）。
        let interlaced = frame.format.interlace.fieldCount >= 2
        let score = interlaced ? CombMetric.toothScore(frame.pixelBuffer) : 0
        let (previous, fieldMatch) = lock.withLock { () -> (CVPixelBuffer?, RenderFrameInput.FieldMatchRequest) in
            var request = RenderFrameInput.FieldMatchRequest.none
            var continuous = true
            if interlaced {
                let r = matcher.match(score: score, pts: frame.pts.seconds, duration: frame.duration.seconds)
                request = r.request
                continuous = r.previousIsContinuous
            }
            // PTS が連続でなければ前 frame は無関係（seek・menu のループ・落とし frame）: 渡さない。
            let p = continuous ? previousBuffer : nil
            previousBuffer = frame.pixelBuffer
            return (p, request)
        }
        let input = RenderFrameInput(pixelBuffer: frame.pixelBuffer, color: frame.format.color,
                                     interlace: frame.format.interlace, aspect: plan.output.aspect,
                                     frameID: frame.id, previousPixelBuffer: previous, fieldMatch: fieldMatch)
        // AI 段: tier が lightML 以上で、plan の superResolution 段が設定済みのモデルを指すときだけ。
        let stage = lock.withLock { enhancer }
        if let stage, plan.tier >= .lightML,
           let request = plan.stage(of: .superResolution)?.parameters as? SuperResolutionParameters,
           request.model == stage.model, claimEnhancement() {
            defer { releaseEnhancement() }
            do {
                let budget = enhancementBudgetMS ?? max(frame.duration.seconds * 1_000, 1)
                let rgb = try await stage.enhance(input, plan: plan, frameID: frame.id,
                                                  deadline: HostTime.now().advancing(ms: budget))
                let outcome = try presenter.presentEnhanced(rgb, aspect: plan.output.aspect, pts: frame.pts,
                                                            frameID: frame.id)
                lock.withLock { enhancementStatistics.enhanced += 1 }
                switch outcome {
                case .scheduled: return .delivered
                case .dropped: return .dropped
                }
            } catch {
                // 失敗は frame を非強調のまま提示する（下の通常経路へ）。再生・音声は止めない。
                lock.withLock {
                    enhancementStatistics.fellBack += 1
                    enhancementStatistics.lastError = String(describing: error)
                }
            }
        }
        do {
            switch try presenter.present(input, plan: plan, pts: frame.pts) {
            case .scheduled: return .delivered
            case .dropped: return .dropped
            }
        } catch {
            return .dropped   // 描画失敗は frame を捨てて次へ（再生・音声は止めない）
        }
    }

    private func notifyAspect(_ dar: AspectRatio) {
        let handler: (@Sendable (Double) -> Void)? = lock.withLock {
            guard lastAspect != dar else { return nil }
            lastAspect = dar
            return onAspectResolved
        }
        handler?(dar.value)
    }
}
