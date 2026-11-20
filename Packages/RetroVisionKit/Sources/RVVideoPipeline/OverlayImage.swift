import CoreVideo
import Foundation
import Metal
import RVMediaCore

// MARK: - オーバーレイ（字幕・DVD メニューのボタンのハイライト）
//
// 映像とは別に作られた画（premultiplied alpha の BGRA8）を、映像の上に重ねる。
// 座標系は「映像の coded frame」（DVD なら 720x480 / 720x576）。映像と同じ取り込み域・同じ枠で
// 描くので、クリーンアパーチャの切り出しや letterbox を経ても、ボタンが映像のボタンの絵に重なる。

public struct OverlayImage: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// BGRA8、premultiplied alpha。行優先で `width × height × 4` byte。
    public let bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        precondition(bgra.count == width * height * 4, "OverlayImage の byte 数が寸法と合わない")
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    /// 全面が透明の画。
    public static func transparent(width: Int, height: Int) -> OverlayImage {
        OverlayImage(width: width, height: height, bgra: [UInt8](repeating: 0, count: width * height * 4))
    }
}

extension MetalRenderGraph {
    /// オーバーレイの画を texture にする（CPU から書ける shared storage。選択の変更ごとに作り直す小さな画）。
    public func makeOverlayTexture(_ image: OverlayImage) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width,
                                                         height: image.height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: d) else { return nil }
        image.bgra.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    /// すでに描いた target（映像）の上に、オーバーレイを重ねる（loadAction = .load）。
    /// 映像と同じ geometry（取り込み域 = `aspect.cleanAperture`、枠 = `aspect.targetDAR`）で描く。
    public func drawOverlay(_ overlay: any MTLTexture, aspect: AspectResolution, onto target: any MTLTexture) throws {
        guard let command = context.commandQueue.makeCommandBuffer() else {
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier),
                                userMessage: "command buffer を作成できません")
        }
        let pso = try context.renderPipeline(vertex: "rv_vs_fullscreen", fragment: "rv_overlay_v1",
                                             colorFormat: target.pixelFormat, label: "overlay_v1",
                                             premultipliedBlend: true)
        let geo = Self.geometry(aspect: aspect, codedWidth: overlay.width, codedHeight: overlay.height,
                                targetWidth: target.width, targetHeight: target.height)
        var params = (source: SIMD4<Float>(geo.source.0, geo.source.1, geo.source.2, geo.source.3),
                      dest: SIMD4<Float>(geo.dest.0, geo.dest.1, geo.dest.2, geo.dest.3))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load          // 映像を残して上に重ねる
        pass.colorAttachments[0].storeAction = .store
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw PlaybackError(kind: .render(.deviceUnavailable), recovery: .retryWith(.lowerTier),
                                userMessage: "encoder を作れません")
        }
        enc.setRenderPipelineState(pso)
        enc.setFragmentBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
        enc.setFragmentTexture(overlay, index: 0)
        enc.setFragmentSamplerState(context.sampler(minFilterNearest: false), index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        command.commit()
    }
}
