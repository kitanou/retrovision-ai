import Metal
import RVMediaCore
import XCTest
@testable import RVVideoPipeline

/// オーバーレイ（字幕・メニューのハイライト）の Metal 描画: premultiplied alpha の重ね合わせの計算と、
/// 映像と同じ geometry（取り込み域・目標比率の枠）に載ること。
final class OverlayTests: XCTestCase {
    nonisolated(unsafe) static var context: MetalRenderContext!
    nonisolated(unsafe) static var graph: MetalRenderGraph!

    override class func setUp() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        context = try! MetalRenderContext(device: device)
        graph = try! MetalRenderGraph(context: context)
    }

    private func makeTarget(width: Int, height: Int, base: (b: Double, g: Double, r: Double)) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = try XCTUnwrap(Self.context.device.makeTexture(descriptor: d))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: base.r, green: base.g, blue: base.b, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let cb = try XCTUnwrap(Self.context.commandQueue.makeCommandBuffer())
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cb.commit()
        return t
    }

    private func drain() async {
        let cb = Self.context.commandQueue.makeCommandBuffer()!; cb.commit(); await cb.completed()
    }

    private func pixel(_ t: any MTLTexture, _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        t.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    private func aspect(dar: (Int32, Int32), aperture: (x: Int32, y: Int32, w: Int32, h: Int32)) -> AspectResolution {
        AspectResolution(targetDAR: AspectRatio(w: dar.0, h: dar.1),
                         cleanAperture: PixelRect(x: aperture.x, y: aperture.y, width: aperture.w, height: aperture.h),
                         source: .sampleAspectOnly)
    }

    /// width × height の画。`fill(x, y)` が (b, g, r, a) の premultiplied を返す。
    private func overlay(_ w: Int, _ h: Int, _ fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> OverlayImage {
        var bgra: [UInt8] = []
        for y in 0..<h { for x in 0..<w { let p = fill(x, y); bgra += [p.0, p.1, p.2, p.3] } }
        return OverlayImage(width: w, height: h, bgra: bgra)
    }

    func testPremultipliedBlendReplacesOpaqueKeepsTransparentAndMixesHalfAlpha() async throws {
        let target = try makeTarget(width: 8, height: 8, base: (b: 1.0, g: 0, r: 0))          // 青
        let img = overlay(8, 8) { x, _ in
            switch x {
            case 0...1: return (255, 255, 255, 255)          // 不透明の白
            case 2...3: return (0, 0, 128, 128)              // premultiplied の半透明の赤（α ≈ 0.5）
            default: return (0, 0, 0, 0)                      // 透明
            }
        }
        let texture = try XCTUnwrap(Self.graph.makeOverlayTexture(img))
        try Self.graph.drawOverlay(texture, aspect: aspect(dar: (1, 1), aperture: (0, 0, 8, 8)), onto: target)
        await drain()

        let opaque = pixel(target, 0, 4), half = pixel(target, 2, 4), none = pixel(target, 6, 4)
        XCTAssertEqual([opaque.b, opaque.g, opaque.r], [255, 255, 255], "不透明は下の画を置き換える")
        XCTAssertEqual([none.b, none.g, none.r], [255, 0, 0], "透明は下の青をそのまま残す")
        XCTAssertEqual(half.r, 128, accuracy: 2, "半透明の赤: src.r（128）+ dst.r（0）× (1 − α)")
        XCTAssertEqual(half.b, 127, accuracy: 3, "半透明の赤の下の青: 255 × (1 − 128/255) ≈ 127")
    }

    func testOverlayLandsOnTheSameGeometryAsTheVideo() async throws {
        // 16x16 の画の (4..7, 6..9) のブロックだけ白。32x32 の枠（比率 1:1、取り込み域は全面）に出ると (8..15, 12..19) に載る。
        // 線形補間で縁は滲むので、ブロックの中心と、十分に離れた点で見る。
        let target = try makeTarget(width: 32, height: 32, base: (0, 0, 0))
        let img = overlay(16, 16) { x, y in (4...7).contains(x) && (6...9).contains(y) ? (255, 255, 255, 255) : (0, 0, 0, 0) }
        try Self.graph.drawOverlay(try XCTUnwrap(Self.graph.makeOverlayTexture(img)),
                                   aspect: aspect(dar: (1, 1), aperture: (0, 0, 16, 16)), onto: target)
        await drain()
        XCTAssertEqual(pixel(target, 11, 15).r, 255, "ブロックの中心に載らない")
        XCTAssertEqual(pixel(target, 12, 16).r, 255)
        for (x, y) in [(2, 15), (22, 15), (11, 3), (11, 27)] { XCTAssertEqual(pixel(target, x, y).r, 0, "(\(x),\(y)) が汚れている") }
    }

    func testCleanApertureCropsTheOverlayExactlyLikeTheVideo() async throws {
        // 取り込み域が左半分（x 0..7、8x16 = 比率 1:2）。32x32 の枠に DAR 1:2 を収めると幅 16 の中央寄せ（dest x = 8..23）。
        // 画の (4..5) のブロックは取り込み域の 0.5〜0.75 → 枠の x = 8 + 0.5×16 … 8 + 0.75×16 = 16..19 に載る。
        // 右半分（x 12..13）の印は切り出しの外なので出ない。
        let target = try makeTarget(width: 32, height: 32, base: (0, 0, 0))
        let img = overlay(16, 16) { x, y in ((4...5).contains(x) || (12...13).contains(x)) && (6...9).contains(y) ? (255, 255, 255, 255) : (0, 0, 0, 0) }
        try Self.graph.drawOverlay(try XCTUnwrap(Self.graph.makeOverlayTexture(img)),
                                   aspect: aspect(dar: (1, 2), aperture: (0, 0, 8, 16)), onto: target)
        await drain()
        XCTAssertGreaterThan(pixel(target, 17, 16).r, 200, "切り出し後の位置に載らない")
        XCTAssertEqual(pixel(target, 26, 16).r, 0, "切り出しの外（右半分の印）が出ている")
        XCTAssertEqual(pixel(target, 4, 16).r, 0, "letterbox の余白に描いている")
        XCTAssertEqual(pixel(target, 12, 16).r, 0, "ブロックの手前（枠の中で、印の左）が汚れている")
    }

    func testLetterboxLeavesTheBarsUntouched() async throws {
        // 全面が不透明の白のオーバーレイでも、目標比率 2:1 の枠（16x16 では高さ 8、上下に 4 px の余白）の外は映像（青）のまま。
        let target = try makeTarget(width: 16, height: 16, base: (b: 1.0, g: 0, r: 0))
        let img = overlay(8, 4) { _, _ in (255, 255, 255, 255) }
        try Self.graph.drawOverlay(try XCTUnwrap(Self.graph.makeOverlayTexture(img)),
                                   aspect: aspect(dar: (2, 1), aperture: (0, 0, 8, 4)), onto: target)
        await drain()
        XCTAssertEqual(pixel(target, 8, 8).r, 255, "枠の中は白")
        XCTAssertEqual(pixel(target, 8, 1).r, 0, "上の余白は青のまま")
        XCTAssertEqual(pixel(target, 8, 14).r, 0, "下の余白は青のまま")
        XCTAssertEqual(pixel(target, 8, 1).b, 255)
    }

    func testTransparentFactoryAndTextureCreation() throws {
        let t = OverlayImage.transparent(width: 4, height: 3)
        XCTAssertEqual(t.bgra.count, 4 * 3 * 4)
        XCTAssertTrue(t.bgra.allSatisfy { $0 == 0 })
        let texture = try XCTUnwrap(Self.graph.makeOverlayTexture(t))
        XCTAssertEqual(texture.width, 4); XCTAssertEqual(texture.height, 3)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
    }
}
