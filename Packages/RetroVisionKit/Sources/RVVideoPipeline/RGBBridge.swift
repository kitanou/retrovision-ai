import CoreVideo
import Foundation
import Metal
import RVMediaCore

// MARK: - Metal ↔ Core ML の橋渡し（06 §4 方針 A）
//
// BGRA8 の IOSurface 付き `CVPixelBuffer` と、その同じ領域を指す `MTLTexture`。Metal の描画先として
// 書き込み、同じ buffer を Core ML に image 入力として渡し、Core ML の出力 buffer を texture として
// 読み戻す（コピー無しで GPU と Core ML が同じ領域を見る）。

public final class RGBFrameBuffer: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let texture: any MTLTexture
    private let cvTexture: CVMetalTexture   // texture の背後の参照。buffer の生存中は保持する

    public var width: Int { texture.width }
    public var height: Int { texture.height }

    init(pixelBuffer: CVPixelBuffer, texture: any MTLTexture, cvTexture: CVMetalTexture) {
        self.pixelBuffer = pixelBuffer
        self.texture = texture
        self.cvTexture = cvTexture
    }
}

extension MetalRenderGraph {
    /// 描画先にも入力にもなる BGRA の buffer を確保する（Metal 互換・IOSurface 付き）。
    public func makeRGBBuffer(width: Int, height: Int) -> RGBFrameBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        return importRGB(pb)
    }

    /// 既存の BGRA buffer（Core ML の出力など）を texture として取り込む。
    public func importRGB(_ pixelBuffer: CVPixelBuffer) -> RGBFrameBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard let texture = importer.importBGRA(pixelBuffer) else { return nil }
        return RGBFrameBuffer(pixelBuffer: pixelBuffer, texture: texture.texture, cvTexture: texture.cvTexture)
    }

    /// 入力（NV12）を deinterlace + 色変換して、取り込み域の寸法の RGB buffer へ描く（拡縮も letterbox も無し）。
    /// AI 段の入力を作る。完了は `completed`（GPU 完了時）。
    @discardableResult
    public func renderToRGB(_ input: RenderFrameInput, plan: RenderPlan, into buffer: RGBFrameBuffer,
                            completed: ((Result<Void, PlaybackError>, RenderTiming) -> Void)? = nil) throws -> RenderTiming {
        var fill = input
        // 出力いっぱいに取り込み域を描く: 目標比率を出力寸法そのものにする（letterbox の余白が出ない）。
        fill.aspect = AspectResolution(
            targetDAR: AspectRatio(w: Int32(buffer.width), h: Int32(buffer.height)),
            cleanAperture: input.aspect.cleanAperture, source: input.aspect.source)
        return try render(fill, plan: plan, to: buffer.texture, completed: completed)
    }

    /// RGB texture を、目標比率で letterbox して target へ描く（AI 段の後の最終 scale / 提示）。
    @discardableResult
    public func presentRGB(_ rgb: RGBFrameBuffer, aspect: AspectResolution, to target: any MTLTexture,
                           completed: ((Result<Void, PlaybackError>) -> Void)? = nil) throws -> Void {
        try presentSource(width: rgb.width, height: rgb.height, aspect: aspect, to: target, keepAlive: rgb,
                          completed: completed) { _ in (rgb.texture, []) }
    }

    /// 最終拡大の共通部分（設計 11 §5.6）。`source` が同じ command buffer に前段（テンソルの展開など）を積み、
    /// 描く元の texture と、完了後に pool へ返す中間 texture を返す。
    func presentSource(width: Int, height: Int, aspect: AspectResolution, to target: any MTLTexture,
                       keepAlive: AnyObject, completed: ((Result<Void, PlaybackError>) -> Void)?,
                       source: (any MTLCommandBuffer) throws -> (texture: any MTLTexture, release: [any MTLTexture])) throws {
        guard let command = context.commandQueue.makeCommandBuffer() else {
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier),
                                userMessage: "command buffer を作成できません")
        }
        let (texture, release) = try source(command)
        let pso = try context.renderPipeline(vertex: "rv_vs_fullscreen", fragment: "rv_rgbPresent_v2",
                                             colorFormat: target.pixelFormat, label: "rgbPresent_v2")
        // letterbox の destRect（colorConvert と同じ geometry。source は全面）。
        let geo = Self.geometry(aspect: AspectResolution(targetDAR: aspect.targetDAR,
                                                         cleanAperture: PixelRect(x: 0, y: 0, width: Int32(width),
                                                                                  height: Int32(height)),
                                                         source: aspect.source),
                                codedWidth: width, codedHeight: height,
                                targetWidth: target.width, targetHeight: target.height)
        // 軸ごとの倍率（出力 1 画素あたりの入力画素数）。拡大は Catmull-Rom、縮小は tent 核（設計 11 §5.6）。
        let destW = max(Double(geo.dest.2) * Double(target.width), 1)
        let destH = max(Double(geo.dest.3) * Double(target.height), 1)
        var params = RGBPresentParams(
            destRect: SIMD4<Float>(geo.dest.0, geo.dest.1, geo.dest.2, geo.dest.3),
            invScale: SIMD2<Float>(Float(Double(width) / destW), Float(Double(height) / destH)),
            dither: target.pixelFormat == .bgra8Unorm || target.pixelFormat == .rgba8Unorm ? 1 : 0, pad: 0)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier),
                                userMessage: "encoder を作れません")
        }
        enc.setRenderPipelineState(pso)
        enc.setFragmentBytes(&params, length: MemoryLayout<RGBPresentParams>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        command.addCompletedHandler { [pool] cb in
            _ = keepAlive   // GPU が読み終えるまで元の buffer を生かす
            for t in release { pool.release(t) }
            if let error = cb.error {
                completed?(.failure(PlaybackError(kind: .render(.drawableLost), causeDescription: String(describing: error),
                                                  recovery: .retryWith(.lowerTier), userMessage: "GPU 処理が完了しませんでした")))
            } else {
                completed?(.success(()))
            }
        }
        command.commit()
    }
}

extension PixelBufferImporter {
    struct BGRATexture { var texture: any MTLTexture; var cvTexture: CVMetalTexture }

    /// BGRA8 の buffer を texture として取り込む（描画先にもなる: renderTarget + shaderRead + shaderWrite）。
    func importBGRA(_ pixelBuffer: CVPixelBuffer) -> BGRATexture? {
        guard let cache = textureCache else { return nil }
        let usage: MTLTextureUsage = [.renderTarget, .shaderRead, .shaderWrite]
        let attrs: [String: Any] = [kCVMetalTextureUsage as String: usage.rawValue]
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, attrs as CFDictionary, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cv)
        guard status == kCVReturnSuccess, let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return BGRATexture(texture: texture, cvTexture: cv)
    }
}

/// `rv_rgbPresent_v2` の引数（Shaders.swift の `RGBPresentParams` と同じ並び）。
struct RGBPresentParams {
    var destRect: SIMD4<Float>
    var invScale: SIMD2<Float>
    var dither: UInt32
    var pad: UInt32
}
