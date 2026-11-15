import Foundation

// MARK: - トラックと選択（01 §3）

public struct TrackID: Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt32
    /// 0 は予約（none）。
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = TrackID(0)
    public var description: String { "track:\(rawValue)" }
}

public struct ItemID: Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "item:\(rawValue)" }
}

public enum TrackKind: UInt8, Sendable, CaseIterable {
    case video, audio, subtitle, data
}

public struct TrackInfo: Sendable, Hashable, Identifiable {
    public var id: TrackID
    public var kind: TrackKind
    /// BCP-47 に正規化済み（DVD の 3 文字 code から変換して持つ）。
    public var language: String?
    public var name: String?
    public var format: FormatDescription
    public var isDefault: Bool
    public var isForced: Bool
    /// DVD の associated-sub-picture 制御（03 §3）。
    public var associatedSubtitleTrack: TrackID?

    public init(id: TrackID, kind: TrackKind, language: String? = nil, name: String? = nil,
                format: FormatDescription, isDefault: Bool = false, isForced: Bool = false,
                associatedSubtitleTrack: TrackID? = nil) {
        self.id = id
        self.kind = kind
        self.language = language
        self.name = name
        self.format = format
        self.isDefault = isDefault
        self.isForced = isForced
        self.associatedSubtitleTrack = associatedSubtitleTrack
    }
}

public enum SubtitleChoice: Sendable, Hashable {
    case off
    /// 言語設定と associated-sub-picture 規則に従って自動選択。
    case auto
    case specific(TrackID)
}

public struct PlaybackSelection: Sendable, Hashable {
    public var item: ItemID
    public var audio: TrackID?
    public var subtitle: SubtitleChoice
    /// 07 §6 の policy を保持するが、RVMediaCore はその詳細を知らない（境界は RVEnhancement 側で決める）。
    /// ここでは「オフか、そうではないか」だけを表す最小値を持たないマーカーは使わない。
    public var enhancementEnabled: Bool

    public init(item: ItemID, audio: TrackID? = nil, subtitle: SubtitleChoice = .auto,
                enhancementEnabled: Bool = true) {
        self.item = item
        self.audio = audio
        self.subtitle = subtitle
        self.enhancementEnabled = enhancementEnabled
    }
}

public enum StepDirection: Sendable { case backward, forward }

public enum SeekTolerance: Sendable, Hashable {
    /// 意図的に既定にしない（デコードコストが跳ね上がるため。04 §1）。
    case exact
    /// 目標位置より前の keyframe まで。既定（01 §1）。
    case previousKeyframe
    /// ± MediaTime の幅を許す。
    case near(MediaTime)

    public static let `default`: SeekTolerance = .previousKeyframe
}

// MARK: - 品質段階と設定の境界（07 §1、08）

public enum QualityTier: Int, Sendable, Comparable, CaseIterable, Codable {
    case off = 0
    case metalOnly = 1
    case lightML = 2
    case fullML = 3

    public static func < (lhs: QualityTier, rhs: QualityTier) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .off: return "オフ"
        case .metalOnly: return "標準（AI なし）"
        case .lightML: return "軽量 AI"
        case .fullML: return "最高品質"
        }
    }

    /// 計測・レポートで使う機械可読名（08 §7）。UI 表示には `displayName` を使う。
    public var metricName: String {
        switch self {
        case .off: return "off"
        case .metalOnly: return "metalOnly"
        case .lightML: return "lightML"
        case .fullML: return "fullML"
        }
    }
}

/// 降格が起きた理由。UI 表示と診断の両方で使う（08 §6）。
public enum DegradeReason: String, Sendable, CaseIterable {
    case loadHigh
    case thermal
    case memory
    case modelFailure
    case displayMismatch
    case userRequested
}

public enum DeinterlaceMode: String, Sendable, CaseIterable {
    case auto
    case passthrough
    case bob
    case edgeDirected
    case motionAdaptive
    case inverseTelecine
}
