import CoreVideo
import Foundation
import Metal
import QuartzCore
import RVMediaCore
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
    private let presenter: MetalPresenter
    private let lock = NSLock()
    private var lastAspect: AspectRatio?
    /// 直前に渡した frame の pixel buffer（motion-adaptive の動き検出用）。
    private var previousBuffer: CVPixelBuffer?
    private var onAspectResolved: (@Sendable (Double) -> Void)?

    /// Metal デバイスが無い環境では nil（呼び出し側は暫定経路へ戻す）。
    public init?() {
        guard let context = try? MetalRenderContext(),
              let graph = try? MetalRenderGraph(context: context) else { return nil }
        presenter = MetalPresenter(graph: graph)
        presenter.timing = .immediate   // 提示時刻は engine（音声 clock）が決める
    }

    public func attachLayer(_ layer: CAMetalLayer?) {
        presenter.attachLayer(layer)
        if layer == nil {
            presenter.clearLast()
            lock.withLock { previousBuffer = nil }
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
        let previous = lock.withLock { () -> CVPixelBuffer? in
            let p = previousBuffer
            previousBuffer = frame.pixelBuffer
            return p
        }
        let input = RenderFrameInput(pixelBuffer: frame.pixelBuffer, color: frame.format.color,
                                     interlace: frame.format.interlace, aspect: plan.output.aspect,
                                     frameID: frame.id, previousPixelBuffer: previous)
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
