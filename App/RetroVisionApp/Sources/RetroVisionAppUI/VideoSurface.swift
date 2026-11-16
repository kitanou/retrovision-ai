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
    }

    override var isFlipped: Bool { true }
}

struct VideoSurfaceView: NSViewRepresentable {
    let onLayer: @MainActor (AVSampleBufferDisplayLayer) -> Void

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        onLayer(view.videoLayer)
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        nsView.needsLayout = true
    }
}
