import CoreML
import CoreVideo
import Foundation
import RVMediaCore

// MARK: - Core ML 実行層（06 §3）
//
// モデルは `<modelsDirectory>/<name>/model.json`（ModelManifest）+ コンパイル済み `.mlmodelc`。
// 入出力は方針 A（06 §4）: CVPixelBuffer を image 特徴として渡し、出力も pixel buffer で受ける。
// 失敗は再生に波及させない（INV-1）: すべて `PlaybackError.model(...)` の値で返し、
// breaker（06 §6）が連続失敗でこのモデルの使用を止める。load は plan 生成の同期経路では呼ばない。

public actor CoreMLModelRuntime: ModelRuntimeProtocol {
    public struct Options: Sendable {
        /// `measuredOn` / `expectedLatencyMS` の無いモデルを実行しない（G3 の運用ルール）。
        /// 契約検査用の tiny model だけ false にする。
        public var requireMeasurement: Bool
        public var breaker: FailureBreaker.Config
        public init(requireMeasurement: Bool = true, breaker: FailureBreaker.Config = .init()) {
            self.requireMeasurement = requireMeasurement
            self.breaker = breaker
        }
    }

    private struct Entry {
        var manifest: ModelManifest
        var directory: URL
    }

    /// MLModel は Sendable 注釈が無い。prediction は actor の外で走るので箱に入れて渡す
    /// （MLModel の prediction はスレッドセーフと文書化されている）。
    private struct ModelBox: @unchecked Sendable { let model: MLModel }

    private let modelsDirectory: URL
    private let options: Options
    private var entries: [ModelID: Entry] = [:]
    private var loaded: [ModelID: MLModel] = [:]
    private var health: [ModelID: ModelHealthTracker] = [:]

    public init(modelsDirectory: URL, options: Options = .init()) {
        self.modelsDirectory = modelsDirectory
        self.options = options
    }

    private static func seconds() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: discover

    /// models ディレクトリの manifest（`<name>/model.json`）を列挙する。読めない manifest は無視する
    /// （壊れたモデルが他のモデルの発見を妨げない）。
    public func discover() -> [ModelManifest] {
        entries.removeAll()
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [ModelManifest] = []
        for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let json = dir.appendingPathComponent("model.json")
            guard let data = try? Data(contentsOf: json),
                  let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else { continue }
            entries[manifest.modelID] = Entry(manifest: manifest, directory: dir)
            found.append(manifest)
        }
        return found
    }

    // MARK: load / unload

    public func load(_ id: ModelID) async throws {
        if entries[id] == nil { _ = discover() }
        guard let entry = entries[id] else {
            throw PlaybackError.model(.notCompiled, message: "モデルが見つかりません: \(id)")
        }
        if options.requireMeasurement {
            if entry.manifest.measuredOn == nil || entry.manifest.expectedLatencyMS.p95 <= 0 {
                throw PlaybackError.model(.runtimeFailure,
                                          message: "計測記録（measuredOn / expectedLatencyMS）が無いモデルは実行しません",
                                          recovery: .giveUp(reason: "model-unmeasured"))
            }
        }
        let url = entry.directory.appendingPathComponent(entry.manifest.compiledModel)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.model(.notCompiled, message: "コンパイル済みモデルがありません: \(entry.manifest.compiledModel)")
        }
        let config = MLModelConfiguration()
        config.computeUnits = Self.computeUnits(for: entry.manifest.computeUnitsPreference)
        do {
            loaded[id] = try await MLModel.load(contentsOf: url, configuration: config)
        } catch {
            throw PlaybackError.model(.conversionUnsupported, message: "モデルを読み込めません",
                                      cause: String(describing: error))
        }
        if health[id] == nil {
            health[id] = ModelHealthTracker(breaker: FailureBreaker(config: options.breaker))
        }
    }

    public func unload(_ id: ModelID) {
        loaded[id] = nil   // in-flight は actor が直列化するので、ここへ来た時点で走っている推論は無い
    }

    public func isLoaded(_ id: ModelID) -> Bool { loaded[id] != nil }

    private static func computeUnits(for preference: ModelManifest.ComputeUnitsPreference) -> MLComputeUnits {
        switch preference {
        case .automatic: .all
        case .anePreferredWithGpuFallback: .cpuAndNeuralEngine
        case .gpuOnly: .cpuAndGPU
        case .cpuOnly: .cpuOnly
        }
    }

    // MARK: predict

    public func predict(_ request: InferenceRequest, input: InferenceFrame) async throws -> InferenceFrame {
        guard let model = loaded[request.model], let entry = entries[request.model] else {
            throw PlaybackError.model(.notCompiled, message: "モデルが load されていません: \(request.model)")
        }
        var tracker = health[request.model] ?? ModelHealthTracker(breaker: FailureBreaker(config: options.breaker))
        guard tracker.allowRequest(atSeconds: Self.seconds()) else {
            health[request.model] = tracker
            throw PlaybackError.model(.disabledByBreaker, message: "連続失敗のため AI 処理を一時停止しています",
                                      recovery: .retryWith(.lowerTier))
        }
        let spec = entry.manifest.input
        let width = CVPixelBufferGetWidth(input.pixelBuffer)
        let height = CVPixelBufferGetHeight(input.pixelBuffer)
        guard width == spec.width, height == spec.height else {
            // shape 不一致は plan（tile 設定）の誤りで、モデルの不調ではない: breaker に数えない。
            // half-open の試行枠を握ったままにしないよう、結果を「成功」扱いで返却する。
            if tracker.breaker.state == .halfOpen { tracker.recordSuccess(latencyMS: 0, atSeconds: Self.seconds()) }
            health[request.model] = tracker
            throw PlaybackError.model(.shapeMismatch,
                                      message: "入力寸法がモデルと一致しません（\(width)x\(height) / 必要 \(spec.width)x\(spec.height)）",
                                      recovery: .retryWith(.lowerTier))
        }

        let started = HostTime.now()
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                spec.name: MLFeatureValue(pixelBuffer: input.pixelBuffer)
            ])
            let box = ModelBox(model: model)
            let result = try await box.model.prediction(from: provider)
            guard let outBuffer = result.featureValue(for: entry.manifest.output.name)?.imageBufferValue else {
                throw PlaybackError.model(.runtimeFailure, message: "モデルの出力が pixel buffer ではありません")
            }
            let elapsedMS = HostTime.now().ms(since: started)
            tracker.recordSuccess(latencyMS: elapsedMS, atSeconds: Self.seconds())
            health[request.model] = tracker
            if HostTime.now() > request.deadline {
                // 結果は捨てる（古い画像を保持するとフリーズに見える — 06 §3）。モデルの不調ではないので breaker は動かさない。
                throw PlaybackError.model(.deadlineExceeded, message: "推論が期限に間に合いませんでした",
                                          recovery: .retryWith(.lowerTier))
            }
            return InferenceFrame(outBuffer)
        } catch let error as PlaybackError {
            if case .model(.deadlineExceeded) = error.kind { throw error }
            tracker.recordFailure(atSeconds: Self.seconds())
            health[request.model] = tracker
            throw error
        } catch {
            tracker.recordFailure(atSeconds: Self.seconds())
            health[request.model] = tracker
            throw PlaybackError.model(.runtimeFailure, message: "推論に失敗しました", cause: String(describing: error))
        }
    }

    public func health(of id: ModelID) -> ModelHealth {
        health[id]?.health ?? ModelHealth()
    }
}
