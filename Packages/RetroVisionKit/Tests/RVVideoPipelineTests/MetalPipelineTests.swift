import CoreMedia
import CoreVideo
import Foundation
import Metal
import RVMediaCore
import XCTest
@testable import RVVideoPipeline

// MARK: - GPU パイプラインのピクセル検査（05 §2〜§6。headless GPU で実行）
//
// 実行環境: GitHub の macOS runner は Apple Silicon（メタルデバイス有り）。device が
// 取れない環境は失敗扱い（fixture 欠如と同じ方針 — 09 §2。環境変数 RV_SKIP_GPU_TESTS
// でローカル手元の明示的無効化のみ可）。
//
// 検査する不変条件:
//  1. シェーダソースがコンパイルでき、全 stage 関数・PSO が作れる（§9 の名前契約）
//  2. 既知 YUV 値 → BT.601 RGB が ±3/255（§3 の行列が GPU 経路でも壊れていない）
//  3. letterbox/crop の geometry が純ロジックとして正しい（§6。704 を 720 に伸ばさない）
//  4. bob が field 順序を守る（bottom-first 素材は奇数列=top field。§5）
//  5. edge-directed が動く斜 edge で average より正しい（§5.2 の品質主張の機械検査）
//  6. field 間 SAD が既知差分を出す（§5.1 detector の土台）

final class MetalPipelineTests: XCTestCase {

    nonisolated(unsafe) static var context: MetalRenderContext!
    nonisolated(unsafe) static var graph: MetalRenderGraph!

    override class func setUp() {
        guard ProcessInfo.processInfo.environment["RV_SKIP_GPU_TESTS"] == nil else {
            return   // 各 test で XCTFail する（skip を成功にしない）
        }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        context = try! MetalRenderContext(device: device)
        graph = try! MetalRenderGraph(context: context)
    }

    private var gpuAvailable: Bool { Self.context != nil }

    private func gpuGate() -> Bool {
        if gpuAvailable { return true }
        XCTFail("Metal device が無い（CI の macOS runner では有るはず。RV_SKIP_GPU_TESTS は未設定のはず）")
        return false
    }

    // MARK: - ユーティリティ

    /// NV12 buffer を合成（Y/UV を行単位で埋める。Metal 互換属性付き）。
    private func makeNV12(width: Int, height: Int,
                          luma: @escaping (Int) -> [UInt8],     // 行番号 → 行バイト列
                          chroma: @escaping (Int) -> [UInt8]) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [String(kCVPixelBufferMetalCompatibilityKey): true]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attrs as CFDictionary, &pb)
        XCTAssertEqual(status, kCVReturnSuccess)
        guard let pb else { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "NV12 合成失敗"]) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)
        let yPitch = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for row in 0..<height {
            let bytes = luma(row)
            XCTAssertEqual(bytes.count, width)
            memcpy(yBase!.advanced(by: row * yPitch), bytes, width)
        }
        let uBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
        let uPitch = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<(height / 2) {
            let bytes = chroma(row)
            XCTAssertEqual(bytes.count, width)   // NV12: UV 交互で幅ぶんバイト
            memcpy(uBase!.advanced(by: row * uPitch), bytes, width)
        }
        return pb
    }

    /// offscreen 検証用 texture（読み戻し可能な shared storage）。
    private func makeTarget(width: Int, height: Int) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let t = Self.context.device.makeTexture(descriptor: d) else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "target 確保失敗"])
        }
        return t
    }

    /// bgra8Unorm 読み戻し: (x,y) → (r,g,b)。row0 = 画像の上行（描き込み向きに合わせる）。
    private func readBack(_ target: any MTLTexture) -> [[(r: UInt8, g: UInt8, b: UInt8)]] {
        let w = target.width, h = target.height
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        target.getBytes(&data, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var rows: [[(UInt8, UInt8, UInt8)]] = []
        for y in 0..<h {
            var row: [(UInt8, UInt8, UInt8)] = []
            for x in 0..<w {
                let i = y * bytesPerRow + x * 4
                row.append((data[i + 2], data[i + 1], data[i]))   // BGRA → RGB
            }
            rows.append(row)
        }
        return rows
    }

    /// 同 queue にこれまでに投入した GPU work が終わるまで待つ（command buffer は
    /// 投入順に完了する性質を使う — MTLCommandQueue 自体に待機 API は無い）。
    private func drainGPU() {
        guard let cmd = Self.context.commandQueue.makeCommandBuffer() else { return }
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func aspect43(codedWidth: Int32 = 720, codedHeight: Int32 = 480) -> AspectResolution {
        // 720x480 の cleanAperture 704（ITU 例）。PAR 10:11 → DAR 4:3。
        AspectResolution(targetDAR: .dar4x3,
                         cleanAperture: PixelRect(x: 8, y: 0, width: 704, height: 480),
                         source: .sampleAspectOnly)
    }

    private func progressiveInput(_ pb: CVPixelBuffer, width: Int, height: Int) -> RenderFrameInput {
        RenderFrameInput(pixelBuffer: pb, color: .unspecified, interlace: .progressive,
                         aspect: AspectResolution(targetDAR: AspectRatio(w: Int32(width), h: Int32(height)),
                                                  cleanAperture: PixelRect(x: 0, y: 0, width: Int32(width), height: Int32(height)),
                                                  source: .sampleAspectOnly),
                         frameID: FrameID(1))
    }

    // MARK: - 1. シェーダ・PSO の名前契約（05 §9）

    func testShaderLibraryCompilesAndExposesAllStageFunctions() throws {
        guard gpuGate() else { return }
        let lib = Self.context.library
        for name in ["rv_vs_fullscreen", "rv_colorConvert_v1", "rv_deint_bob_v1",
                     "rv_deint_edgeDirected_v1", "rv_deint_motionAdaptive_v1", "rv_fieldMatch_sad_v1"] {
            XCTAssertNotNil(lib.makeFunction(name: name), "shader function 無し: \(name)")
        }
        // 実 PSO 生成（colorConvert は bgra8 の render pipeline、deint/detector は compute）
        _ = try Self.context.renderPipeline(vertex: "rv_vs_fullscreen", fragment: "rv_colorConvert_v1",
                                            colorFormat: .bgra8Unorm, label: "test")
        _ = try Self.context.computePipeline(function: "rv_deint_edgeDirected_v1", label: "test")
        _ = try Self.context.computePipeline(function: "rv_fieldMatch_sad_v1", label: "test")
        let cv = MTLFunctionConstantValues()
        var topFirst = true
        cv.setConstantValue(&topFirst, type: .bool, index: 0)
        _ = try Self.context.computePipeline(function: "rv_deint_bob_v1", constants: cv, label: "test")
    }

    // MARK: - 2. 既知 YUV → RGB（GPU 経路の数値同一性。±3/255）

    func testColorConvertGPUPathMatchesKnownBarValues() throws {
        guard gpuGate() else { return }
        let w = 64, h = 48
        // 画面全体を赤バー（BT.601: Y=81, Cb=90, Cr=240）で埋める
        let pb = try makeNV12(width: w, height: h,
                              luma: { _ in [UInt8](repeating: 81, count: w) },
                              chroma: { _ in [UInt8](repeating: 0, count: w).enumerated().map { i, _ in i % 2 == 0 ? 90 : 240 }})
        let target = try makeTarget(width: w, height: h)
        let plan = RenderPlan.metalBaseline(id: PlanID(1), output: OutputContract(
            displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
            aspect: aspect43(codedWidth: Int32(w), codedHeight: Int32(h))))
        // 1:1 寸法。metalBaseline は deinterlace(auto) を含むが progressive（fieldCount 0）→ passthrough。
        let input = progressiveInput(pb, width: w, height: h)
        let timing = try Self.graph.render(input, plan: plan, to: target)
        drainGPU()
        _ = timing
        let px = readBack(target)[h / 2][w / 2]
        // 期待 (254,0,0)。色は matrix assumption（ColorInfo.unspecified → BT.601）経路を通る。
        XCTAssertLessThanOrEqual(abs(Int(px.r) - 254), 3, "赤バー R: got \(px.r)")
        XCTAssertLessThanOrEqual(Int(px.g), 4, "赤バー G: got \(px.g)")
        XCTAssertLessThanOrEqual(Int(px.b), 4, "赤バー B: got \(px.b)")
    }

    func testColorAssumptionIsRecordedByRender() throws {
        guard gpuGate() else { return }
        let w = 16, h = 16
        let pb = try makeNV12(width: w, height: h,
                              luma: { _ in [UInt8](repeating: 128, count: w) },
                              chroma: { _ in [UInt8](repeating: 128, count: w) })
        let target = try makeTarget(width: w, height: h)
        let plan = RenderPlan.metalBaseline(id: PlanID(2), output: OutputContract(
            displayPixels: PixelSize(width: 16, height: 16),
            aspect: aspect43(codedWidth: 16, codedHeight: 16), present: .offscreen))
        let input = progressiveInput(pb, width: w, height: h)
        // color は .unspecified のまま → assumption 発動が RenderTiming に残る（05 §3）
        let timing = try Self.graph.render(input, plan: plan, to: target)
        XCTAssertTrue(timing.colorAssumptionApplied, "assumption の発動が記録されていない")
        XCTAssertEqual(timing.colorMatrixUsed, "bt601_4")
    }

    // MARK: - 3. geometry（純ロジック。05 §6）

    func testGeometryLetterboxAndCrop() throws {
        // 720x480 → 640x480 target、DAR 4:3: 幅いっぱいで letterbox 無し（比率一致）
        let a43 = aspect43()
        let g = MetalRenderGraph.geometry(aspect: a43, codedWidth: 720, codedHeight: 480,
                                         targetWidth: 640, targetHeight: 480)
        // sourceRect: cleanAperture 704 offset 8 を 720 で割る（704/720 — 引き伸ばさない）
        XCTAssertLessThanOrEqual(abs(Double(g.source.0) - 8.0 / 720.0), 1e-5, "src x")
        XCTAssertLessThanOrEqual(abs(Double(g.source.2) - 704.0 / 720.0), 1e-5, "src w")
        XCTAssertLessThanOrEqual(abs(Double(g.dest.2) - 1.0), 1e-4, "4:3 → 4:3 は letterbox 無し")
        XCTAssertLessThanOrEqual(abs(Double(g.dest.3) - 1.0), 1e-4)

        // 16:9 target に 4:3: pillarbox（幅 75%、中央）
        let g2 = MetalRenderGraph.geometry(aspect: a43, codedWidth: 720, codedHeight: 480,
                                          targetWidth: 1024, targetHeight: 576)
        XCTAssertLessThanOrEqual(abs(Double(g2.dest.0) - 0.125), 1e-4, "pillarbox x")
        XCTAssertLessThanOrEqual(abs(Double(g2.dest.2) - 0.75), 1e-4, "pillarbox w")
        XCTAssertLessThanOrEqual(abs(Double(g2.dest.1)), 1e-6)
        XCTAssertLessThanOrEqual(abs(Double(g2.dest.3) - 1.0), 1e-4)

        // 4:3 target に 16:9: letterbox（高さ 75%）
        let wide = AspectResolution(targetDAR: .dar16x9,
                                    cleanAperture: PixelRect(x: 0, y: 0, width: 720, height: 480),
                                    source: .sampleAspectOnly)
        let g3 = MetalRenderGraph.geometry(aspect: wide, codedWidth: 720, codedHeight: 480,
                                          targetWidth: 640, targetHeight: 480)
        XCTAssertLessThanOrEqual(abs(Double(g3.dest.1) - 0.125), 1e-4, "letterbox y")
        XCTAssertLessThanOrEqual(abs(Double(g3.dest.3) - 0.75), 1e-4, "letterbox h")
    }

    // MARK: - 4. bob の field 順序（05 §5。bottom-first fixture の実配列に対応）

    func testBobHonoursFieldOrder() throws {
        guard gpuGate() else { return }
        let w = 32, h = 16
        // weave 信号: 偶数行 = 190（A field）、奇数行 = 30（B field）。chroma 中立。
        let pb = try makeNV12(width: w, height: h,
                              luma: { row in [UInt8](repeating: row % 2 == 0 ? 190 : 30, count: w) },
                              chroma: { _ in [UInt8](repeating: 0, count: w).enumerated().map { i, _ in 128 }})

        func renderBob(order: FieldOrder) throws -> [[(r: UInt8, g: UInt8, b: UInt8)]] {
            var interlace = InterlaceInfo.ntscInterlaced
            interlace = InterlaceInfo(fieldCount: 2, fieldOrder: order, cadence: .interlaced22,
                                      fieldSource: .formatDescription)
            var input = progressiveInput(pb, width: w, height: h)
            input.interlace = interlace
            let target = try makeTarget(width: w, height: h)
            let plan = RenderPlan(id: PlanID(3), tier: .metalOnly,
                                  stages: [.init(stage: .deinterlace, parameters: DeinterlaceParameters(mode: .bob)),
                                           .init(stage: .colorConvert, parameters: ColorConvertParameters())],
                                  output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                         aspect: input.aspect, present: .offscreen))
            _ = try Self.graph.render(input, plan: plan, to: target)
            drainGPU()
            return readBack(target)
        }

        // top-first: 偶数行 = 上 field → bob の全行は偶数行（190→明）で満たされる
        let top = try renderBob(order: .topFirst)
        for row in [0, 1, 2, 3] {
            XCTAssertGreaterThan(Int(top[row][1].r), 150, "top-first bob 行\(row) が暗い: \(top[row][1])")
        }
        // bottom-first: 上 field は奇数列 → bob の全行は奇数行（30→暗）
        let bottom = try renderBob(order: .bottomFirst)
        for row in [0, 1, 2, 3] {
            XCTAssertLessThan(Int(bottom[row][1].r), 90, "bottom-first bob 行\(row) が明るい: \(bottom[row][1])")
        }
    }

    // MARK: - 5. edge-directed の品質主張（動く斜 edge を average より正しく）

    func testEdgeDirectedFollowsMovingEdge() throws {
        guard gpuGate() else { return }
        let w = 32, h = 16
        // 保持 field（偶数行）の斜 edge: 行 r で列 c(r) = 2r の右側が黒（走査線 1 行ごとに 2 列進む）。
        // 奇数行の源値は逆パターンのゴミ（補間側は源を使ってはいけない設計の不変検査）。
        let pb = try makeNV12(width: w, height: h,
                              luma: { row in
            let c = 2 * row
            if row % 2 == 0 { return (0..<w).map { x in x < c ? 235 : 16 } }
            return (0..<w).map { x in x >= (w - c) ? 235 : 16 }
        }, chroma: { _ in [UInt8](repeating: 128, count: w) })

        var input = progressiveInput(pb, width: w, height: h)
        input.interlace = InterlaceInfo(fieldCount: 2, fieldOrder: .topFirst, cadence: .interlaced22,
                                        fieldSource: .formatDescription)
        let target = try makeTarget(width: w, height: h)
        let plan = RenderPlan(id: PlanID(4), tier: .metalOnly,
                              stages: [.init(stage: .deinterlace, parameters: DeinterlaceParameters(mode: .edgeDirected)),
                                       .init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                     aspect: input.aspect, present: .offscreen))
        _ = try Self.graph.render(input, plan: plan, to: target)
        drainGPU()
        let px = readBack(target)

        // 補間行 y=2m+1 の x=4m+1（内挿 edge の左 1 画素 = 白領域の内側）。
        // simple average（対 a=0）なら上下が edge を跨ぐので gray（≈128）になる。
        // edge-directed は a=-2（実際の傾き 2 列/row に一致）を選び上下とも白 → 235。
        // この 2 値の差が §5.2 の品質主張の機械検査。
        for m in [3, 5] {
            let y = 2 * m + 1, x = 4 * m + 1
            let v = Int(px[y][x].r)
            XCTAssertGreaterThan(v, 150,
                                 "edgeDirected 行\(y) 列\(x): gray(\(v)) — 対称 2 点内挿が斜 edge を追っていない")
        }
        // 保持行は源そのまま（偶数行: x < 2r で白）。
        for r in [2, 4, 6] {
            XCTAssertGreaterThan(Int(px[r][2 * r - 1].r), 150, "保持行 行\(r) の白側が汚染")
            XCTAssertLessThan(Int(px[r][2 * r + 1].r), 90, "保持行 行\(r) の黒側が汚染")
        }
    }

    // MARK: - 5b. motion-adaptive（静止は weave、動きは空間内挿。前 frame が無ければ edge-directed）

    /// 偶数行 = A、奇数行 = B（B ≠ A）の縞を作る。前 frame を同じにすれば「静止」、
    /// 大きく変えれば「動き」。出力の奇数行がどちらになるかで weave / 空間内挿を判定する。
    private func renderMotionAdaptive(previousLuma: UInt8?) throws -> [[(r: UInt8, g: UInt8, b: UInt8)]] {
        let w = 32, h = 16
        let rowsA: UInt8 = 60, rowsB: UInt8 = 200
        func stripes(_ even: UInt8, _ odd: UInt8) throws -> CVPixelBuffer {
            try makeNV12(width: w, height: h,
                         luma: { row in [UInt8](repeating: row % 2 == 0 ? even : odd, count: w) },
                         chroma: { _ in [UInt8](repeating: 128, count: w) })
        }
        let cur = try stripes(rowsA, rowsB)
        var input = progressiveInput(cur, width: w, height: h)
        input.interlace = InterlaceInfo(fieldCount: 2, fieldOrder: .topFirst, cadence: .interlaced22,
                                        fieldSource: .formatDescription)
        if let previousLuma {
            // 静止: 同じ縞。動き: 全行を別の値にする。
            input.previousPixelBuffer = previousLuma == 0 ? cur
                : try makeNV12(width: w, height: h,
                               luma: { _ in [UInt8](repeating: previousLuma, count: w) },
                               chroma: { _ in [UInt8](repeating: 128, count: w) })
        }
        let target = try makeTarget(width: w, height: h)
        let plan = RenderPlan(id: PlanID(5), tier: .metalOnly,
                              stages: [.init(stage: .deinterlace, parameters: DeinterlaceParameters(mode: .motionAdaptive)),
                                       .init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                     aspect: input.aspect, present: .offscreen))
        let timing = try Self.graph.render(input, plan: plan, to: target)
        drainGPU()
        XCTAssertEqual(timing.deinterlaceApplied, previousLuma == nil ? .edgeDirected : .motionAdaptive)
        return readBack(target)
    }

    func testMotionAdaptiveKeepsStaticDetailAndInterpolatesMotion() throws {
        guard gpuGate() else { return }
        // 保持行（偶数）は A=60 → 暗い。奇数行の源は B=200 → 明るい。
        let still = try renderMotionAdaptive(previousLuma: 0)        // 前 frame = 同じ縞（静止）
        let moving = try renderMotionAdaptive(previousLuma: 128)     // 前 frame と大きく違う（動き）
        let noPrev = try renderMotionAdaptive(previousLuma: nil)     // 前 frame 無し → edge-directed
        let y = 5   // 奇数行（補間側）
        XCTAssertGreaterThan(Int(still[y][10].r), 150, "静止部は weave（源の他 field の線）を保つはず")
        XCTAssertLessThan(Int(moving[y][10].r), 110, "動き部は空間内挿（保持行の明るさ）になるはず")
        XCTAssertLessThan(Int(noPrev[y][10].r), 110, "前 frame 無しは edge-directed（空間内挿）になるはず")
        // 保持行は常に源のまま。
        XCTAssertLessThan(Int(still[4][10].r), 110)
        XCTAssertLessThan(Int(moving[4][10].r), 110)
    }

    /// 色（4:2:0）も field 交互: 偶数 chroma 行 = Cb 100、奇数 chroma 行 = Cb 156。輝度は平坦。
    /// 静止なら weave（奇数行は 156 のまま）、動きなら偶数行の chroma から補間（奇数行も 100 側に寄る）。
    private func renderChromaStripes(previousLuma: UInt8) throws -> [[(r: UInt8, g: UInt8, b: UInt8)]] {
        let w = 32, h = 32
        func make(luma: UInt8) throws -> CVPixelBuffer {
            try makeNV12(width: w, height: h,
                         luma: { _ in [UInt8](repeating: luma, count: w) },
                         chroma: { row in
                // chroma 行は 1 行 = (Cb, Cr) × (w/2) 画素。偶数行 Cb=100 / 奇数行 Cb=156、Cr=128。
                (0..<(w / 2)).flatMap { _ in [UInt8(row % 2 == 0 ? 100 : 156), UInt8(128)] }
            })
        }
        let cur = try make(luma: 128)
        var input = progressiveInput(cur, width: w, height: h)
        input.interlace = InterlaceInfo(fieldCount: 2, fieldOrder: .topFirst, cadence: .interlaced22,
                                        fieldSource: .formatDescription)
        input.previousPixelBuffer = previousLuma == 128 ? cur : try make(luma: previousLuma)
        let target = try makeTarget(width: w, height: h)
        let plan = RenderPlan(id: PlanID(9), tier: .metalOnly,
                              stages: [.init(stage: .deinterlace, parameters: DeinterlaceParameters(mode: .motionAdaptive)),
                                       .init(stage: .colorConvert, parameters: ColorConvertParameters())],
                              output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                     aspect: input.aspect, present: .offscreen))
        _ = try Self.graph.render(input, plan: plan, to: target)
        drainGPU()
        return readBack(target)
    }

    func testMotionAdaptiveInterpolatesChromaOnlyWhereThePixelMoves() throws {
        guard gpuGate() else { return }
        let still = try renderChromaStripes(previousLuma: 128)    // 前 frame と同じ → 静止
        let moving = try renderChromaStripes(previousLuma: 40)    // 前 frame と大きく違う → 動き
        // 輝度 row 6 は chroma 行 3（奇数）、row 4 は chroma 行 2（偶数）。青成分に Cb の差が出る。
        let stillGap = abs(Int(still[6][10].b) - Int(still[4][10].b))
        let movingGap = abs(Int(moving[6][10].b) - Int(moving[4][10].b))
        XCTAssertGreaterThan(stillGap, 20, "静止は chroma を weave（偶数行と奇数行の色が違うまま）")
        XCTAssertLessThan(movingGap, 6, "動きは偶数行の chroma から補間（奇数行も偶数行と同じ色になる）")
    }

    // MARK: - 5c. highQuality スケール（拡大時は bicubic。エッジが bilinear より鋭い）

    private func renderStepEdge(filter: ScaleParameters.ScaleFilter, targetSize: Int) throws -> [UInt8] {
        let w = 16, h = 16
        let pb = try makeNV12(width: w, height: h,
                              luma: { _ in (0..<w).map { $0 < w / 2 ? 40 : 200 } },
                              chroma: { _ in [UInt8](repeating: 128, count: w) })
        let input = progressiveInput(pb, width: w, height: h)
        let target = try makeTarget(width: targetSize, height: targetSize)
        let plan = RenderPlan(id: PlanID(6), tier: .metalOnly,
                              stages: [.init(stage: .colorConvert, parameters: ColorConvertParameters()),
                                       .init(stage: .scale, parameters: ScaleParameters(filter: filter))],
                              output: OutputContract(displayPixels: PixelSize(width: Int32(targetSize), height: Int32(targetSize)),
                                                     aspect: input.aspect, present: .offscreen))
        _ = try Self.graph.render(input, plan: plan, to: target)
        drainGPU()
        return readBack(target)[targetSize / 2].map(\.r)
    }

    func testHighQualityScaleSharpensEdgesWhenUpscalingOnly() throws {
        guard gpuGate() else { return }
        // 16 → 64 の拡大（4 倍）。遷移幅 = 暗側 10% 〜 明側 90% の間に居る画素数。
        func transitionWidth(_ row: [UInt8]) -> Int {
            let lo = Int(row.first ?? 0), hi = Int(row.last ?? 0)
            let a = lo + (hi - lo) / 10, b = hi - (hi - lo) / 10
            return row.filter { Int($0) > a && Int($0) < b }.count
        }
        let linear = try renderStepEdge(filter: .bilinear, targetSize: 64)
        let cubic = try renderStepEdge(filter: .highQuality, targetSize: 64)
        XCTAssertLessThan(transitionWidth(cubic), transitionWidth(linear),
                          "拡大時の highQuality は bilinear よりエッジが鋭い（遷移幅が狭い）はず")
        // 縮小（16 → 8）では highQuality でも linear と同じ経路（bicubic は使わない）。
        let linearDown = try renderStepEdge(filter: .bilinear, targetSize: 8)
        let cubicDown = try renderStepEdge(filter: .highQuality, targetSize: 8)
        XCTAssertEqual(linearDown, cubicDown, "縮小は filter に関わらず同じ（linear）")
        // 平坦部は変えない（overshoot を clamp で抑えても、元の暗/明の値が保たれる）。
        XCTAssertEqual(Int(cubic.first ?? 0), Int(linear.first ?? 0), accuracy: 2)
        XCTAssertEqual(Int(cubic.last ?? 0), Int(linear.last ?? 0), accuracy: 2)
    }

    // MARK: - 5d. 非 AI denoise（エッジ保存。小振幅の揺らぎは均し、強い edge は保つ）

    private struct TestDenoise: LumaChromaDenoiseRequest {
        var metalDenoiseStrength: Double?
        var canonicalForm: String { "test-denoise=\(metalDenoiseStrength ?? -1)" }
    }

    private func renderNoisyEdge(strength: Double?) throws -> [[UInt8]] {
        let w = 32, h = 32
        // 左半分: 128 を中心に ±8 の市松ノイズ。右半分: 平坦な 220（x=16 に強い edge）。
        let pb = try makeNV12(width: w, height: h,
                              luma: { row in
            (0..<w).map { x in x < 16 ? ((x + row) % 2 == 0 ? UInt8(120) : UInt8(136)) : UInt8(220) }
        }, chroma: { _ in [UInt8](repeating: 128, count: w) })
        let input = progressiveInput(pb, width: w, height: h)
        var stages: [StageRequest] = [.init(stage: .colorConvert, parameters: ColorConvertParameters())]
        if let strength { stages.insert(.init(stage: .denoise, parameters: TestDenoise(metalDenoiseStrength: strength)), at: 0) }
        let target = try makeTarget(width: w, height: h)
        let plan = RenderPlan(id: PlanID(8), tier: .lightML, stages: stages,
                              output: OutputContract(displayPixels: PixelSize(width: Int32(w), height: Int32(h)),
                                                     aspect: input.aspect, present: .offscreen))
        let timing = try Self.graph.render(input, plan: plan, to: target)
        XCTAssertEqual(timing.denoiseApplied, (strength ?? 0) > 0)
        drainGPU()
        return readBack(target).map { $0.map(\.r) }
    }

    func testMetalGuidedDenoiseSmoothsNoiseButKeepsStrongEdges() throws {
        guard gpuGate() else { return }
        func noiseRange(_ px: [[UInt8]]) -> Int {   // 平坦なノイズ領域（edge から離れた x 4...10）の振れ幅
            let vals = (8...24).flatMap { y in (4...10).map { x in Int(px[y][x]) } }
            return (vals.max() ?? 0) - (vals.min() ?? 0)
        }
        let off = try renderNoisyEdge(strength: nil)
        let zero = try renderNoisyEdge(strength: 0)
        let on = try renderNoisyEdge(strength: 0.8)
        XCTAssertEqual(noiseRange(zero), noiseRange(off), "strength 0 は恒等（段を実行しない）")
        XCTAssertLessThan(noiseRange(on), noiseRange(off) / 2, "ノイズ領域の振れ幅が半分未満に均される")
        // 強い edge は保たれる: 暗側（x=12）は暗いまま、明側（x=20）は明るいまま。
        let y = 16
        XCTAssertLessThan(Int(on[y][12]), 150, "暗側が edge を越えて明るくならない")
        XCTAssertGreaterThan(Int(on[y][20]), 190, "明側が edge を越えて暗くならない")
    }

    // MARK: - 6. field 間 SAD（05 §5.1 detector の土台。kernel 直接）

    func testFieldMatchSADProducesKnownDifference() throws {
        guard gpuGate() else { return }
        let w = 16, h = 16   // 2x1 blocks
        // 偶数行 = 0.6（153/255）、奇数行 = 0.4（102/255）→ 隣接走査線差 = 0.2
        let pb = try makeNV12(width: w, height: h,
                              luma: { row in [UInt8](repeating: row % 2 == 0 ? 153 : 102, count: w) },
                              chroma: { _ in [UInt8](repeating: 128, count: w).enumerated().map { i, _ in i % 2 == 0 ? 128 : 128 }})
        guard let planes = Self.graph.importer.importNV12(pb) else { return XCTFail("取り込み失敗") }
        let pso = try Self.context.computePipeline(function: "rv_fieldMatch_sad_v1", label: "test")
        let blockCount = (w / 8) * (h / 16)
        let buf = Self.context.device.makeBuffer(length: MemoryLayout<Float>.stride * blockCount)!
        let cmd = Self.context.commandQueue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setTexture(planes[0].texture, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        var blocks = (UInt32(w / 8), UInt32(h / 16))
        enc.setBytes(&blocks, length: MemoryLayout<(UInt32, UInt32)>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: w / 8, height: h / 16, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let out = buf.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<blockCount {
            // 51/255 = 0.2（正規化）。r8Unorm テクスチャの read は [0,1] 正規化。
            XCTAssertLessThanOrEqual(abs(out[i] - 0.2), 0.01, "SAD block\(i): got \(out[i])")
        }
    }

    // MARK: - 7. present 計画（純ロジックの部分。refresh 推定は present 記録から）

    func testEstimateRefreshFromPresentRecords() throws {
        func records(intervalMS: [Double]) -> [PresentRecord] {
            var t = 1_000.0
            return intervalMS.map { d in
                t += d
                return PresentRecord(frameID: FrameID(0), pts: CMTime(seconds: t / 1000, preferredTimescale: 1_000),
                                     scheduledHostMS: t, presentedHostMS: t, jitterMS: 0)
            }
        }
        // 60 Hz 相当（16.67 ms 間隔・±0.4 ms の揺らぎ）→ hz60
        let noisy = (0..<20).map { i in 1000.0 / 60.0 + (i % 2 == 0 ? 0.4 : -0.4) }
        let est = MetalPresenter.estimateRefresh(records: records(intervalMS: noisy))
        XCTAssertEqual(est, .hz60)
        // 59.94（60000/1001）→ hz59_94 に丸める
        let ntsc = [Double](repeating: 1_000.0 * 1_001 / 60_000, count: 12)
        XCTAssertEqual(MetalPresenter.estimateRefresh(records: records(intervalMS: ntsc)), .hz59_94)
        // 2 件未満は nil（推定しない）
        XCTAssertNil(MetalPresenter.estimateRefresh(records: records(intervalMS: [16.7, 16.7])))
    }
}
