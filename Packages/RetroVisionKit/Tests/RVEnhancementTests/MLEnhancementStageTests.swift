import CoreVideo
import Metal
import RVMediaCore
import RVMLRuntime
import RVVideoPipeline
import XCTest
@testable import RVEnhancement

/// Metal の描画 → Core ML（実際の tiny model）→ Metal の提示、を通しで検査する。
/// 反転モデルなので、AI 段を通した出力は通常の出力の 255 − x になるはず。
final class MLEnhancementStageTests: XCTestCase {
    private var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RVMLRuntimeTests/Models")
    }
    private let modelID = ModelID("test.tiny.invert@1")

    private func makeNV12(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &pb),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height { for x in 0..<width { y[row * yStride + x] = UInt8(40 + (x * 2 + row) % 150) } }
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) { for x in 0..<(width / 2) {
            uv[row * uvStride + x * 2] = UInt8(90 + (x * 3) % 70)
            uv[row * uvStride + x * 2 + 1] = UInt8(150 - (row * 3) % 70)
        } }
        return buffer
    }

    private func makeTarget(_ device: any MTLDevice, size: Int) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func bytes(_ t: any MTLTexture) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: t.width * 4 * t.height)
        t.getBytes(&data, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return data
    }

    func testMetalToCoreMLToMetalRoundTripInvertsEveryPixel() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal device が無い")
        let context = try MetalRenderContext(device: device)
        let graph = try MetalRenderGraph(context: context)
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)

        let size = 64                        // 32x32 のタイルで割り切れ、overlap の継ぎ目が出る寸法
        let aspect = AspectResolution(targetDAR: AspectRatio(w: Int32(size), h: Int32(size)),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: Int32(size), height: Int32(size)),
                                      source: .sampleAspectOnly)
        let input = RenderFrameInput(pixelBuffer: try makeNV12(width: size, height: size), color: .unspecified,
                                     interlace: .progressive, aspect: aspect, frameID: FrameID(1))
        let plan = RenderPlan(id: PlanID(1), tier: .lightML,
                              stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: Int32(size), height: Int32(size)),
                                                     aspect: aspect, present: .offscreen))

        // A: AI 段を通さない通常の描画（基準）。
        let plain = try makeTarget(device, size: size)
        _ = try graph.render(input, plan: plan, to: plain)
        let drain = try XCTUnwrap(context.commandQueue.makeCommandBuffer()); drain.commit(); await drain.completed()

        // B: Metal の描画 → Core ML（タイル分割）→ Metal の提示。
        let stage = MLEnhancementStage(graph: graph, runtime: runtime, model: modelID,
                                       tiling: .init(tileWidth: 32, tileHeight: 32, overlap: 8))
        let enhanced = try await stage.enhance(input, plan: plan, frameID: FrameID(1),
                                               deadline: HostTime.now().advancing(ms: 10_000))
        XCTAssertEqual(enhanced.width, size)
        XCTAssertEqual(enhanced.height, size)
        let ai = try makeTarget(device, size: size)
        try graph.presentRGB(enhanced, aspect: aspect, to: ai)
        let drain2 = try XCTUnwrap(context.commandQueue.makeCommandBuffer()); drain2.commit(); await drain2.completed()

        let a = bytes(plain), b = bytes(ai)
        var maxError = 0, checked = 0
        for pixel in 0..<(size * size) {
            for c in 0..<3 {        // B, G, R
                let expected = 255 - Int(a[pixel * 4 + c])
                maxError = max(maxError, abs(Int(b[pixel * 4 + c]) - expected))
                checked += 1
            }
        }
        XCTAssertEqual(checked, size * size * 3)
        // 通常の描画の 255 − x（継ぎ目を含む全画素）。BGRA 往復の丸めと float16 を見込んで ±4。
        XCTAssertLessThanOrEqual(maxError, 4, "Metal → Core ML → Metal の結果が反転と違う（最大誤差 \(maxError)）")
    }

    func testStageReportsATypedErrorWhenTheModelIsNotLoaded() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let graph = try MetalRenderGraph(context: try MetalRenderContext(device: device))
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let aspect = AspectResolution(targetDAR: AspectRatio(w: 64, h: 64),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: 64, height: 64), source: .sampleAspectOnly)
        let input = RenderFrameInput(pixelBuffer: try makeNV12(width: 64, height: 64), color: .unspecified,
                                     interlace: .progressive, aspect: aspect, frameID: FrameID(1))
        let plan = RenderPlan(id: PlanID(1), tier: .lightML,
                              stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: 64, height: 64), aspect: aspect,
                                                     present: .offscreen))
        let stage = MLEnhancementStage(graph: graph, runtime: runtime, model: modelID,
                                       tiling: .init(tileWidth: 32, tileHeight: 32, overlap: 8))
        do {
            _ = try await stage.enhance(input, plan: plan, frameID: FrameID(1), deadline: HostTime.now().advancing(ms: 10_000))
            XCTFail("load していないモデルは失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .model(.notCompiled), "型付きのエラーで返る（再生側はその frame を非強調で出す）")
        }
    }

    func testFrameSmallerThanTheTileIsRejectedAsShapeMismatch() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let graph = try MetalRenderGraph(context: try MetalRenderContext(device: device))
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(modelID)
        let aspect = AspectResolution(targetDAR: AspectRatio(w: 16, h: 16),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: 16, height: 16), source: .sampleAspectOnly)
        let input = RenderFrameInput(pixelBuffer: try makeNV12(width: 16, height: 16), color: .unspecified,
                                     interlace: .progressive, aspect: aspect, frameID: FrameID(1))
        let plan = RenderPlan(id: PlanID(1), tier: .lightML,
                              stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: 16, height: 16), aspect: aspect,
                                                     present: .offscreen))
        let stage = MLEnhancementStage(graph: graph, runtime: runtime, model: modelID,
                                       tiling: .init(tileWidth: 32, tileHeight: 32, overlap: 8))
        do {
            _ = try await stage.enhance(input, plan: plan, frameID: FrameID(1), deadline: HostTime.now().advancing(ms: 10_000))
            XCTFail("タイルより小さい frame は失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .model(.shapeMismatch))
        }
    }
}
