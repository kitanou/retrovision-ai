import CoreMedia
import CoreVideo
import Foundation
import Metal
import RVMediaCore
import XCTest
@testable import RVVideoPipeline

// 設計 11 §5.2・§7 の検査（P7a）: SR 前のアーティファクト除去を、合成素材と真値で測る。
//
// ブロックの素材は、滑らかな画（真値）を 8×8 の DCT で量子化して作る。真値が手元にあるので、
// 段差指数 B だけでなく再現誤差（真値との PSNR）まで測れる。格子の位相を任意にずらせる（D11）。

// MARK: - 指標（設計 11 §7。輝度の [0,255]）

enum ArtifactMetrics {
    /// 段差指数 B: 8 px 格子上の隣り合う画素の差の平均 ÷ 格子外の平均（横・縦を合わせる）。1.0 が段差なし。
    static func blockiness(_ p: [[Double]], origin: (x: Int, y: Int) = (0, 0)) -> Double {
        let h = p.count, w = p[0].count
        var onSum = 0.0, onN = 0.0, offSum = 0.0, offN = 0.0
        for y in 0..<h {
            for x in 1..<w {
                let d = abs(p[y][x] - p[y][x - 1])
                if (x + origin.x) % 8 == 0 { onSum += d; onN += 1 } else { offSum += d; offN += 1 }
            }
        }
        for y in 1..<h {
            for x in 0..<w {
                let d = abs(p[y][x] - p[y - 1][x])
                if (y + origin.y) % 8 == 0 { onSum += d; onN += 1 } else { offSum += d; offN += 1 }
            }
        }
        return (onSum / onN) / max(offSum / offN, 1e-9)
    }

    static func psnr(_ a: [[Double]], _ b: [[Double]]) -> Double {
        var se = 0.0, n = 0.0
        for y in 0..<a.count { for x in 0..<a[0].count { let d = a[y][x] - b[y][x]; se += d * d; n += 1 } }
        let mse = se / n
        return mse <= 1e-12 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// 勾配エネルギー（細部保持 S の分子・分母）。
    static func gradientEnergy(_ p: [[Double]]) -> Double {
        var e = 0.0
        for y in 0..<(p.count - 1) {
            for x in 0..<(p[0].count - 1) {
                e += abs(p[y][x + 1] - p[y][x]) + abs(p[y + 1][x] - p[y][x])
            }
        }
        return e
    }

    static func variance(_ p: [[Double]], x: Range<Int>, y: Range<Int>) -> Double {
        let vals = y.flatMap { yy in x.map { xx in p[yy][xx] } }
        let m = vals.reduce(0, +) / Double(vals.count)
        return vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)
    }
}

// MARK: - 合成素材

enum ArtifactScenes {
    /// 滑らかな真値（符号化座標 X, Y）。緩い勾配と波。値域は約 60...200。
    static func smooth(_ X: Int, _ Y: Int) -> Double {
        100 + 0.45 * Double(X) + 18 * sin(Double(Y) / 7.0) + 10 * cos(Double(X + Y) / 11.0)
    }

    /// 8×8 の DCT で量子化したブロック素材。`phase` は texture の原点の符号化座標（格子の位相）。
    /// 返すのは (真値, ブロック化) の 2 枚（texture 座標。w × h）。
    static func blocky(width w: Int, height h: Int, phase: (x: Int, y: Int),
                       scene: (Int, Int) -> Double = smooth, q: Double = 14)
        -> (truth: [[Double]], coded: [[Double]]) {
        let padW = ((w + phase.x + 7) / 8) * 8, padH = ((h + phase.y + 7) / 8) * 8
        var coded = [[Double]](repeating: [Double](repeating: 0, count: padW), count: padH)
        var c = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        func alpha(_ u: Int) -> Double { u == 0 ? sqrt(1.0 / 8) : sqrt(2.0 / 8) }
        for by in stride(from: 0, to: padH, by: 8) {
            for bx in stride(from: 0, to: padW, by: 8) {
                for v in 0..<8 {
                    for u in 0..<8 {
                        var sum = 0.0
                        for y in 0..<8 { for x in 0..<8 {
                            sum += scene(bx + x, by + y) * cos(Double(2 * x + 1) * Double(u) * .pi / 16)
                                * cos(Double(2 * y + 1) * Double(v) * .pi / 16)
                        } }
                        let coef = alpha(u) * alpha(v) * sum
                        let step = u == 0 && v == 0 ? 8.0 : q + Double(u + v) * 3
                        c[v][u] = (coef / step).rounded() * step
                    }
                }
                for y in 0..<8 { for x in 0..<8 {
                    var sum = 0.0
                    for v in 0..<8 { for u in 0..<8 {
                        sum += alpha(u) * alpha(v) * c[v][u] * cos(Double(2 * x + 1) * Double(u) * .pi / 16)
                            * cos(Double(2 * y + 1) * Double(v) * .pi / 16)
                    } }
                    coded[by + y][bx + x] = min(max(sum, 0), 255)
                } }
            }
        }
        var truth = [[Double]](repeating: [Double](repeating: 0, count: w), count: h)
        var out = truth
        for y in 0..<h { for x in 0..<w {
            truth[y][x] = scene(x + phase.x, y + phase.y)
            out[y][x] = coded[y + phase.y][x + phase.x]
        } }
        return (truth, out)
    }
}

// MARK: - GPU の経路

final class ArtifactRemovalTests: XCTestCase {
    nonisolated(unsafe) static var context: MetalRenderContext!
    nonisolated(unsafe) static var graph: MetalRenderGraph!

    override class func setUp() {
        guard ProcessInfo.processInfo.environment["RV_SKIP_GPU_TESTS"] == nil,
              let device = MTLCreateSystemDefaultDevice() else { return }
        context = try! MetalRenderContext(device: device)
        graph = try! MetalRenderGraph(context: context)
    }

    private func gpuGate() -> Bool {
        if Self.context != nil { return true }
        XCTFail("Metal device が無い")
        return false
    }

    private struct Request: LumaChromaDenoiseRequest {
        var metalDenoiseStrength: Double? = 0.35
        var metalDenoiseTargets: MetalDenoiseTargets = [.blocking, .chromaNoise]
        var metalDenoiseGridOrigin: (x: Int, y: Int) = (0, 0)
        var canonicalForm: String { "test-\(metalDenoiseStrength ?? -1)-\(metalDenoiseTargets.rawValue)-\(metalDenoiseGridOrigin)" }
    }

    private func makeNV12(width: Int, height: Int, luma: [[Double]], chroma: UInt8 = 128) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [String(kCVPixelBufferMetalCompatibilityKey): true]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &pb)
        guard let pb else { throw NSError(domain: "fixture", code: 1) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yPitch = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<height { for x in 0..<width { yBase[y * yPitch + x] = UInt8(min(max(luma[y][x].rounded(), 0), 255)) } }
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvPitch = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for y in 0..<(height / 2) { for x in 0..<width { uvBase[y * uvPitch + x] = chroma } }
        return pb
    }

    /// 輝度の画を graph に通し、R 面（グレーなので輝度の線形写像。video range の 16...235 → 0...255）を返す。
    /// `request` が nil なら除去の段なし。値は video range の逆写像で輝度の [0,255] に戻す。
    private func render(_ luma: [[Double]], request: Request?) throws -> [[Double]] {
        let h = luma.count, w = luma[0].count
        let pb = try makeNV12(width: w, height: h, luma: luma)
        let input = RenderFrameInput(pixelBuffer: pb, color: .unspecified, interlace: .progressive,
                                     aspect: AspectResolution(targetDAR: AspectRatio(w: Int32(w), h: Int32(h)),
                                                              cleanAperture: PixelRect(x: 0, y: 0, width: Int32(w), height: Int32(h)),
                                                              source: .sampleAspectOnly),
                                     frameID: FrameID(1))
        var stages: [StageRequest] = [.init(stage: .colorConvert, parameters: ColorConvertParameters())]
        if let request { stages.insert(.init(stage: .denoise, parameters: request), at: 0) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = Self.context.device.makeTexture(descriptor: d)!
        let plan = RenderPlan(id: PlanID(1), tier: .lightML, stages: stages,
                              output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                     aspect: input.aspect, present: .offscreen))
        _ = try Self.graph.render(input, plan: plan, to: target)
        let cmd = Self.context.commandQueue.makeCommandBuffer()!
        cmd.commit(); cmd.waitUntilCompleted()
        var data = [UInt8](repeating: 0, count: w * 4 * h)
        target.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return (0..<h).map { y in (0..<w).map { x in Double(data[y * w * 4 + x * 4 + 2]) } }
    }

    private let w = 96, h = 64

    // MARK: blocking

    func testDeblockingLowersBlockinessAndImprovesReconstruction() throws {
        guard gpuGate() else { return }
        let (truth, coded) = ArtifactScenes.blocky(width: w, height: h, phase: (0, 0))
        let before = try render(coded, request: nil)
        let reference = try render(truth, request: nil)
        let after = try render(coded, request: Request(metalDenoiseTargets: [.blocking]))
        let bBefore = ArtifactMetrics.blockiness(before), bAfter = ArtifactMetrics.blockiness(after)
        print("P7a blocking: B \(bBefore) -> \(bAfter), PSNR \(ArtifactMetrics.psnr(before, reference)) -> \(ArtifactMetrics.psnr(after, reference))")
        XCTAssertGreaterThan(bBefore, 1.3, "素材に段差がある（B = \(bBefore)）")
        XCTAssertLessThan(bAfter, bBefore, "段差指数が下がる（\(bBefore) → \(bAfter)）")
        XCTAssertLessThan(bAfter, 1.15, "処理後の段差指数 \(bAfter)")
        XCTAssertGreaterThan(ArtifactMetrics.psnr(after, reference), ArtifactMetrics.psnr(before, reference),
                             "真値との誤差が悪化しない")
    }

    func testGridPhaseMatters() throws {
        guard gpuGate() else { return }
        let phase = (x: 3, y: 5)
        let (truth, coded) = ArtifactScenes.blocky(width: w, height: h, phase: phase)
        let reference = try render(truth, request: nil)
        let right = try render(coded, request: Request(metalDenoiseTargets: [.blocking], metalDenoiseGridOrigin: phase))
        let wrong = try render(coded, request: Request(metalDenoiseTargets: [.blocking], metalDenoiseGridOrigin: (0, 0)))
        let none = try render(coded, request: nil)
        let bRight = ArtifactMetrics.blockiness(right, origin: phase)
        let bWrong = ArtifactMetrics.blockiness(wrong, origin: phase)
        let bNone = ArtifactMetrics.blockiness(none, origin: phase)
        XCTAssertLessThan(bRight, bNone, "位相を合わせれば段差が下がる")
        XCTAssertLessThan(bRight, bWrong, "位相を外すと効きが落ちる（正: \(bRight)、誤: \(bWrong)）")
        XCTAssertGreaterThan(ArtifactMetrics.psnr(right, reference), ArtifactMetrics.psnr(wrong, reference) - 0.001)
    }

    // MARK: 守るもの

    func testLineArtAndStrongEdgesAreKept() throws {
        guard gpuGate() else { return }
        // 8 px 格子の境界ちょうどにある強い縁（段差 80）と 1 px の細い線。
        var img = [[Double]](repeating: [Double](repeating: 70, count: w), count: h)
        for y in 0..<h {
            for x in 0..<w {
                if x >= 40 { img[y][x] = 150 }          // x=40 は 8 の倍数（格子の上）
                if y == 20 && x < 32 { img[y][x] = 200 } // 1 px の横線
                if x == 12 && y > 30 { img[y][x] = 210 } // 1 px の縦線
            }
        }
        let before = try render(img, request: nil)
        let after = try render(img, request: Request(metalDenoiseStrength: 1.0, metalDenoiseTargets: [.blocking, .ringing]))
        let s = ArtifactMetrics.gradientEnergy(after) / ArtifactMetrics.gradientEnergy(before)
        XCTAssertGreaterThanOrEqual(s, 0.98, "線画・強い縁の勾配エネルギーが保たれる（S = \(s)）")
    }

    func testGrainIsNotTouchedByDefaultTargets() throws {
        guard gpuGate() else { return }
        // 平坦な面に決定的な粒子（±6）。既定の targets（blocking + chromaNoise）では輝度に触らない。
        var seed: UInt64 = 12345
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 13) - 6
        }
        let img = (0..<h).map { _ in (0..<w).map { _ in 128 + noise() } }
        let before = try render(img, request: nil)
        let after = try render(img, request: Request(metalDenoiseStrength: 0.35))
        let vb = ArtifactMetrics.variance(before, x: 8..<88, y: 8..<56)
        let va = ArtifactMetrics.variance(after, x: 8..<88, y: 8..<56)
        XCTAssertGreaterThanOrEqual(va / vb, 0.9, "粒子の分散が保たれる（比 \(va / vb)）")
    }

    func testNoTargetsIsIdentity() throws {
        guard gpuGate() else { return }
        let (_, coded) = ArtifactScenes.blocky(width: w, height: h, phase: (0, 0))
        let off = try render(coded, request: nil)
        let empty = try render(coded, request: Request(metalDenoiseTargets: []))
        XCTAssertEqual(off, empty, "targets が空なら恒等")
        let zero = try render(coded, request: Request(metalDenoiseStrength: 0))
        XCTAssertEqual(off, zero, "strength 0 は恒等")
    }

    // MARK: ringing

    func testRingingNearAnEdgeIsReducedAndTheEdgeStays() throws {
        guard gpuGate() else { return }
        // 縁（70 → 170）の右側に、減衰する振動（リンギング）。
        let img = (0..<h).map { _ in (0..<w).map { x -> Double in
            if x < 48 { return 70 }
            let k = Double(x - 48)
            return 170 + 9 * exp(-k / 4) * cos(k * 1.6)
        } }
        let before = try render(img, request: nil)
        let after = try render(img, request: Request(metalDenoiseStrength: 0.6, metalDenoiseTargets: [.ringing]))
        func ripple(_ p: [[Double]]) -> Double { ArtifactMetrics.variance(p, x: 49..<53, y: 8..<56) }
        XCTAssertLessThan(ripple(after), ripple(before) * 0.6, "縁の近傍の振動が減る")
        XCTAssertEqual(after[30][46], before[30][46], accuracy: 2, "縁の暗側は変わらない")
        XCTAssertEqual(after[30][50], before[30][50], accuracy: 12, "縁の明側の最初の画素も保たれる")
    }

    // MARK: 契約

    func testShaderFunctionsExist() throws {
        guard gpuGate() else { return }
        for name in ["rv_deblock_v1", "rv_ringing_v1", "rv_denoise_chroma_v1"] {
            XCTAssertNotNil(Self.context.library.makeFunction(name: name), "shader function 無し: \(name)")
        }
    }
}
