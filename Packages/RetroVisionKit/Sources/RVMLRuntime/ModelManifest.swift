import Foundation
import RVMediaCore

// MARK: - モデル契約（06 §2）
//
// モデルの version・license・入力寸法・精度・実行設定を 1 つの manifest に集約する。
// `measuredOn` が無いモデルは実行しない（G3 の運用ルール）。

public struct ModelManifest: Codable, Sendable, Hashable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var revision: String
    public var displayName: String
    public var task: Task
    public var scaleFactor: Int
    public var license: License
    public var compiledModel: String
    public var checksum: String
    public var input: TensorSpec
    public var output: TensorSpec
    public var constraints: Constraints
    public var computeUnitsPreference: ComputeUnitsPreference
    public var variantGroup: String?
    public var memoryEstimateMB: Double
    public var expectedLatencyMS: Latency
    public var measuredOn: Measurement?

    public var modelID: ModelID { ModelID("\(id)@\(revision)") }
    public var identifier: String { id }

    public enum Task: String, Codable, Sendable { case superResolution, denoise, restoration, unknown }

    public struct License: Codable, Sendable, Hashable {
        public var spdx: String
        public var weightsLicense: String?
        /// 出力の利用権（自作パイプラインでの処理・表示）を確認済みか。false ならリリースビルドで警告。
        public var outputRightsConfirmed: Bool
        public var noticeTextPath: String?
        public init(spdx: String, weightsLicense: String? = nil, outputRightsConfirmed: Bool = false,
                    noticeTextPath: String? = nil) {
            self.spdx = spdx; self.weightsLicense = weightsLicense
            self.outputRightsConfirmed = outputRightsConfirmed; self.noticeTextPath = noticeTextPath
        }
    }

    public struct TensorSpec: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case image, tensor }
        public enum DataType: String, Codable, Sendable { case float16, float32 }

        public var name: String
        public var kind: Kind
        public var width: Int
        public var height: Int
        public var pixelFormat: String
        public var dataType: DataType
        public var normalization: Normalization?

        public struct Normalization: Codable, Sendable, Hashable {
            public var mean: [Double]
            public var scale: Double
            public init(mean: [Double], scale: Double) { self.mean = mean; self.scale = scale }
        }

        public init(name: String, kind: Kind, width: Int, height: Int, pixelFormat: String,
                    dataType: DataType, normalization: Normalization? = nil) {
            self.name = name; self.kind = kind; self.width = width; self.height = height
            self.pixelFormat = pixelFormat; self.dataType = dataType; self.normalization = normalization
        }
    }

    public struct Constraints: Codable, Sendable, Hashable {
        public var multipleOf: Int
        public var maxPixels: Int
        public var allowsDynamicShape: Bool
        public init(multipleOf: Int = 16, maxPixels: Int = 4_194_304, allowsDynamicShape: Bool = false) {
            self.multipleOf = multipleOf; self.maxPixels = maxPixels
            self.allowsDynamicShape = allowsDynamicShape
        }
    }

    public enum ComputeUnitsPreference: String, Codable, Sendable {
        case automatic, anePreferredWithGpuFallback, gpuOnly, cpuOnly
    }

    public struct Latency: Codable, Sendable, Hashable {
        public var p50: Double
        public var p95: Double
        public init(p50: Double, p95: Double) { self.p50 = p50; self.p95 = p95 }
    }

    public struct Measurement: Codable, Sendable, Hashable {
        public var device: String
        public var os: String
        public var date: String
        public var reportPath: String?
        public init(device: String, os: String, date: String, reportPath: String? = nil) {
            self.device = device; self.os = os; self.date = date; self.reportPath = reportPath
        }
    }

    public init(schemaVersion: Int = ModelManifest.schemaVersion, id: String, revision: String,
                displayName: String, task: Task, scaleFactor: Int = 2, license: License,
                compiledModel: String, checksum: String, input: TensorSpec, output: TensorSpec,
                constraints: Constraints = .init(),
                computeUnitsPreference: ComputeUnitsPreference = .automatic,
                variantGroup: String? = nil, memoryEstimateMB: Double = 0,
                expectedLatencyMS: Latency, measuredOn: Measurement? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.displayName = displayName
        self.task = task
        self.scaleFactor = scaleFactor
        self.license = license
        self.compiledModel = compiledModel
        self.checksum = checksum
        self.input = input
        self.output = output
        self.constraints = constraints
        self.computeUnitsPreference = computeUnitsPreference
        self.variantGroup = variantGroup
        self.memoryEstimateMB = memoryEstimateMB
        self.expectedLatencyMS = expectedLatencyMS
        self.measuredOn = measuredOn
    }

    /// manifest の検査。通らなかった項目は list で返す（CI で機械検査。06 §2）。
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if schemaVersion != Self.schemaVersion { problems.append("schemaVersion \(schemaVersion) は未対応") }
        if id.isEmpty || revision.isEmpty { problems.append("id / revision が必要") }
        if measuredOn == nil { problems.append("measuredOn が無いモデルは実行できない（G3）") }
        if expectedLatencyMS.p95 <= 0 { problems.append("expectedLatencyMS が無い") }
        if input.width <= 0 || input.height <= 0 { problems.append("入力寸法が不正") }
        if output.width < input.width || output.height < input.height, task == .superResolution {
            problems.append("superResolution なのに出力が入力より小さい")
        }
        if !license.outputRightsConfirmed { problems.append("出力の利用権未確認（開発ビルドのみで動く）") }
        return problems
    }
}

// MARK: - 実行層の契約（06 §3）

public struct InferenceRequest: Sendable {
    public let model: ModelID
    public let width: Int
    public let height: Int
    public let frameID: FrameID
    public let deadline: HostTime
    public init(model: ModelID, width: Int, height: Int, frameID: FrameID, deadline: HostTime) {
        self.model = model; self.width = width; self.height = height
        self.frameID = frameID; self.deadline = deadline
    }
}

public struct ModelHealth: Sendable, Hashable {
    public var p50MS: Double
    public var p95MS: Double
    public var failureRatio: Double
    public var breakerState: BreakerState

    public enum BreakerState: String, Sendable { case closed, open, halfOpen }
    public init(p50MS: Double = 0, p95MS: Double = 0, failureRatio: Double = 0,
                breakerState: ModelHealth.BreakerState = .closed) {
        self.p50MS = p50MS; self.p95MS = p95MS; self.failureRatio = failureRatio; self.breakerState = breakerState
    }
}

public protocol ModelRuntimeProtocol: Sendable {
    func discover() async -> [ModelManifest]
    func load(_ id: ModelID) async throws
    func unload(_ id: ModelID) async
    func predict(_ request: InferenceRequest) async throws
    func health(of id: ModelID) async -> ModelHealth
}
