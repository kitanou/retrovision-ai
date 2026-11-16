import CoreVideo
import Foundation
import Metal
import RVMediaCore

// MARK: - RenderGraph（05 §1: plan を command buffer に落とす実行器）
//
// plan の stages を実行順に処理する。段の追加・削除は plan の書き換えだけで、
// この実行器のコードは変更不要にする（…が趣旨。v1 で実行するのは
// [deinterlace?] → [colorConvert+scale] の鉄路。AI 段（#7）と字幕合成（#3/#4）は
// 同じ口を通す）。
//
// 実行モデル:
// - 1 frame = 1 command buffer（段は同じ buffer の中に順に積む）。CPU 側は待たない
//   （完了通知は completedHandler で受ける — 提示経路は次節の MetalPresenter が担う）。
// - 段ごとの CPU wall time（投入・符号）を StageTimingMS に残す（05 §8 の CPU 側計測。
//   GPU 側の実行時間は present の presentedTime と合わせて 04 §9 系の実測表を作る）。
// - 取り込み texture は command buffer 完了まで生存させる（FrameImport を完了まで保持）。

public struct RenderFrameInput: @unchecked Sendable {
    public var pixelBuffer: CVPixelBuffer
    public var color: ColorInfo
    public var interlace: InterlaceInfo
    public var aspect: AspectResolution
    /// 诊断用（frame id など。pipeline は意味を決めない）。
    public var frameID: FrameID?

    public init(pixelBuffer: CVPixelBuffer, color: ColorInfo, interlace: InterlaceInfo,
                aspect: AspectResolution, frameID: FrameID? = nil) {
        self.pixelBuffer = pixelBuffer
        self.color = color
        self.interlace = interlace
        self.aspect = aspect
        self.frameID = frameID
    }
}

/// 段別の CPU wall time（ms。encode 投入までの時間）。plan の stage id を key にする。
public struct RenderTiming: Sendable {
    public var stageEncodeMS: [(stage: StageID, ms: Double)] = []
    public var encodeTotalMS: Double = 0
    /// 実際に適用された deinterlace mode（auto 解決の後。plan・診断に残す値 — 05 §5.2）。
    public var deinterlaceApplied: DeinterlaceMode?
    public var colorMatrixUsed: String = ""
    public var colorAssumptionApplied: Bool = false
}

public final class MetalRenderGraph: @unchecked Sendable {
    public let context: MetalRenderContext
    let importer: PixelBufferImporter
    let pool: TexturePool

    public init(context: MetalRenderContext) throws {
        self.context = context
        self.importer = try PixelBufferImporter(context: context)
        self.pool = TexturePool(context: context)
    }

    /// plan を target（drawable の texture か offscreen 検証用 texture）へ描く。
    /// target の寸法が plan.output.displayPixels と違う場合は letterbox をその場で計算する
    /// （窓リサイズで plan を毎回作り直さないための措置。表示品質上は plan 再生成が本则 — 08 §3）。
    public func render(_ input: RenderFrameInput, plan: RenderPlan,
                      to target: any MTLTexture,
                      completed: ((Result<Void, PlaybackError>, RenderTiming) -> Void)? = nil) throws
        -> RenderTiming {
        guard let command = context.commandQueue.makeCommandBuffer() else {
            throw PlaybackError(kind: .render(.deviceUnavailable),
                                recovery: .retryWith(.lowerTier),
                                userMessage: "command buffer を作成できません")
        }
        var timing = RenderTiming()
        let began = ContinuousClock.now

        // 1. 取り込み（zero-copy。完了まで生存させる）
        guard let planes = importer.importNV12(input.pixelBuffer) else {
            throw PlaybackError(kind: .render(.memoryLimit),
                                causeDescription: "NV12 → MTLTexture 取り込み不可（layout 外）",
                                recovery: .retryWith(.bypassStage(StageID.colorConvert)),
                                userMessage: "この pixel layout は GPU に取り込めません")
        }
        var yTex = planes[0].texture
        var uvTex = planes[1].texture

        // 2. deinterlace（plan に段があり、source が interlaced のときだけ実行）
        var interimTextures: [any MTLTexture] = []
        if let req = plan.stage(of: .deinterlace), input.interlace.fieldCount >= 2 {
            let mode = resolveDeinterlace(req: req, input: input, timing: &timing)
            try encodeDeinterlace(mode: mode, fieldOrder: input.interlace.fieldOrder,
                                 y: yTex, uv: uvTex,
                                 into: &yTex, uvOut: &uvTex, interim: &interimTextures, command: command)
        }

        // 3. colorConvert（+ crop / letterbox / scale を同一 pass で）
        guard let cc = plan.stage(of: .colorConvert) else {
            throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                causeDescription: "plan に colorConvert 段が無い",
                                recovery: .giveUp(reason: "plan"),
                                userMessage: "色変換段のない plan は描けません")
        }
        guard let constants = ColorMatrixBuilder.resolve(color: input.color,
                                                        parameters: (cc.parameters as? ColorConvertParameters) ?? .init()) else {
            throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                causeDescription: "色変換行列を作れない（matrix 未解決）",
                                recovery: .needsUserAction(.chooseAspect),
                                userMessage: "色空間を決定できません")
        }
        timing.colorMatrixUsed = constants.matrixUsed
        timing.colorAssumptionApplied = constants.assumptionApplied

        let stageBegan = ContinuousClock.now
        try encodeColorConvert(constants: constants, aspect: input.aspect,
                              y: yTex, uv: uvTex, target: target, command: command)
        timing.stageEncodeMS.append((.colorConvert, msSince(stageBegan)))

        // 完了処理: pool 返却と CVMetalTexture の flush（GPU 使用後）。
        // addCompletedHandler は commit より前でなければならない（Metal の実測アサーション）。
        let imports = planes
        command.addCompletedHandler { [pool, importer] cb in
            for t in interimTextures { pool.release(t) }
            _ = imports   // CVMetalTexture の参照をここで手放す（texture は cb 完了まで生存済み）
            importer.flushUnretained()
            if let error = cb.error {
                completed?(.failure(PlaybackError(kind: .render(.drawableLost),
                                                  causeDescription: String(describing: error),
                                                  recovery: .retryWith(.lowerTier),
                                                  userMessage: "GPU 処理が完了しませんでした")), timing)
            } else {
                completed?(.success(()), timing)
            }
        }
        command.commit()
        timing.encodeTotalMS = msSince(began)
        return timing
    }

    // MARK: - auto / detector の解像（v1: declared 情報と safe 側で決める）
    //
    // 05 §5.2 の表どおり、progressive 素材は passthrough。interlaced 素材の mode 選択は
    // detector（05 §5.1）の実測判断が載るまで motionAdaptive → edge-directed で置く
    // （単一フレームのみで動く中間解。detector + motionAdaptive は同一 issue の次増分）。

    private func resolveDeinterlace(req: StageRequest, input: RenderFrameInput,
                                    timing: inout RenderTiming) -> DeinterlaceMode {
        let requested = (req.parameters as? DeinterlaceParameters)?.mode ?? .auto
        let declared = input.interlace.fieldCount >= 2
        if !declared {
            timing.deinterlaceApplied = .passthrough
            return .passthrough
        }
        let actual: DeinterlaceMode
        switch requested {
        case .passthrough: actual = .passthrough
        case .bob: actual = .bob
        case .edgeDirected, .motionAdaptive, .auto:
            actual = .edgeDirected   // v1 の safe 側実装（motionAdaptive は detector と共に入る）
        case .inverseTelecine:
            actual = .edgeDirected   // telecine 検出（CadenceAnalyzer）未実装の間の代替
        }
        timing.deinterlaceApplied = actual
        return actual
    }

    private func encodeDeinterlace(mode: DeinterlaceMode, fieldOrder: FieldOrder,
                                  y: any MTLTexture, uv: any MTLTexture,
                                  into yOut: inout any MTLTexture, uvOut: inout any MTLTexture,
                                  interim: inout [any MTLTexture],
                                  command: any MTLCommandBuffer) throws {
        switch mode {
        case .passthrough:
            return   // field をそのまま（weave）。源 texture をそのまま使う
        case .bob, .edgeDirected, .motionAdaptive, .auto, .inverseTelecine:
            break
        }
        let w = y.width, h = y.height
        guard let outY = pool.acquire(width: w, height: h, format: .r8Unorm,
                                      usage: [.shaderRead, .shaderWrite]),
              let outUV = pool.acquire(width: w / 2, height: h / 2, format: .rg8Unorm,
                                      usage: [.shaderRead, .shaderWrite]) else {
            throw PlaybackError(kind: .render(.memoryLimit),
                                recovery: .retryWith(.lowerTier),
                                userMessage: "中間テクスチャを確保できません")
        }
        interim.append(outY)
        interim.append(outUV)

        let functionName = switch mode {
        case .bob: "rv_deint_bob_v1"
        default: "rv_deint_edgeDirected_v1"
        }
        var constants: MTLFunctionConstantValues?
        var variant = ""
        if functionName == "rv_deint_bob_v1" {
            // field 順序を function constant で渡す（bottom-first 素材は上 field が奇数列 —
            // 04 §3 の PCE 実測。PSO 再作成は field 順序が変わるときだけ）。
            let cv = MTLFunctionConstantValues()
            let topFirst = fieldOrder != .bottomFirst   // .unknown は top-first 仮定（記録は deint 側の診断へ）
            var flag = topFirst
            cv.setConstantValue(&flag, type: .bool, index: 0)
            constants = cv
            variant = "topFirst=\(topFirst)"
        }
        let pso = try context.computePipeline(function: functionName, constants: constants,
                                              variant: variant, label: functionName)
        let stageBegan = ContinuousClock.now
        guard let enc = command.makeComputeCommandEncoder() else {
            throw PlaybackError(kind: .render(.deviceUnavailable),
                                recovery: .retryWith(.lowerTier), userMessage: "encoder を作れません")
        }
        enc.setComputePipelineState(pso)
        enc.setTexture(y, index: 0)
        enc.setTexture(uv, index: 1)
        enc.setTexture(outY, index: 2)
        enc.setTexture(outUV, index: 3)
        let threads = MTLSize(width: w, height: h, depth: 1)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        enc.dispatchThreads(threads, threadsPerThreadgroup: group)
        enc.endEncoding()
        // timing には載せない（deint の CPU 投入は 1 dispatch だけ。実測の表は
        // colorConvert 段と合わせて end-to-end で取る — 04 §9 と同じ運用）
        yOut = outY
        uvOut = outUV
        _ = stageBegan
    }

    // MARK: colorConvert + crop/letterbox/scale（単一 pass）

    struct ColorParams {
        var m: (Float, Float, Float, Float, Float, Float, Float, Float, Float) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0)
        var b: (Float, Float, Float) = (0, 0, 0)
        var sourceRect: (Float, Float, Float, Float) = (0, 0, 1, 1)
        var destRect: (Float, Float, Float, Float) = (0, 0, 1, 1)
    }

    /// 設計の計算（05 §6）: buffer の寸法は変えず、geometry で出す。
    /// - sourceRect = cleanAperture の uv 領域（分母は coded size。704 を 720 に引き伸ばさない）
    /// - destRect = 出力内 letterbox（target 寸法と targetDAR に合う最大の矩形。引き伸ばさない）
    static func geometry(aspect: AspectResolution, codedWidth: Int, codedHeight: Int,
                         targetWidth: Int, targetHeight: Int)
        -> (source: (Float, Float, Float, Float), dest: (Float, Float, Float, Float)) {
        let ca = aspect.cleanAperture
        let fullW = Double(max(codedWidth, 1)), fullH = Double(max(codedHeight, 1))
        // cleanAperture が coded size を超える入力は uv [0,1] に切る（異常メタデータの自己防衛）
        let src = (Float(Double(ca.x) / fullW), Float(Double(ca.y) / fullH),
                   Float(min(Double(ca.width), fullW) / fullW),
                   Float(min(Double(ca.height), fullH) / fullH))
        let dar = aspect.targetDAR.value   // 表示目標比率
        guard dar > 0, targetWidth > 0, targetHeight > 0 else {
            return (src, (0, 0, 1, 1))
        }
        let targetAspect = Double(targetWidth) / Double(targetHeight)
        var w = 1.0, h = 1.0
        if targetAspect > dar {
            w = dar / targetAspect         // 横に余白（pillarbox）
        } else {
            h = targetAspect / dar         // 縦に余白（letterbox）
        }
        let x = (1.0 - w) / 2.0, y = (1.0 - h) / 2.0
        // uv 系は「行 0 = 画面上部」で統一（rv_vs_fullscreen が y を反転して揃える — 実測）。
        // sourceRect の ca.y は画像上端からのオフセット、destRect は中心寄せなので
        // 上下原点の選び方と無関係に正しい（反転整合の検査は MetalPipelineTests）。
        return (src, (Float(x), Float(y), Float(w), Float(h)))
    }

    private func encodeColorConvert(constants matrix: YCbCrToRGBConstants,
                                   aspect: AspectResolution,
                                   y: any MTLTexture, uv: any MTLTexture,
                                   target: any MTLTexture,
                                   command: any MTLCommandBuffer) throws {
        let pso = try context.renderPipeline(vertex: "rv_vs_fullscreen",
                                             fragment: "rv_colorConvert_v1",
                                             colorFormat: target.pixelFormat,
                                             label: "colorConvert_v1")
        var p = ColorParams()
        p.m = (matrix.m[0], matrix.m[1], matrix.m[2],
               matrix.m[3], matrix.m[4], matrix.m[5],
               matrix.m[6], matrix.m[7], matrix.m[8])
        p.b = (matrix.b[0], matrix.b[1], matrix.b[2])
        let geo = Self.geometry(aspect: aspect, codedWidth: y.width, codedHeight: y.height,
                               targetWidth: target.width, targetHeight: target.height)
        p.sourceRect = geo.source
        p.destRect = geo.dest

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear   // letterbox 側は clear（黒）
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw PlaybackError(kind: .render(.deviceUnavailable),
                                recovery: .retryWith(.lowerTier), userMessage: "encoder を作れません")
        }
        enc.setRenderPipelineState(pso)
        enc.setFragmentBytes(&p, length: MemoryLayout<ColorParams>.stride, index: 0)
        enc.setFragmentTexture(y, index: 0)
        enc.setFragmentTexture(uv, index: 1)
        enc.setFragmentSamplerState(context.sampler(minFilterNearest: false), index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func msSince(_ mark: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - mark
        return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1_000
    }
}
