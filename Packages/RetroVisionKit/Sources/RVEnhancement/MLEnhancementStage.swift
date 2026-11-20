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
        /// モデルの入出力の形（manifest の input.kind）。`.tensor` は 16 bit の NCHW（設計 11 §5.4・D3）。
        public var io: IO
        public enum IO: Sendable { case image, tensor }
        /// 全画面で 1 回に推論できる入力寸法（EnumeratedShapes。設計 11 D4）。tile の寸法は常に含む。
        public var fullFrameSizes: [PixelSize]
        public init(tileWidth: Int, tileHeight: Int, overlap: Int = 16, scale: Int = 1, io: IO = .image,
                    fullFrameSizes: [PixelSize] = []) {
            self.tileWidth = tileWidth; self.tileHeight = tileHeight; self.overlap = overlap; self.scale = scale
            self.io = io
            self.fullFrameSizes = fullFrameSizes
        }
        func acceptsFullFrame(width: Int, height: Int) -> Bool {
            (width == tileWidth && height == tileHeight)
                || fullFrameSizes.contains(PixelSize(width: Int32(width), height: Int32(height)))
        }
    }

    /// 強調の結果（最終拡大の入力）。
    public enum EnhancedFrame: @unchecked Sendable {
        case rgb(RGBFrameBuffer)
        case tensor(TensorTexture)
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

    /// モデルの入出力の形に応じて強調する（`.tensor` は 16 bit、`.image` は従来の BGRA8 + タイル）。
    public func enhanceFrame(_ input: RenderFrameInput, plan: RenderPlan, frameID: FrameID,
                             deadline: HostTime) async throws -> EnhancedFrame {
        switch tiling.io {
        case .tensor: return .tensor(try await enhanceTensor(input, plan: plan, frameID: frameID, deadline: deadline))
        case .image: return .rgb(try await enhance(input, plan: plan, frameID: frameID, deadline: deadline))
        }
    }

    /// 16 bit テンソル経路（設計 11 §5.3・§5.4）: NV12 → deinterlace + 色変換 → fp16 NCHW（取り込み域の寸法、
    /// 元格子のまま — D2）→ Core ML（IOSurface をコピー無しで共有）→ fp16 NCHW の出力を texture として返す。
    /// 取り込み域がモデルの受ける寸法（EnumeratedShapes）なら全画面で 1 回、そうでなければ GPU のタイル（D4 の予備）。
    public func enhanceTensor(_ input: RenderFrameInput, plan: RenderPlan, frameID: FrameID,
                              deadline: HostTime) async throws -> TensorTexture {
        let aperture = input.aspect.cleanAperture
        let width = Int(aperture.width), height = Int(aperture.height)
        let fullFrame = tiling.acceptsFullFrame(width: width, height: height)
        let tilePlan = fullFrame ? nil : TilePlan(imageWidth: width, imageHeight: height, tileWidth: tiling.tileWidth,
                                                  tileHeight: tiling.tileHeight, overlap: tiling.overlap, scale: tiling.scale)
        guard fullFrame || tilePlan != nil else {
            throw PlaybackError.model(.shapeMismatch,
                                      message: "取り込み域（\(width)x\(height)）をモデルのタイル（\(tiling.tileWidth)x\(tiling.tileHeight)）で覆えません")
        }
        guard let inFrame = TensorFrame.make(width: width, height: height),
              let inTexture = graph.importTensor(inFrame.pixelBuffer) else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "AI 段の入力 buffer を確保できません")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try graph.renderToTensor(input, plan: plan, into: inTexture) { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard let tilePlan else {
            let request = InferenceRequest(model: model, width: width, height: height, frameID: frameID, deadline: deadline)
            let output = try await runtime.predictTensor(request, input: inFrame)
            return try importOrThrow(output)
        }
        return try await enhanceTiles(inTexture, plan: tilePlan, frameID: frameID, deadline: deadline)
    }

    private func importOrThrow(_ frame: TensorFrame) throws -> TensorTexture {
        guard let texture = graph.importTensor(frame.pixelBuffer, channels: frame.channels) else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "AI 段の buffer を取り込めません")
        }
        return texture
    }

    private func makeTensor(width: Int, height: Int) throws -> (TensorFrame, TensorTexture) {
        guard let frame = TensorFrame.make(width: width, height: height) else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "AI 段の buffer を確保できません")
        }
        return (frame, try importOrThrow(frame))
    }

    /// GPU のタイル（設計 11 §5.4、D4 の予備）: 切り出し → タイルごとに推論 → 重みつき合成（すべて GPU / Core ML。
    /// CPU で画素を触らない）。どのタイルが失敗しても全体を失敗にする（部分的に強調した frame は出さない）。
    private func enhanceTiles(_ source: TensorTexture, plan: TilePlan, frameID: FrameID,
                              deadline: HostTime) async throws -> TensorTexture {
        let tiles = try plan.tiles.map { _ in try makeTensor(width: plan.tileWidth, height: plan.tileHeight) }
        try await gpu { done in
            try graph.cropTensorTiles(source, origins: plan.tiles.map { ($0.x, $0.y) }, into: tiles.map(\.1), completed: done)
        }
        var outputs: [TensorTexture] = []
        for (frame, _) in tiles {
            let request = InferenceRequest(model: model, width: plan.tileWidth, height: plan.tileHeight,
                                           frameID: frameID, deadline: deadline)
            outputs.append(try importOrThrow(try await runtime.predictTensor(request, input: frame)))
        }
        let placements = plan.tiles.indices.map { i -> MetalRenderGraph.TensorTilePlacement in
            let ix = i % plan.xs.count, iy = i / plan.xs.count
            return .init(outputX: plan.tiles[i].x * plan.scale, outputY: plan.tiles[i].y * plan.scale,
                         hasLeft: ix > 0, hasRight: ix < plan.xs.count - 1, hasTop: iy > 0, hasBottom: iy < plan.ys.count - 1)
        }
        let (_, out) = try makeTensor(width: plan.outputWidth, height: plan.outputHeight)
        try await gpu { done in
            try graph.composeTensorTiles(outputs, placements: placements, rampPixels: plan.overlap * plan.scale,
                                         into: out, completed: done)
        }
        return out
    }

    /// GPU の完了を待つ（完了 handler 形式を async に）。
    private func gpu(_ body: (@escaping (Result<Void, PlaybackError>) -> Void) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try body { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
