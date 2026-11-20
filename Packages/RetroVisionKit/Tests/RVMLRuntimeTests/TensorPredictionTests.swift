import CoreVideo
import Foundation
import XCTest

@testable import RVMLRuntime
import RVMediaCore

/// テンソル（fp16 NCHW、IOSurface 付き）入出力の推論（設計 11 §5.4・P2）。
/// tiny model: 入力 [1,3,16,24] → 出力 [1,3,32,48] = 「1 − x」を最近傍で 2 倍。
final class TensorPredictionTests: XCTestCase {
    private let id = ModelID("test.tiny.sr2x.f16@1")
    private var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Models")
    }

    static func write(_ t: TensorFrame, _ value: (Int, Int, Int) -> Float) {
        let pb = t.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        for c in 0..<t.channels { for y in 0..<t.height { for x in 0..<t.width {
            base.advanced(by: (c * t.height + y) * stride + x * 2).assumingMemoryBound(to: Float16.self).pointee = Float16(value(c, y, x))
        } } }
    }

    static func read(_ t: TensorFrame, c: Int, y: Int, x: Int) -> Float {
        let pb = t.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        return Float(CVPixelBufferGetBaseAddress(pb)!.advanced(by: (c * t.height + y) * stride + x * 2)
            .assumingMemoryBound(to: Float16.self).pointee)
    }

    private func value(_ c: Int, _ y: Int, _ x: Int) -> Float { Float(c * 100 + y * 24 + x) / 400 }

    func testTensorRoundTripMapsEveryChannelAndPosition() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(id)
        let input = try XCTUnwrap(TensorFrame.make(width: 24, height: 16))
        Self.write(input, value)
        let request = InferenceRequest(model: id, width: 24, height: 16, frameID: FrameID(1),
                                       deadline: HostTime.now().advancing(ms: 5_000))
        let out = try await runtime.predictTensor(request, input: input)
        XCTAssertEqual(out.width, 48); XCTAssertEqual(out.height, 32); XCTAssertEqual(out.channels, 3)
        for c in 0..<3 { for y in stride(from: 0, to: 32, by: 3) { for x in stride(from: 0, to: 48, by: 5) {
            XCTAssertEqual(Self.read(out, c: c, y: y, x: x), 1 - value(c, y / 2, x / 2), accuracy: 2e-3, "c\(c) (\(x),\(y))")
        } } }
        await runtime.unload(id)
    }

    func testWrongInputSizeIsShapeMismatch() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        try await runtime.load(id)
        let input = try XCTUnwrap(TensorFrame.make(width: 32, height: 16))
        let request = InferenceRequest(model: id, width: 32, height: 16, frameID: FrameID(1),
                                       deadline: HostTime.now().advancing(ms: 5_000))
        do {
            _ = try await runtime.predictTensor(request, input: input)
            XCTFail("shape 不一致が通った")
        } catch let error as PlaybackError {
            guard case .model(.shapeMismatch) = error.kind else { return XCTFail("\(error.kind)") }
        }
    }

    func testImageModelRejectsTensorPrediction() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let imageModel = ModelID("test.tiny.invert@1")
        try await runtime.load(imageModel)
        let input = try XCTUnwrap(TensorFrame.make(width: 32, height: 32))
        do {
            _ = try await runtime.predictTensor(InferenceRequest(model: imageModel, width: 32, height: 32, frameID: FrameID(1),
                                                                 deadline: HostTime.now().advancing(ms: 5_000)), input: input)
            XCTFail("image モデルでテンソル推論が通った")
        } catch let error as PlaybackError {
            guard case .model(.conversionUnsupported) = error.kind else { return XCTFail("\(error.kind)") }
        }
    }
}

// MARK: - EnumeratedShapes（設計 11 D4）

extension TensorPredictionTests {
    func testEnumeratedModelAcceptsEachListedSizeAndRejectsOthers() async throws {
        let runtime = CoreMLModelRuntime(modelsDirectory: modelsDirectory, options: .init(requireMeasurement: false))
        let enumID = ModelID("test.tiny.sr2x.f16.enum@1")
        try await runtime.load(enumID)
        for (w, h) in [(24, 16), (32, 24)] {
            let input = try XCTUnwrap(TensorFrame.make(width: w, height: h))
            Self.write(input) { c, y, x in Float(c * 10 + y + x) / 100 }
            let out = try await runtime.predictTensor(InferenceRequest(model: enumID, width: w, height: h, frameID: FrameID(1),
                                                                       deadline: HostTime.now().advancing(ms: 5_000)), input: input)
            XCTAssertEqual(out.width, w * 2); XCTAssertEqual(out.height, h * 2)
            XCTAssertEqual(Self.read(out, c: 2, y: h * 2 - 1, x: w * 2 - 1),
                           1 - Float(20 + (h - 1) + (w - 1)) / 100, accuracy: 2e-3, "\(w)x\(h)")
        }
        let other = try XCTUnwrap(TensorFrame.make(width: 20, height: 20))
        do {
            _ = try await runtime.predictTensor(InferenceRequest(model: enumID, width: 20, height: 20, frameID: FrameID(1),
                                                                 deadline: HostTime.now().advancing(ms: 5_000)), input: other)
            XCTFail("一覧に無い寸法が通った")
        } catch let error as PlaybackError {
            guard case .model(.shapeMismatch) = error.kind else { return XCTFail("\(error.kind)") }
        }
    }
}
