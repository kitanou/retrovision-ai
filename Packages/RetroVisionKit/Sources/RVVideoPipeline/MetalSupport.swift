import CoreVideo
import Foundation
import Metal
import RVMediaCore

// MARK: - Metal 実行系の土台（05 §2 の取り込み・§9 の PSO/ライブラリ管理）
//
// 設計どおりの配置:
// - device は 1 個（`MTLCreateSystemDefaultDevice`）。取得できない場合は
//   `deviceUnavailable`（01 §5 の recovery: .lowerTier / .disableStage へ倒す）。
// - シェーダは `MetalShaders.source` を 1 回コンパイル（05 §9。失敗は
//   `pipelineCompileFailed` — コンパイラ診断メッセージを causeDescription に残す）。
// - PSO は `RenderContext` が stage + variant（+ function constants）単位で cache する。
// - 取り込みは CVMetalTextureCache（05 §2 の zero-copy）。復号 pool が Metal 互換属性で
//   作られていることを前提にする（04 §3。無ければ `formatRejected` 相当で落とす）。

public final class MetalRenderContext: @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    let library: any MTLLibrary

    private let lock = NSLock()
    private var renderPipelines: [String: any MTLRenderPipelineState] = [:]
    private var computePipelines: [String: any MTLComputePipelineState] = [:]
    private var samplerNearest: (any MTLSamplerState)?
    private var samplerLinear: (any MTLSamplerState)?

    public init(device: (any MTLDevice)? = nil) throws {
        let d = device ?? MTLCreateSystemDefaultDevice()
        guard let d else {
            throw PlaybackError(kind: .render(.deviceUnavailable),
                                recovery: .retryWith(.lowerTier),
                                userMessage: "GPU デバイスを取得できません")
        }
        self.device = d
        guard let q = d.makeCommandQueue() else {
            throw PlaybackError(kind: .render(.deviceUnavailable),
                                recovery: .retryWith(.lowerTier),
                                userMessage: "コマンド キューを作成できません")
        }
        self.commandQueue = q
        do {
            let options = MTLCompileOptions()
            self.library = try d.makeLibrary(source: MetalShaders.source, options: options)
        } catch {
            throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                causeDescription: String(describing: error),
                                recovery: .giveUp(reason: "shader compile"),
                                userMessage: "シェーダのコンパイルに失敗しました")
        }
    }

    // MARK: PSO cache（05 §9: stage_variant + function constants の key）

    func renderPipeline(vertex: String, fragment: String,
                        colorFormat: MTLPixelFormat,
                        label: String) throws -> any MTLRenderPipelineState {
        let key = "r:\(vertex)|\(fragment):\(colorFormat.rawValue)"
        if let pso = lock.withLock({ renderPipelines[key] }) { return pso }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = try function(named: vertex)
        desc.fragmentFunction = try function(named: fragment)
        desc.colorAttachments[0].pixelFormat = colorFormat
        let pso: any MTLRenderPipelineState
        do {
            pso = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                causeDescription: String(describing: error),
                                recovery: .giveUp(reason: "pso"),
                                userMessage: "描画パイプラインを作成できません")
        }
        lock.withLock { renderPipelines[key] = pso }
        return pso
    }

    func computePipeline(function: String, constants: MTLFunctionConstantValues? = nil,
                         variant: String = "", label: String) throws -> any MTLComputePipelineState {
        let fn: any MTLFunction
        if let constants {
            do {
                fn = try library.makeFunction(name: function, constantValues: constants)
            } catch {
                throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                    causeDescription: String(describing: error),
                                    recovery: .giveUp(reason: "pso"),
                                    userMessage: "コンピュート パイプラインを作成できません")
            }
        } else {
            fn = try self.function(named: function)
        }
        // cache key には function constant の値を識別する文字列を必ず載せる
        // （MTLFunctionConstantValues は読み戻せないので、呼び出し側が determiner を渡す — 05 §9）。
        let key = "c:\(function):\(constants == nil ? "plain" : "fc[\(variant)]")"
        if let pso = lock.withLock({ computePipelines[key] }) { return pso }
        let pso: any MTLComputePipelineState
        do {
            pso = try device.makeComputePipelineState(function: fn)
        } catch {
            throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                causeDescription: String(describing: error),
                                recovery: .giveUp(reason: "pso"),
                                userMessage: "コンピュート パイプラインを作成できません")
        }
        lock.withLock { computePipelines[key] = pso }
        return pso
    }

    private func function(named name: String) throws -> any MTLFunction {
        guard let f = library.makeFunction(name: name) else {
            throw PlaybackError(kind: .render(.pipelineCompileFailed),
                                causeDescription: "function \(name) not found",
                                recovery: .giveUp(reason: "shader function"),
                                userMessage: "シェーダ関数がありません: \(name)")
        }
        return f
    }

    // MARK: sampler（nearest / linear。ScaleParameters.filter の受け口）

    func sampler(minFilterNearest: Bool) -> any MTLSamplerState {
        lock.withLock {
            if minFilterNearest {
                if let s = samplerNearest { return s }
                let s = makeSampler(nearest: true)
                samplerNearest = s
                return s
            } else {
                if let s = samplerLinear { return s }
                let s = makeSampler(nearest: false)
                samplerLinear = s
                return s
            }
        }
    }

    private func makeSampler(nearest: Bool) -> any MTLSamplerState {
        let d = MTLSamplerDescriptor()
        d.minFilter = nearest ? .nearest : .linear
        d.magFilter = nearest ? .nearest : .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        // makeSamplerDescriptor は失敗し得る（rare）。標準設定で失敗しない前提で ok。
        return device.makeSamplerState(descriptor: d)!
    }
}

// MARK: - 取り込み（05 §2 zero-copy）

/// CVPixelBuffer → MTLTexture（平面単位）。CVMetalTexture の参照は frame の生存中
/// 保持する必要がある（texture の背後に CV 引用がある）— `FrameImport` がまとめて持つ。
public final class PixelBufferImporter: @unchecked Sendable {
    private let context: MetalRenderContext
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()
    /// BGRA 取り込み（RGBBridge）が使う同じ cache。
    var textureCache: CVMetalTextureCache? { lock.withLock { cache } }

    public init(context: MetalRenderContext) throws {
        self.context = context
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw PlaybackError(kind: .render(.memoryLimit),
                                recovery: .retryWith(.lowerTier),
                                userMessage: "テクスチャ キャッシュを作成できません")
        }
        self.cache = cache
    }

    public struct Plane {
        public var texture: any MTLTexture
        let cvTexture: CVMetalTexture
    }

    /// NV12（420v/f Both planes）を Y(r8Unorm) + UV(rg8Unorm) として取り込む。
    /// 対応しない layout は nil（呼び出し側が `formatRejected` 相当で処理 — 05 §2）。
    public func importNV12(_ pixelBuffer: CVPixelBuffer) -> [Plane]? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        guard let cache = lock.withLock({ cache }) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var planes: [Plane] = []
        var cvY: CVMetalTexture?
        let s1 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer,
                                                           nil, .r8Unorm, w, h, 0, &cvY)
        var cvUV: CVMetalTexture?
        let s2 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer,
                                                           nil, .rg8Unorm, w / 2, h / 2, 1, &cvUV)
        guard s1 == kCVReturnSuccess, s2 == kCVReturnSuccess,
              let cvY, let cvUV,
              let tY = CVMetalTextureGetTexture(cvY), let tUV = CVMetalTextureGetTexture(cvUV)
        else { return nil }
        planes.append(Plane(texture: tY, cvTexture: cvY))
        planes.append(Plane(texture: tUV, cvTexture: cvUV))
        return planes
    }

    /// 使用中の CVMetalTexture を解放可能にする（GPU 使用終了後に行う — 01 §4 の
    /// lease と同じ運用。RenderGraph 側が完了時に呼ぶ）。
    public func flushUnretained() {
        guard let cache = lock.withLock({ cache }) else { return }
        CVMetalTextureCacheFlush(cache, 0)
    }
}

// MARK: - 中间テクスチャの再利用（05 §1 TexturePool の最小形）
//
/// 寸法・フォーマット単位の再利用。in-flight 上限ぶんしか必要無い（00 §5）。
/// lease 違反（使用中の再利用）は上書きせず新規確保 + 診断、の方針は #6/#7 の
/// 中间帧が増える時点で本実装にする（Phase 2 の deint/color 段階では 1 組で回る）。
final class TexturePool {
    private let context: MetalRenderContext
    private var free: [String: [any MTLTexture]] = [:]
    let lock = NSLock()

    init(context: MetalRenderContext) { self.context = context }

    func acquire(width: Int, height: Int, format: MTLPixelFormat,
                 usage: MTLTextureUsage) -> (any MTLTexture)? {
        let key = "\(width)x\(height):\(format.rawValue):\(usage.rawValue)"
        let pooled = lock.withLock { free[key]?.popLast() }
        if let pooled { return pooled }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                         width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        return context.device.makeTexture(descriptor: d)
    }

    func release(_ texture: any MTLTexture) {
        let key = "\(texture.width)x\(texture.height):\(texture.pixelFormat.rawValue):\(texture.usage.rawValue)"
        lock.withLock {
            var list = free[key] ?? []
            if list.count < 4 {   // 上限ぶんだけ積む（無限保持しない）
                list.append(texture)
                free[key] = list
            }
        }
    }
}
