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
}
