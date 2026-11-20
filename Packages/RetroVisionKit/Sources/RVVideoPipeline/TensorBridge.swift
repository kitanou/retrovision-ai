import CoreVideo
import Foundation
import Metal
import RVMediaCore

// MARK: - Metal ↔ Core ML の 16 bit テンソル橋渡し（設計 11 §5.3・§5.4、D3）
//
// SR の入出力は NCHW の planar・16 bit 浮動小数（`kCVPixelFormatType_OneComponent16Half`、IOSurface 付き）。
// 幅 = W、高さ = 3 × H（R・G・B の面を縦に積む）。Core ML 側は `MLMultiArray(pixelBuffer:shape:)` でコピー無しに
// 包み（RVMLRuntime の `TensorFrame`）、Metal 側は同じ buffer を r16Float の texture として読み書きする。
//   入力: NV12 → deinterlace + 色変換（RGBA16F の中間、取り込み域の寸法）→ `rv_pack_nchw_f16_v1` で planar へ
//   出力: planar → `rv_unpack_nchw_f16_v1` で RGBA16F の中間 → 最終拡大（`presentSource`）
// 値は 0..1 の RGB（gamma は線形化しない — 05 §3）。RVVideoPipeline は RVMLRuntime に依存しないので、
// ここでは CVPixelBuffer のまま扱う。

public final class TensorTexture: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let texture: any MTLTexture
    public let channels: Int
    private let cvTexture: CVMetalTexture
    public var width: Int { texture.width }
    public var height: Int { texture.height / max(channels, 1) }

    init(pixelBuffer: CVPixelBuffer, texture: any MTLTexture, cvTexture: CVMetalTexture, channels: Int) {
        self.pixelBuffer = pixelBuffer; self.texture = texture; self.cvTexture = cvTexture; self.channels = channels
    }
}

extension MetalRenderGraph {
    /// fp16 planar の buffer を texture（r16Float、幅 W × 高さ C·H）として取り込む。
    public func importTensor(_ pixelBuffer: CVPixelBuffer, channels: Int = 3) -> TensorTexture? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent16Half,
              CVPixelBufferGetHeight(pixelBuffer) % channels == 0,
              let cache = importer.textureCache else { return nil }
        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let attrs: [String: Any] = [kCVMetalTextureUsage as String: usage.rawValue]
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, attrs as CFDictionary, .r16Float,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cv)
        guard status == kCVReturnSuccess, let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return TensorTexture(pixelBuffer: pixelBuffer, texture: texture, cvTexture: cv, channels: channels)
    }

    /// 入力（NV12）を deinterlace + 色変換して、取り込み域の寸法の fp16 planar テンソルへ書く（SR の入力）。
    /// テンソルの寸法（W×H）は取り込み域と一致していること（設計 11 D2: 元格子のまま SR）。
    public func renderToTensor(_ input: RenderFrameInput, plan: RenderPlan, into tensor: TensorTexture,
                               completed: ((Result<Void, PlaybackError>) -> Void)? = nil) throws {
        let w = tensor.width, h = tensor.height
        guard let rgb = pool.acquire(width: w, height: h, format: .rgba16Float,
                                     usage: [.renderTarget, .shaderRead, .shaderWrite]) else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "AI 段の中間 texture を確保できません")
        }
        var fill = input
        fill.aspect = AspectResolution(targetDAR: AspectRatio(w: Int32(w), h: Int32(h)),
                                       cleanAperture: input.aspect.cleanAperture, source: input.aspect.source)
        do {
            try render(fill, plan: plan, to: rgb)   // 同じ queue: 下の pack はこの後に実行される
        } catch {
            pool.release(rgb)
            throw error
        }
        guard let command = context.commandQueue.makeCommandBuffer(),
              let enc = command.makeComputeCommandEncoder() else {
            pool.release(rgb)
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier),
                                userMessage: "command buffer を作成できません")
        }
        let pso = try context.computePipeline(function: "rv_pack_nchw_f16_v1", label: "pack_nchw_f16")
        enc.setComputePipelineState(pso)
        enc.setTexture(rgb, index: 0)
        enc.setTexture(tensor.texture, index: 1)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        command.addCompletedHandler { [pool] cb in
            pool.release(rgb)
            _ = tensor
            if let error = cb.error {
                completed?(.failure(PlaybackError(kind: .render(.drawableLost), causeDescription: String(describing: error),
                                                  recovery: .retryWith(.lowerTier), userMessage: "GPU 処理が完了しませんでした")))
            } else {
                completed?(.success(()))
            }
        }
        command.commit()
    }

    /// fp16 planar テンソル（SR の出力）を、目標比率で letterbox して target へ描く（最終拡大。設計 11 §5.6）。
    public func presentTensor(_ tensor: TensorTexture, aspect: AspectResolution, to target: any MTLTexture,
                              completed: ((Result<Void, PlaybackError>) -> Void)? = nil) throws {
        let w = tensor.width, h = tensor.height
        try presentSource(width: w, height: h, aspect: aspect, to: target, keepAlive: tensor,
                          completed: completed) { [pool, context] command in
            guard let rgb = pool.acquire(width: w, height: h, format: .rgba16Float, usage: [.shaderRead, .shaderWrite]),
                  let enc = command.makeComputeCommandEncoder() else {
                throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                    userMessage: "AI 段の出力の中間 texture を確保できません")
            }
            let pso = try context.computePipeline(function: "rv_unpack_nchw_f16_v1", label: "unpack_nchw_f16")
            enc.setComputePipelineState(pso)
            enc.setTexture(tensor.texture, index: 0)
            enc.setTexture(rgb, index: 1)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            enc.endEncoding()
            return (rgb, [rgb])
        }
    }

    // MARK: タイル（設計 11 §5.4、D4 の予備。切り出しと合成を GPU で）

    /// タイル 1 枚の置き場所（出力 px）と、隣のタイルの有無（重なり側だけ重みを下げる）。
    public struct TensorTilePlacement: Sendable {
        public var outputX: Int, outputY: Int
        public var hasLeft: Bool, hasRight: Bool, hasTop: Bool, hasBottom: Bool
        public init(outputX: Int, outputY: Int, hasLeft: Bool, hasRight: Bool, hasTop: Bool, hasBottom: Bool) {
            self.outputX = outputX; self.outputY = outputY
            self.hasLeft = hasLeft; self.hasRight = hasRight; self.hasTop = hasTop; self.hasBottom = hasBottom
        }
    }

    /// 全画面のテンソルから、各タイル（`tiles[i]` の寸法）を `origins[i]`（入力 px）で切り出す。
    public func cropTensorTiles(_ source: TensorTexture, origins: [(x: Int, y: Int)], into tiles: [TensorTexture],
                                completed: @escaping (Result<Void, PlaybackError>) -> Void) throws {
        precondition(origins.count == tiles.count)
        guard let command = context.commandQueue.makeCommandBuffer(),
              let enc = command.makeComputeCommandEncoder() else {
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier),
                                userMessage: "command buffer を作成できません")
        }
        let pso = try context.computePipeline(function: "rv_tensor_crop_v1", label: "tensor_crop")
        enc.setComputePipelineState(pso)
        var srcSize = SIMD2<UInt32>(UInt32(source.width), UInt32(source.height))
        for (origin, tile) in zip(origins, tiles) {
            var o = SIMD2<UInt32>(UInt32(origin.x), UInt32(origin.y))
            enc.setTexture(source.texture, index: 0)
            enc.setTexture(tile.texture, index: 1)
            enc.setBytes(&o, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            enc.setBytes(&srcSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: tile.width, height: tile.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        enc.endEncoding()
        command.addCompletedHandler { cb in
            _ = source; _ = tiles
            completed(cb.error.map { .failure(PlaybackError(kind: .render(.drawableLost), causeDescription: String(describing: $0),
                                                            recovery: .retryWith(.lowerTier), userMessage: "GPU 処理が完了しませんでした")) }
                      ?? .success(()))
        }
        command.commit()
    }

    /// タイルの出力を重みつきで合成して `output`（全体の出力寸法のテンソル）へ書く。`rampPixels` は重なり幅（出力 px）。
    public func composeTensorTiles(_ tiles: [TensorTexture], placements: [TensorTilePlacement], rampPixels: Int,
                                   into output: TensorTexture,
                                   completed: @escaping (Result<Void, PlaybackError>) -> Void) throws {
        precondition(tiles.count == placements.count)
        let w = output.width, h = output.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let acc = context.device.makeTexture(descriptor: desc),
              let command = context.commandQueue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            throw PlaybackError(kind: .render(.memoryLimit), recovery: .retryWith(.lowerTier),
                                userMessage: "タイル合成の texture を確保できません")
        }
        // 累積 texture を 0 で初期化する（private storage は内容不定）。
        let zeros = context.device.makeBuffer(length: w * h * 16, options: .storageModePrivate)!
        blit.fill(buffer: zeros, range: 0..<zeros.length, value: 0)
        blit.copy(from: zeros, sourceOffset: 0, sourceBytesPerRow: w * 16, sourceBytesPerImage: w * h * 16,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: acc, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        guard let enc = command.makeComputeCommandEncoder() else {
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier), userMessage: "encoder を作れません")
        }
        let accumulate = try context.computePipeline(function: "rv_tensor_tile_accumulate_v1", label: "tensor_tile_accumulate")
        let resolve = try context.computePipeline(function: "rv_tensor_tile_resolve_v1", label: "tensor_tile_resolve")
        enc.setComputePipelineState(accumulate)
        for (tile, place) in zip(tiles, placements) {
            var params = TensorTileParams(
                origin: SIMD2(UInt32(place.outputX), UInt32(place.outputY)),
                size: SIMD2(UInt32(tile.width), UInt32(tile.height)),
                neighbours: SIMD4(place.hasLeft ? 1 : 0, place.hasRight ? 1 : 0, place.hasTop ? 1 : 0, place.hasBottom ? 1 : 0),
                ramp: UInt32(max(rampPixels, 1)), pad0: 0, pad1: 0, pad2: 0)
            enc.setTexture(tile.texture, index: 0)
            enc.setTexture(acc, index: 1)
            enc.setBytes(&params, length: MemoryLayout<TensorTileParams>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: tile.width, height: tile.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            enc.memoryBarrier(resources: [acc])   // 重なり部分の読み書きを前のタイルの後にする
        }
        enc.setComputePipelineState(resolve)
        enc.setTexture(acc, index: 0)
        enc.setTexture(output.texture, index: 1)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        command.addCompletedHandler { cb in
            _ = tiles; _ = output; _ = acc; _ = zeros
            completed(cb.error.map { .failure(PlaybackError(kind: .render(.drawableLost), causeDescription: String(describing: $0),
                                                            recovery: .retryWith(.lowerTier), userMessage: "GPU 処理が完了しませんでした")) }
                      ?? .success(()))
        }
        command.commit()
    }
}

/// `rv_tensor_tile_accumulate_v1` の引数（Shaders.swift の `TensorTileParams` と同じ並び）。
struct TensorTileParams {
    var origin: SIMD2<UInt32>
    var size: SIMD2<UInt32>
    var neighbours: SIMD4<UInt32>
    var ramp: UInt32
    var pad0: UInt32, pad1: UInt32, pad2: UInt32
}

