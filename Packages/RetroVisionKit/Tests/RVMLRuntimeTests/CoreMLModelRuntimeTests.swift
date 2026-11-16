import CoreVideo
import RVMediaCore
import XCTest
@testable import RVMLRuntime

/// 06 §8: tiny model（32x32 を 255-x で反転）による契約検査。load → predict → 出力 layout → unload、
/// と障害分離（shape 不一致・期限超過・breaker・未計測モデルの拒否）。
final class CoreMLModelRuntimeTests: XCTestCase {
    private var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Models")
    }
    private let tinyID = ModelID("test.tiny.invert@1")

    private func makeRuntime(requireMeasurement: Bool = false,
                             breaker: FailureBreaker.Config = .init()) -> CoreMLModelRuntime {
        CoreMLModelRuntime(modelsDirectory: modelsDirectory,
                           options: .init(requireMeasurement: requireMeasurement, breaker: breaker))
    }

    private func makeBGRA(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                           attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4
                base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
            }
        }
        return buffer
    }

    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> (b: Int, g: Int, r: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let o = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(base[o]), Int(base[o + 1]), Int(base[o + 2]))
    }

    private func request(deadlineInMS: Double = 5_000) -> InferenceRequest {
        InferenceRequest(model: tinyID, width: 32, height: 32, frameID: FrameID(1),
                         deadline: HostTime.now().advancing(ms: deadlineInMS))
    }

    func testDiscoverFindsTheTinyModelAndItsManifestDecodes() async {
        let found = await makeRuntime().discover()
        XCTAssertTrue(found.contains { $0.modelID == tinyID }, "tiny model が発見されない")
    }

    func testLoadPredictAndUnloadContract() async throws {
        let runtime = makeRuntime()
        try await runtime.load(tinyID)
        let isLoaded = await runtime.isLoaded(tinyID)
        XCTAssertTrue(isLoaded)

        let input = try makeBGRA(width: 32, height: 32, b: 10, g: 100, r: 200)
        let output = try await runtime.predict(request(), input: InferenceFrame(input))
        XCTAssertEqual(CVPixelBufferGetWidth(output.pixelBuffer), 32)
        XCTAssertEqual(CVPixelBufferGetHeight(output.pixelBuffer), 32)
        let p = try pixel(output.pixelBuffer, x: 16, y: 16)
        // 255 - x（float16 経由の丸めを ±2 まで許す）。
        XCTAssertEqual(p.b, 245, accuracy: 2)
        XCTAssertEqual(p.g, 155, accuracy: 2)
        XCTAssertEqual(p.r, 55, accuracy: 2)

        let health = await runtime.health(of: tinyID)
        XCTAssertEqual(health.breakerState, .closed)
        XCTAssertGreaterThan(health.p50MS, 0, "推論時間が記録される")

        await runtime.unload(tinyID)
        let stillLoaded = await runtime.isLoaded(tinyID)
        XCTAssertFalse(stillLoaded)
        do {
            _ = try await runtime.predict(request(), input: InferenceFrame(input))
            XCTFail("unload 後の predict は失敗するはず")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .model(.notCompiled))
        }
    }

    func testModelsWithoutMeasurementAreRefusedByDefault() async {
        let runtime = makeRuntime(requireMeasurement: true)
        do {
            try await runtime.load(tinyID)
            XCTFail("measuredOn の無いモデルは実行しない（G3 の運用ルール）")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.kind, .model(.runtimeFailure))
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testShapeMismatchIsReportedWithoutTrippingTheBreaker() async throws {
        let runtime = makeRuntime(breaker: .init(windowSize: 5, failureThreshold: 2))
        try await runtime.load(tinyID)
        let wrong = try makeBGRA(width: 64, height: 64, b: 0, g: 0, r: 0)
        for _ in 0..<4 {
            do {
                _ = try await runtime.predict(request(), input: InferenceFrame(wrong))
                XCTFail("寸法違いは失敗するはず")
            } catch let error as PlaybackError {
                XCTAssertEqual(error.kind, .model(.shapeMismatch))
            }
        }
        let health = await runtime.health(of: tinyID)
        XCTAssertEqual(health.breakerState, .closed, "shape 不一致はモデルの不調ではない（breaker に数えない）")
        // 正しい寸法ならそのまま動く。
        let ok = try makeBGRA(width: 32, height: 32, b: 0, g: 0, r: 0)
        _ = try await runtime.predict(request(), input: InferenceFrame(ok))
    }

    func testPastDeadlineDiscardsTheResultWithoutTrippingTheBreaker() async throws {
        let runtime = makeRuntime(breaker: .init(windowSize: 5, failureThreshold: 2))
        try await runtime.load(tinyID)
        let input = try makeBGRA(width: 32, height: 32, b: 1, g: 2, r: 3)
        for _ in 0..<3 {
            do {
                _ = try await runtime.predict(request(deadlineInMS: -1_000), input: InferenceFrame(input))
                XCTFail("期限を過ぎた結果は捨てられるはず")
            } catch let error as PlaybackError {
                XCTAssertEqual(error.kind, .model(.deadlineExceeded))
            }
        }
        let health = await runtime.health(of: tinyID)
        XCTAssertEqual(health.breakerState, .closed, "期限超過は breaker に数えない（超過率は 08 の tier 制御が見る）")
    }

    func testRepeatedRuntimeFailuresOpenTheBreakerAndStopFurtherRequests() async throws {
        let runtime = makeRuntime(breaker: .init(windowSize: 5, failureThreshold: 3, openDurationSeconds: 600))
        try await runtime.load(tinyID)
        // 寸法は合っているが pixel format が違う（BGRA ではなく NV12）→ Core ML が入力を拒む。
        var bad: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &bad)
        let badBuffer = try XCTUnwrap(bad)
        var kinds: [PlaybackError.Kind] = []
        for _ in 0..<5 {
            do {
                _ = try await runtime.predict(request(), input: InferenceFrame(badBuffer))
                XCTFail("形式違いの入力は失敗するはず")
            } catch let error as PlaybackError {
                kinds.append(error.kind)
            }
        }
        XCTAssertEqual(kinds.prefix(3).map { $0 }, [.model(.runtimeFailure), .model(.runtimeFailure), .model(.runtimeFailure)],
                       "最初の 3 回は推論失敗として返る")
        XCTAssertEqual(kinds.suffix(2).map { $0 }, [.model(.disabledByBreaker), .model(.disabledByBreaker)],
                       "3 回失敗で open → 以降は投入されず disabledByBreaker")
        let health = await runtime.health(of: tinyID)
        XCTAssertEqual(health.breakerState, .open)
    }
}
