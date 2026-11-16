import AVKit
import CoreMedia
import CoreVideo
import Foundation
import RVMediaCore
import RVPlaybackEngine
import SwiftUI

// MARK: - 提示サーフェス（OQ-26 の暫定経路。#5 の Metal 提示に置き換わるまでの間つなぎ）
//
// 05 §7 の正式経路は engine が CAMetalLayer の drawable 予約に描く形。暫定は
// 「engine が present を済らせた帧を VideoPresentSink へ渡す」契約で、UI 側は
// AVSampleBufferDisplayLayer に enqueue するだけ（スケーリングも deint も通さない —
// 画質ではなく UI の回路と比率の正しさを見るための経路）。

/// 復号帧を AVSampleBufferDisplayLayer に積む。主役は再生線なので、積めない帧は
/// 落ちる（engine 側の in-flight 上限と displayMissed で計数される — INV-1）。
@MainActor
final class SurfaceSink: VideoPresentSink {
    private weak var layer: AVSampleBufferDisplayLayer?
    private let onAspectResolved: @Sendable (Double) -> Void
    /// 比率の解決は format 単位で 1 回（毎帧やると resolve の分岐で見え方が変わらない）。
    private var resolvedFor: VideoFormatDescription?

    init(layer: AVSampleBufferDisplayLayer,
         onAspectResolved: @escaping @Sendable (Double) -> Void) {
        self.layer = layer
        self.onAspectResolved = onAspectResolved
    }

    func receive(_ frame: DecodedVideoFrame) async {
        guard let layer else { return }
        if resolvedFor != frame.format {
            resolvedFor = frame.format
            let resolution = AspectResolver.resolve(codedSize: frame.format.codedSize,
                                                   signals: frame.format.aspectSignals,
                                                   policy: .followSource)
            if resolution.targetDAR.h > 0 {
                onAspectResolved(resolution.targetDAR.value)
            }
        }
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription
        else { return }
        var timing = CMSampleTimingInfo(duration: frame.duration,
                                        presentationTimeStamp: frame.pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr,
              let sample
        else { return }
        if layer.status == .failed {
            layer.flush()   // 積み失敗の後片付け（次を積める状態に戻す。再生は止めない）
        }
        // enqueue(_:) は macOS 15 で非推奨（sampleBufferRenderer へ移行の案内）。
        // #5 でこの経路自体が Metal 提示に置き換わるため、暫定まま許容する。
        layer.enqueue(sample)
    }

    /// 再生の組み替え（close / 開き直し）で積み残しを捨てる。
    func reset() {
        layer?.flush()
    }
}

// MARK: - SwiftUI 側の surface

/// AVSampleBufferDisplayLayer をホストする view。親（PlayerScreenView）が
/// displayAspectValue で枠の比率を決めるので、layer は枠いっぱいに .resize（引き伸ばさない）。
final class VideoLayerView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    /// transport バー再表示のための活動配線（#22 の実装補完。nil の間は nobody に等しい）。
    /// local monitor とは独立の配送経路（両方届いても showControls は冪等なので無害）。
    var onControlsActivity: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = videoLayer
        videoLayer.videoGravity = .resize
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1.0
        // fullscreen 遷移などで窓の属性が作り直される経路の保险（setter はフラグ書き換えのみ）。
        window?.acceptsMouseMovedEvents = true
    }

    override var isFlipped: Bool { true }

    /// #22 の二次原因（実測 2026-11-17): NSWindow は既定で acceptsMouseMovedEvents=false。
    /// 既定のままだと mouseMoved イベント自体が生成されず、local monitor
    /// （ControlsActivityMonitor）は何も観測できない — 配線だけでは足りなかった。
    /// 映像面が載る window では mouse-moved を生成させる（生成→sendEvent→monitor で再表示）。
    /// fullscreen など表示環境側が後から false に戻した場合に備え、layout 時にも再宣言する。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    /// 映像面上のマウス移動は owner 配送の受け口でもある（window が mouse-moved を生成した
    /// 上で deepest hit-view に届く経路）。local monitor とは独立の配送で、両方届いても
    /// showControls は冪等なので無害。
    override func mouseMoved(with event: NSEvent) {
        onControlsActivity?()
        super.mouseMoved(with: event)
    }
}

struct VideoSurfaceView: NSViewRepresentable {
    let onLayer: @MainActor (AVSampleBufferDisplayLayer) -> Void
    /// transport バー再表示の活動配線（#22。window の mouse-moved 生成と owner 配送の
    /// 受け口を確保した上で、View 側に「動きをactivityとして扱う」意図を渡す）。
    var onActivity: (@MainActor () -> Void)? = nil

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.onControlsActivity = onActivity
        onLayer(view.videoLayer)
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.onControlsActivity = onActivity
        nsView.needsLayout = true
    }
}
