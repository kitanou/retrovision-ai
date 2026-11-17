import CoreVideo
import Foundation
import RVMediaCore
import RVMLRuntime
import RVVideoPipeline

// MARK: - AI 段（06 §4・§5、07）: Metal の描画 → Core ML のタイル推論 → RGB texture
//
// 1. 入力 frame を deinterlace + 色変換して、取り込み域の寸法の RGB buffer（IOSurface 付き）へ描く（GPU）。
// 2. その buffer をタイルに分けて Core ML で推論し、合成する（`TiledInference`）。
// 3. 結果の buffer を texture として取り込んで返す。最終の scale / 提示は `presentRGB` が受け持つ。
//
// 失敗（breaker open・shape 不一致・期限超過・描画失敗）はすべて `PlaybackError` の値で返す。
// 呼び出し側はその frame を**非強調のまま**提示する（INV-1・06 §3）。この段は再生時刻を持たない。

public struct MLEnhancementStage: Sendable {
    public struct Tiling: Sendable {
        public var tileWidth: Int
        public var tileHeight: Int
        public var overlap: Int
        public var scale: Int
        public init(tileWidth: Int, tileHeight: Int, overlap: Int = 16, scale: Int = 1) {
            self.tileWidth = tileWidth; self.tileHeight = tileHeight; self.overlap = overlap; self.scale = scale
        }
    }

    private let graph: MetalRenderGraph
    private let runtime: any ModelRuntimeProtocol
    public let model: ModelID
    public let tiling: Tiling

    public init(graph: MetalRenderGraph, runtime: any ModelRuntimeProtocol, model: ModelID, tiling: Tiling) {
        self.graph = graph
        self.runtime = runtime
        self.model = model
        self.tiling = tiling
    }

    public func enhance(_ input: RenderFrameInput, plan: RenderPlan, frameID: FrameID,
                        deadline: HostTime) async throws -> RGBFrameBuffer {
        let aperture = input.aspect.cleanAperture
        let width = Int(aperture.width), height = Int(aperture.height)
        guard let rgbIn = graph.makeRGBBuffer(width: width, height: height) else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "AI 段の入力 buffer を確保できません")
        }
        // 1. GPU で RGB へ（完了を待つ。再生の他の部分は待たせない — この関数は presenter の Task 内で走る）。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try graph.renderToRGB(input, plan: plan, into: rgbIn) { result, _ in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        // 2. タイル分割推論。寸法がタイルより小さい等で計画が作れなければ shapeMismatch（より小さい variant へ — 08 §5）。
        guard let tilePlan = TilePlan(imageWidth: width, imageHeight: height, tileWidth: tiling.tileWidth,
                                      tileHeight: tiling.tileHeight, overlap: tiling.overlap, scale: tiling.scale) else {
            throw PlaybackError.model(.shapeMismatch, message: "この寸法はモデルのタイルで覆えません（\(width)x\(height)）")
        }
        let request = InferenceRequest(model: model, width: tiling.tileWidth, height: tiling.tileHeight,
                                       frameID: frameID, deadline: deadline)
        let enhanced = try await TiledInference.run(frame: InferenceFrame(rgbIn.pixelBuffer), plan: tilePlan,
                                                    request: request, runtime: runtime)
        // 3. 結果を texture として取り込む。
        guard let rgbOut = graph.importRGB(enhanced.pixelBuffer) else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "AI 段の出力を取り込めません")
        }
        return rgbOut
    }
}
