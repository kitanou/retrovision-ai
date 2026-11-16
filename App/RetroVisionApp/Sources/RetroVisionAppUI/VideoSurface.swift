import AVKit
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import RVMediaCore
import RVPlaybackEngine
import SwiftUI

// MARK: - 提示サーフェス（#5: 既定は Metal。OQ-26 の暫定経路は RV_LEGACY_PRESENT=1 のフォールバック）
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

/// 提示面の種類。既定は Metal（#5）。`RV_LEGACY_PRESENT` を設定すると暫定の
/// AVSampleBufferDisplayLayer 経路（OQ-26）に戻せる。Metal デバイスが無い環境も同じく暫定経路。
enum VideoSurfaceMode {
    case metal, legacy
    static var current: VideoSurfaceMode {
        if ProcessInfo.processInfo.environment["RV_LEGACY_PRESENT"] != nil { return .legacy }
        return MTLCreateSystemDefaultDevice() == nil ? .legacy : .metal
    }
}

/// view がホストする提示面の layer。
enum VideoSurfaceLayer {
    case legacy(AVSampleBufferDisplayLayer)
    case metal(CAMetalLayer)
}

/// 提示面をホストする view。親（PlayerScreenView）が displayAspectValue で枠の比率を決めるので、
/// layer は枠いっぱい（引き伸ばさない）。Metal では drawableSize を view の実ピクセル寸法に保つ
/// （窓リサイズ・全画面・Retina。寸法が変わったら最後の frame を描き直す）。
final class VideoLayerView: NSView {
    let mode: VideoSurfaceMode
    let videoLayer = AVSampleBufferDisplayLayer()
    let metalLayer = CAMetalLayer()
    /// drawable 寸法が変わった（窓リサイズ・全画面・backing scale 変更）。Metal の再描画用。
    var onDrawableResized: (@MainActor () -> Void)?
    /// transport バー再表示のための活動配線（#22 の実装補完。nil の間は nobody に等しい）。
    /// local monitor とは独立の配送経路（両方届いても showControls は冪等なので無害）。
    var onControlsActivity: (@MainActor () -> Void)?

    convenience override init(frame frameRect: NSRect) {
        self.init(mode: .current, frame: frameRect)
    }

    init(mode: VideoSurfaceMode = .current, frame frameRect: NSRect = .zero) {
        self.mode = mode
        super.init(frame: frameRect)
        wantsLayer = true
        switch mode {
        case .legacy:
            layer = videoLayer
            videoLayer.videoGravity = .resize
        case .metal:
            metalLayer.device = MTLCreateSystemDefaultDevice()
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.displaySyncEnabled = true        // 05 §7
            metalLayer.presentsWithTransaction = false  // UI との同期を待たない
            metalLayer.maximumDrawableCount = 3         // in-flight 上限（00 §5）と揃える
            layer = metalLayer
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1.0
        switch mode {
        case .legacy:
            videoLayer.frame = bounds
            videoLayer.contentsScale = scale
        case .metal:
            metalLayer.frame = bounds
            metalLayer.contentsScale = scale
            let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                              height: max(1, (bounds.height * scale).rounded()))
            if metalLayer.drawableSize != size {
                metalLayer.drawableSize = size
                onDrawableResized?()
            }
        }
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
        needsLayout = true   // backing scale が窓に載って初めて決まる（drawableSize の再計算）
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
    let onLayer: @MainActor (VideoSurfaceLayer) -> Void
    /// Metal の drawable 寸法が変わった（再描画の契機）。
    var onResize: (@MainActor () -> Void)? = nil
    /// transport バー再表示の活動配線（#22。window の mouse-moved 生成と owner 配送の
    /// 受け口を確保した上で、View 側に「動きをactivityとして扱う」意図を渡す）。
    var onActivity: (@MainActor () -> Void)? = nil

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.onControlsActivity = onActivity
        view.onDrawableResized = onResize
        switch view.mode {
        case .legacy: onLayer(.legacy(view.videoLayer))
        case .metal: onLayer(.metal(view.metalLayer))
        }
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.onControlsActivity = onActivity
        nsView.onDrawableResized = onResize
        nsView.needsLayout = true
    }
}
