import CoreVideo
import Metal
import XCTest

@testable import RVVideoPipeline
import RVMediaCore

/// AI 段の後の最終拡大（`presentRGB` / `rv_rgbPresent_v2`。設計 11 §5.6）:
/// 等倍は画素どおり、拡大は Catmull-Rom、縮小は tent 核で縞を抑える。
final class RGBPresentTests: XCTestCase {
    nonisolated(unsafe) static var graph: MetalRenderGraph?

    override class func setUp() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        graph = try? MetalRenderGraph(context: try MetalRenderContext(device: device))
    }

    private func requireGraph() throws -> MetalRenderGraph {
        guard let g = Self.graph else { XCTFail("Metal device が無い"); throw XCTSkip() }
        return g
    }

    /// 灰色の値 v(x, y) で埋めた RGB buffer。
    private func makeRGB(_ g: MetalRenderGraph, width: Int, height: Int, value: (Int, Int) -> UInt8) throws -> RGBFrameBuffer {
        let rgb = try XCTUnwrap(g.makeRGBBuffer(width: width, height: height))
        let pb = rgb.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y), o = y * stride + x * 4
                base[o] = v; base[o + 1] = v; base[o + 2] = v; base[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return rgb
    }

    /// target（bgra8）へ描き、赤成分を [y][x] で返す。
    private func present(_ g: MetalRenderGraph, _ rgb: RGBFrameBuffer, dar: AspectRatio,
                         width: Int, height: Int) throws -> [[Int]] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try XCTUnwrap(g.context.device.makeTexture(descriptor: d))
        let aspect = AspectResolution(targetDAR: dar,
                                      cleanAperture: PixelRect(x: 0, y: 0, width: Int32(rgb.width), height: Int32(rgb.height)),
                                      source: .userOverride)
        let done = expectation(description: "present")
        try g.presentRGB(rgb, aspect: aspect, to: target) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (0..<height).map { y in (0..<width).map { x in Int(bytes[(y * width + x) * 4 + 2]) } }
    }

    func testSameSizeReproducesPixels() throws {
        let g = try requireGraph()
        let rgb = try makeRGB(g, width: 32, height: 24) { x, y in UInt8((x * 7 + y * 13) % 256) }
        let out = try present(g, rgb, dar: AspectRatio(w: 4, h: 3), width: 32, height: 24)
        for y in 0..<24 { for x in 0..<32 {
            XCTAssertLessThanOrEqual(abs(out[y][x] - (x * 7 + y * 13) % 256), 1, "(\(x),\(y))")
        } }
    }

    /// 拡大は Catmull-Rom: 黒白の段差を 4 倍にしたとき、bilinear（32 / 223）より急に立ち上がる。
    func testUpscaleIsSharperThanBilinear() throws {
        let g = try requireGraph()
        let rgb = try makeRGB(g, width: 32, height: 24) { x, _ in x < 16 ? 0 : 255 }
        let out = try present(g, rgb, dar: AspectRatio(w: 4, h: 3), width: 128, height: 96)
        let row = out[48]
        XCTAssertLessThan(row[62], 28, "入力位置 15.125: Catmull-Rom ≈ 21、bilinear なら 32")
        XCTAssertGreaterThan(row[65], 227, "入力位置 15.875: Catmull-Rom ≈ 234、bilinear なら 223")
        XCTAssertEqual(row[0], 0); XCTAssertEqual(row[127], 255)
    }

    /// 縮小は tent 核（半径 = 倍率の逆数）: 1 画素おきの横縞（ナイキスト）を縦 0.75 倍にしたとき、
    /// 1 回の bilinear sample（行によって 0 か 255 = 振れ 255）より振れが 1/3 未満に収まり、平均は中間の灰。
    /// tent 核はナイキスト付近を完全には消さない（実測の振れ 92〜163）。完全に消すには広い核が要る（ぼけと引き換え）。
    func testDownscaleSuppressesStripes() throws {
        let g = try requireGraph()
        let rgb = try makeRGB(g, width: 64, height: 64) { _, y in y % 2 == 0 ? 255 : 0 }
        let out = try present(g, rgb, dar: AspectRatio(w: 4, h: 3), width: 64, height: 48)
        let column = (4..<44).map { out[$0][32] }
        XCTAssertLessThan(column.max()! - column.min()!, 85, "縮小で縞が残っている: \(column)")
        let mean = Double(column.reduce(0, +)) / Double(column.count)
        XCTAssertEqual(mean, 127.5, accuracy: 10)
    }
}
