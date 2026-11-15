import Foundation

// MARK: - エラー体系（01 §5）
//
// メディア由来の失敗は例外ではなく値で扱い、回復方針を必ず添える。

public struct PlaybackError: Error, Sendable, Hashable, CustomStringConvertible, Identifiable {
    public enum Kind: Sendable, Hashable {
        case source(SourceErrorKind)
        case decode(DecodeErrorKind)
        case render(RenderErrorKind)
        case model(ModelErrorKind)
        case cancelled
        case internalFailure(String)
    }

    public let id: UUID
    public let kind: Kind
    public let causeDescription: String?
    public let recovery: RecoveryAdvice
    public let userMessage: String
    /// 診断レコードを指す参照（08 §4）。
    public let diagnosticRef: String?

    public init(kind: Kind,
                causeDescription: String? = nil,
                recovery: RecoveryAdvice,
                userMessage: String,
                diagnosticRef: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.causeDescription = causeDescription
        self.recovery = recovery
        self.userMessage = userMessage
        self.diagnosticRef = diagnosticRef
    }

    public var description: String { userMessage }
}

public enum RecoveryAdvice: Sendable, Hashable {
    case retryWith(AlternativeStrategy)
    case needsUserAction(UserActionHint)
    case giveUp(reason: String)
}

public enum AlternativeStrategy: Sendable, Hashable {
    case softwareDecode
    case lowerTier
    case lighterModel
    case disableSubtitleRendering
    case bypassStage(StageID)
}

// MARK: - 構造の警告（03 §3）
//
// 「IFO と VOB の長さが食い違う」等を列挙する。core に置くのは、デコーダ側（ProbedStream）も
// 同じ型を使うため（00 §2 の依存規則に合わせる）。

public struct StructureWarning: Sendable, Hashable {
    public enum Code: String, Sendable, Codable {
        case ifoShorterThanVob, missingVOB, unreadableIFO, aspectMismatch,
             unknownAudioCodec, unsupportedSubtitleCodec
    }
    public let code: Code
    public let detail: String
    public init(code: Code, detail: String) { self.code = code; self.detail = detail }
}

public enum UserActionHint: String, Sendable, CaseIterable {
    case insertDisc
    case selectDifferentItem
    case grantPermission
    case updateMedia
    case chooseAspect
    case contactVendorAboutLicense
}

public enum SourceErrorKind: String, Sendable, CaseIterable {
    case notFound
    case unreadable
    case malformedStructure
    case unsupportedStructure
    case protectedNeedsLicense
    case mediaRemoved
    case permissionDenied
    case noDisc
}

public enum DecodeErrorKind: String, Sendable, CaseIterable {
    case unsupportedCodec
    case unsupportedProfile
    case hwDecodeUnavailable
    case corruptStream
    case bufferExhausted
    case formatRejected
}

public enum RenderErrorKind: String, Sendable, CaseIterable {
    case deviceUnavailable
    case pipelineCompileFailed
    case drawableLost
    case memoryLimit
}

public enum ModelErrorKind: String, Sendable, CaseIterable {
    case notCompiled
    case shapeMismatch
    case conversionUnsupported
    case deadlineExceeded
    case timeout
    case runtimeFailure
    case disabledByBreaker
}

// MARK: - 補助コンストラクタ

extension PlaybackError {
    public static func source(_ kind: SourceErrorKind, message: String,
                              recovery: RecoveryAdvice = .giveUp(reason: "source"),
                              cause: String? = nil) -> PlaybackError {
        PlaybackError(kind: .source(kind), causeDescription: cause, recovery: recovery, userMessage: message)
    }

    public static func decode(_ kind: DecodeErrorKind, message: String,
                              recovery: RecoveryAdvice = .giveUp(reason: "decode"),
                              cause: String? = nil) -> PlaybackError {
        PlaybackError(kind: .decode(kind), causeDescription: cause, recovery: recovery, userMessage: message)
    }

    public static func model(_ kind: ModelErrorKind, message: String,
                             recovery: RecoveryAdvice = .retryWith(.lowerTier),
                             cause: String? = nil) -> PlaybackError {
        PlaybackError(kind: .model(kind), causeDescription: cause, recovery: recovery, userMessage: message)
    }
}
