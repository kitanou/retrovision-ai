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

// MARK: - 16 bit テンソル経路（設計 11 §5.3・§5.4・P2）

extension MLEnhancementStageTests {
    /// Metal → fp16 NCHW → Core ML（tiny: 1 − x を最近傍 2 倍）→ fp16 → 最終拡大。
    /// SR 出力（48x32）を同寸法へ描くので、出力 (X, Y) は通常の描画（24x16）の (X/2, Y/2) の 255 − x になる。
    func testTensorPathRoundTripThroughCoreMLAtTwiceTheSize() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal device が無い")
        let context = try MetalRenderContext(device: device)
        let graph = try MetalRenderGraph(context: context)
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let srID = ModelID("test.tiny.sr2x.f16@1")
        try await runtime.load(srID)

        let w = 24, h = 16
        let aspect = AspectResolution(targetDAR: AspectRatio(w: 3, h: 2),
                                      cleanAperture: PixelRect(x: 0, y: 0, width: Int32(w), height: Int32(h)),
                                      source: .sampleAspectOnly)
        let input = RenderFrameInput(pixelBuffer: try makeNV12(width: w, height: h), color: .unspecified,
                                     interlace: .progressive, aspect: aspect, frameID: FrameID(1))
        let plan = RenderPlan(id: PlanID(2), tier: .lightML,
                              stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                     aspect: aspect, present: .offscreen))
        func target(_ tw: Int, _ th: Int) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: tw, height: th, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let plain = try target(w, h)
        _ = try graph.render(input, plan: plan, to: plain)

        let stage = MLEnhancementStage(graph: graph, runtime: runtime, model: srID,
                                       tiling: .init(tileWidth: w, tileHeight: h, overlap: 0, scale: 2, io: .tensor))
        guard case .tensor(let out) = try await stage.enhanceFrame(input, plan: plan, frameID: FrameID(1),
                                                                    deadline: HostTime.now().advancing(ms: 10_000)) else {
            return XCTFail("テンソル経路にならなかった")
        }
        XCTAssertEqual(out.width, w * 2); XCTAssertEqual(out.height, h * 2)
        let ai = try target(w * 2, h * 2)
        try graph.presentTensor(out, aspect: aspect, to: ai)
        let drain = try XCTUnwrap(context.commandQueue.makeCommandBuffer()); drain.commit(); await drain.completed()

        let a = bytes(plain), b = bytes(ai)
        var maxError = 0
        for y in 0..<(h * 2) { for x in 0..<(w * 2) { for c in 0..<3 {
            let expected = 255 - Int(a[((y / 2) * w + x / 2) * 4 + c])
            maxError = max(maxError, abs(Int(b[(y * w * 2 + x) * 4 + c]) - expected))
        } } }
        // fp16 の往復・8 bit の丸め・ディザ（±0.5 LSB）を見込んで ±3。
        XCTAssertLessThanOrEqual(maxError, 3, "テンソル経路の結果が 1 − x の 2 倍と違う（最大誤差 \(maxError)）")
    }

    func testTensorPathRejectsAnApertureThatDoesNotMatchTheModel() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let graph = try MetalRenderGraph(context: try MetalRenderContext(device: device))
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let aspect = AspectResolution(targetDAR: AspectRatio(w: 1, h: 1), cleanAperture: PixelRect(x: 0, y: 0, width: 32, height: 32),
                                      source: .sampleAspectOnly)
        let input = RenderFrameInput(pixelBuffer: try makeNV12(width: 32, height: 32), color: .unspecified,
                                     interlace: .progressive, aspect: aspect, frameID: FrameID(1))
        let plan = RenderPlan(id: PlanID(3), tier: .lightML,
                              stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: 32, height: 32), aspect: aspect, present: .offscreen))
        let stage = MLEnhancementStage(graph: graph, runtime: runtime, model: ModelID("test.tiny.sr2x.f16@1"),
                                       tiling: .init(tileWidth: 24, tileHeight: 16, overlap: 0, scale: 2, io: .tensor))
        do {
            _ = try await stage.enhanceFrame(input, plan: plan, frameID: FrameID(1), deadline: HostTime.now().advancing(ms: 1_000))
            XCTFail("寸法違いが通った")
        } catch let error as PlaybackError {
            guard case .model(.shapeMismatch) = error.kind else { return XCTFail("\(error.kind)") }
        }
    }
}
