import CoreVideo
import RVMediaCore
import XCTest
@testable import RVMLRuntime

/// 06 §5: タイル分割 + 16 px オーバーラップ。計画（純粋）と、実際の Core ML 推論を通した端から端までの検査。
final class TilePlanTests: XCTestCase {
    func testPositionsCoverTheWholeAxisAndEndAtTheEdge() {
        for (length, tile, overlap) in [(64, 32, 8), (720, 256, 16), (480, 144, 16), (100, 32, 0), (33, 32, 16), (32, 32, 8)] {
            let xs = TilePlan.positions(length: length, tile: tile, overlap: overlap)
            XCTAssertEqual(xs.first, 0)
            XCTAssertEqual(xs.last, max(length - tile, 0), "最後のタイルは端に揃う (\(length),\(tile),\(overlap))")
            // 全画素がどれかのタイルに入る（隙間なし）。
            for p in 0..<length { XCTAssertTrue(xs.contains { p >= $0 && p < $0 + tile }, "画素 \(p) が覆われない") }
            // 隣り合うタイルは少なくとも overlap だけ重なる。
            for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(a + tile - b, min(overlap, tile - 1)) }
        }
    }

    func testInvalidPlansAreRejected() {
        XCTAssertNil(TilePlan(imageWidth: 16, imageHeight: 64, tileWidth: 32, tileHeight: 32), "frame がタイルより小さい")
        XCTAssertNil(TilePlan(imageWidth: 64, imageHeight: 64, tileWidth: 32, tileHeight: 32, overlap: 32), "重なりがタイル以上")
        XCTAssertNil(TilePlan(imageWidth: 64, imageHeight: 64, tileWidth: 32, tileHeight: 32, scale: 0))
    }

    func testWeightsNormalizeSoIdentityComposeRestoresTheInputExactly() throws {
        for scale in [1, 2] {
            let plan = try XCTUnwrap(TilePlan(imageWidth: 70, imageHeight: 50, tileWidth: 32, tileHeight: 24,
                                              overlap: 8, scale: scale))
            // 入力: 画素ごとに違う値の 1 channel。恒等（scale 1）/ 最近傍 2 倍（scale 2）のタイル出力を作る。
            func value(_ x: Int, _ y: Int) -> Float { Float((x * 7 + y * 13) % 251) }
            let outputs: [[Float]] = plan.tiles.map { tile in
                var out = [Float](repeating: 0, count: plan.outputTileWidth * plan.outputTileHeight)
                for v in 0..<plan.outputTileHeight { for u in 0..<plan.outputTileWidth {
                    out[v * plan.outputTileWidth + u] = value(tile.x + u / scale, tile.y + v / scale)
                } }
                return out
            }
            let composed = plan.compose(tileOutputs: outputs, channels: 1)
            var maxError: Float = 0
            for y in 0..<plan.outputHeight { for x in 0..<plan.outputWidth {
                maxError = max(maxError, abs(composed[y * plan.outputWidth + x] - value(x / scale, y / scale)))
            } }
            XCTAssertLessThan(maxError, 1e-3, "scale \(scale): 合成が入力を復元しない（重みの正規化が崩れている）")
        }
    }

    func testSeamIsFeatheredNotAStep() throws {
        // 2 枚のタイルが別の定数（0 と 100）を出すと、重なり帯の中で値が単調に 0→100 へ移る。
        let plan = try XCTUnwrap(TilePlan(imageWidth: 48, imageHeight: 32, tileWidth: 32, tileHeight: 32, overlap: 16))
        XCTAssertEqual(plan.tiles.count, 2)
        let outputs: [[Float]] = [[Float](repeating: 0, count: 32 * 32), [Float](repeating: 100, count: 32 * 32)]
        let row = plan.compose(tileOutputs: outputs, channels: 1)
        let line = (0..<48).map { row[$0] }
        XCTAssertEqual(line[0], 0); XCTAssertEqual(line[47], 100)
        for i in 1..<48 { XCTAssertGreaterThanOrEqual(line[i], line[i - 1] - 1e-4, "継ぎ目で値が逆戻りする") }
        let steps = (1..<48).map { line[$0] - line[$0 - 1] }
        XCTAssertLessThan(steps.max() ?? 0, 15, "継ぎ目が階段になっている（最大の差 \(steps.max() ?? 0)）")
    }
}

final class TiledInferenceTests: XCTestCase {
    private var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Models")
    }

    private func gradientBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let o = y * stride + x * 4
            base[o] = UInt8((x * 3) % 200)          // B
            base[o + 1] = UInt8((y * 3) % 200)      // G
            base[o + 2] = UInt8(((x + y) * 2) % 200) // R
            base[o + 3] = 255
        } }
        return buffer
    }

    func testTiledRealCoreMLInferenceMatchesTheWholeImageInversionIncludingSeams() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let id = ModelID("test.tiny.invert@1")
        try await runtime.load(id)
        let width = 80, height = 64          // タイル 32x32 で割り切れない寸法（端に揃えるタイルが出る）
        let source = try gradientBuffer(width: width, height: height)
        let plan = try XCTUnwrap(TilePlan(imageWidth: width, imageHeight: height, tileWidth: 32, tileHeight: 32, overlap: 8))
        XCTAssertGreaterThan(plan.tiles.count, 4)

        let request = InferenceRequest(model: id, width: 32, height: 32, frameID: FrameID(1),
                                       deadline: HostTime.now().advancing(ms: 10_000))
        let result = try await TiledInference.run(frame: InferenceFrame(source), plan: plan, request: request, runtime: runtime)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(result.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(result.pixelBuffer, .readOnly); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        XCTAssertEqual(CVPixelBufferGetWidth(result.pixelBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(result.pixelBuffer), height)
        let s = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        let r = try XCTUnwrap(CVPixelBufferGetBaseAddress(result.pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let sStride = CVPixelBufferGetBytesPerRow(source), rStride = CVPixelBufferGetBytesPerRow(result.pixelBuffer)
        var maxError = 0
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {   // B, G, R（alpha は除く）
            let expected = 255 - Int(s[y * sStride + x * 4 + c])
            maxError = max(maxError, abs(Int(r[y * rStride + x * 4 + c]) - expected))
        } } }
        // モデルは 255 − x。タイルをまたいでも（継ぎ目の混合でも）全画素が反転値に一致する（float16 の丸め ±2）。
        XCTAssertLessThanOrEqual(maxError, 3, "タイル合成の結果が全体の反転と違う（最大誤差 \(maxError)）")
    }

    func testAnyFailingTileFailsTheWholeFrameWithoutPartialOutput() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        // load していない → 最初のタイルで失敗 → 全体が失敗（部分的な出力は返さない）。
        let source = try gradientBuffer(width: 64, height: 64)
        let plan = try XCTUnwrap(TilePlan(imageWidth: 64, imageHeight: 64, tileWidth: 32, tileHeight: 32, overlap: 8))
        let request = InferenceRequest(model: ModelID("test.tiny.invert@1"), width: 32, height: 32, frameID: FrameID(1),
                                       deadline: HostTime.now().advancing(ms: 10_000))
        do {
            _ = try await TiledInference.run(frame: InferenceFrame(source), plan: plan, request: request, runtime: runtime)
            XCTFail("失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .model(.notCompiled))
        }
    }

    func testWrongInputShapeIsRejectedBeforeAnyTileRuns() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let source = try gradientBuffer(width: 48, height: 48)
        let plan = try XCTUnwrap(TilePlan(imageWidth: 64, imageHeight: 64, tileWidth: 32, tileHeight: 32))
        let request = InferenceRequest(model: ModelID("test.tiny.invert@1"), width: 32, height: 32, frameID: FrameID(1),
                                       deadline: HostTime.now().advancing(ms: 10_000))
        do {
            _ = try await TiledInference.run(frame: InferenceFrame(source), plan: plan, request: request, runtime: runtime)
            XCTFail("寸法違いは失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .model(.shapeMismatch))
        }
    }
}
