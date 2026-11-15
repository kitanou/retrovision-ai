import Foundation
import RVMediaCore

// MARK: - ソース抽象（03 §1、§2）
//
// optical / VIDEO_TS folder / ISO / 一般ファイルの差は「ブロックを読む方法」と
// 「構造の作り方」に閉じ込める。上位（Demuxer・Engine）は Disc の意味を知らない。

public protocol MediaSource: Sendable {
    var descriptor: SourceDescriptor { get }
    /// 開いて構造を作る。重い処理は内部の IO キューで実行する（INV-4）。
    func open() async throws -> OpenedSource
}

public struct SourceDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case opticalDisc, videoTsFolder, discImage, plainFile }

    public let id: SourceID
    public let kind: Kind
    public let displayName: String
    public let location: SourceLocation
    public var protectionHint: ProtectionHint

    public init(id: SourceID, kind: Kind, displayName: String, location: SourceLocation,
                protectionHint: ProtectionHint = .unknown) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.location = location
        self.protectionHint = protectionHint
    }
}

public struct SourceID: Sendable, Hashable, CustomStringConvertible {
    public var rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "source:\(rawValue)" }
}

public enum SourceLocation: Sendable, Hashable {
    case fileURL(URL)
    case directoryURL(URL)
    case blockDevice(path: String)
    /// sandbox / 外部 volume の再アクセス用（00 §9）。
    case securityScopedBookmark(Data)
}

public enum ProtectionHint: String, Sendable { case unknown, unprotected, protectedCSS, protectedAACS }

public struct OpenedSource: Sendable {
    public let reader: any BlockReader
    public let structure: MediaStructure
    public let formatHint: SourceFormatHint

    public init(reader: any BlockReader, structure: MediaStructure, formatHint: SourceFormatHint) {
        self.reader = reader
        self.structure = structure
        self.formatHint = formatHint
    }
}

public enum SourceFormatHint: String, Sendable { case mpegProgramStream, matroska, quickTime, unknown }

/// 読む単位は「ブロック番号 → blockSize バイト」に寄せる（03 §2）。
public protocol BlockReader: Sendable {
    var blockCount: Int64 { get }
    var blockSize: Int32 { get }
    /// 同期。demuxQueue からだけ呼ぶ（INV-4）。
    func read(block: Int64, count: Int32) throws -> Data
    func prefetch(block: Int64, count: Int32)
    func invalidate()
}

// MARK: - 構造モデル（03 §3）

public struct MediaStructure: Sendable, Hashable {
    public enum ItemKind: String, Sendable { case dvdTitles, playlist, singleItem, unknown }

    public let itemKind: ItemKind
    public var items: [MediaItem]
    /// 「IFO と VOB の長さが食い違う」等を列挙する（#3 の受入基準）。
    public var warnings: [StructureWarning]

    public init(itemKind: ItemKind, items: [MediaItem], warnings: [StructureWarning] = []) {
        self.itemKind = itemKind
        self.items = items
        self.warnings = warnings
    }
}

public struct MediaItem: Sendable, Hashable, Identifiable {
    public let id: ItemID
    public var titleNumber: Int?
    public var partNumber: Int?
    public var duration: MediaTime?
    public var trackTable: [TrackInfo]
    public var videoFormat: VideoFormatDescription?
    public var chapters: [ChapterMark]
    public var angles: [AngleInfo]
    public var stillImage: Bool
    public var aspectFlag: AspectSignals.DVDAspectFlag?

    public init(id: ItemID, titleNumber: Int? = nil, partNumber: Int? = nil, duration: MediaTime? = nil,
                trackTable: [TrackInfo] = [], videoFormat: VideoFormatDescription? = nil,
                chapters: [ChapterMark] = [], angles: [AngleInfo] = [], stillImage: Bool = false,
                aspectFlag: AspectSignals.DVDAspectFlag? = nil) {
        self.id = id
        self.titleNumber = titleNumber
        self.partNumber = partNumber
        self.duration = duration
        self.trackTable = trackTable
        self.videoFormat = videoFormat
        self.chapters = chapters
        self.angles = angles
        self.stillImage = stillImage
        self.aspectFlag = aspectFlag
    }
}

public struct ChapterMark: Sendable, Hashable {
    public var index: Int
    public var start: MediaTime
    public var title: String?
    public init(index: Int, start: MediaTime, title: String? = nil) {
        self.index = index; self.start = start; self.title = title
    }
}

public struct AngleInfo: Sendable, Hashable {
    public var index: Int
    public init(index: Int) { self.index = index }
}

// MARK: - テスト用・仮の実装

/// メモリ上のブロック列。単体テストと CI で使う（09 §3）。
public struct MemoryBlockReader: BlockReader, @unchecked Sendable {
    public let blockCount: Int64
    public let blockSize: Int32
    private let bytes: Data
    private let invalidFlag = ManagedFlag()

    public init(bytes: Data, blockSize: Int32 = 2_048) {
        self.bytes = bytes
        self.blockSize = blockSize
        self.blockCount = Int64(bytes.count) / Int64(blockSize)
    }

    public func read(block: Int64, count: Int32) throws -> Data {
        if invalidFlag.isSet {
            throw PlaybackError.source(.mediaRemoved, message: "メディアが取り出されました",
                                       recovery: .needsUserAction(.insertDisc))
        }
        let start = Int(block) * Int(blockSize)
        let end = min(bytes.count, start + Int(count) * Int(blockSize))
        guard start >= 0, end > start else {
            throw PlaybackError.source(.unreadable, message: "ブロックを読み取れません",
                                       recovery: .giveUp(reason: "read"))
        }
        return bytes[start..<end]
    }

    public func prefetch(block: Int64, count: Int32) {}
    public func invalidate() { invalidFlag.set() }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
