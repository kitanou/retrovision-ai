import Foundation
import RVMediaCore
import RVMediaSources
import RVDecode

// MARK: - ファイル source の MediaSource（03 §6 のファイル系、#11 の接続点）
//
// open() は「構造」（トラック表とフォーマット）を作る。再生の配線（demux/decode の生成）は
// Engine 側が持つ: OpenedSource は RVMediaSources の型で、RVMediaSources は RVDecode を
// import しない（00 §2 の依存規則）。そのため demuxer の取り出し口は makeDemuxer() として
// この型に置く（EngineCore が FileMediaSource を見たときだけ通る配線経路。DVD の配線は
// Phase 2 で同じ形のスロットに収める）。

public actor FileMediaSource: MediaSource {
    public let url: URL
    private var cachedDemuxer: AVFoundationDemuxer?

    public init(url: URL) { self.url = url }

    nonisolated public var descriptor: SourceDescriptor {
        SourceDescriptor(id: SourceID(Self.stableID(for: url.path)),
                         kind: .plainFile,
                         displayName: url.deletingPathExtension().lastPathComponent,
                         location: .fileURL(url))
    }

    public func open() async throws -> OpenedSource {
        let demuxer = AVFoundationDemuxer(url: url)
        self.cachedDemuxer = demuxer
        let stream = try await demuxer.probe()
        guard let video = stream.tracks.first(where: { $0.kind == .video }),
              case .video(let videoFormat) = video.format else {
            throw PlaybackError(kind: .source(.unreadable),
                                recovery: .giveUp(reason: "open"),
                                userMessage: "動画トラックが見つかりません")
        }
        let item = MediaItem(id: ItemID(1),
                             duration: stream.programDuration,
                             trackTable: stream.tracks,
                             videoFormat: videoFormat)
        let structure = MediaStructure(itemKind: .singleItem, items: [item], warnings: stream.warnings)
        return OpenedSource(reader: FileBlockReader(url: url),
                            structure: structure,
                            formatHint: Self.formatHint(url: url, stream: stream))
    }

    /// Engine 向けの配線口（上記コメント参照）。open() で probe 済みの demuxer を返す
    /// （新しい实例だと track id が対応しないため、必ず同じ实例を使う）。
    public func makeDemuxer() -> any Demuxer {
        if let cachedDemuxer { return cachedDemuxer }
        let demuxer = AVFoundationDemuxer(url: url)
        cachedDemuxer = demuxer
        return demuxer
    }

    /// パスから決定的な SourceID（FNV-1a。プロセス間・実行間で安定にしておく）。
    private static func stableID(for path: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func formatHint(url: URL, stream: ProbedStream) -> SourceFormatHint {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mkv": return .matroska
        case "mov", "mp4", "m4v": return .quickTime
        default:
            // MPEG-PS の映像サブタイプ（mp2v/mp1v）が見えていれば program stream 扱い。
            for track in stream.tracks where track.kind == .video {
                if case .video(let format) = track.format,
                   format.rawFormatType == FourCC.code("mp2v") || format.rawFormatType == FourCC.code("mp1v") {
                    return .mpegProgramStream
                }
            }
            return .unknown
        }
    }
}

// MARK: - ファイルの BlockReader（OpenedSource の契約充足用）

/// 論理 2048 バイト単位で読む。AVFoundation 経路では demux に使わないが、
/// 「メディアが消えた」検出（03 §6・mediaRemoved）と診断のために常設する。
public struct FileBlockReader: BlockReader {
    public let blockCount: Int64
    public let blockSize: Int32 = 2_048
    private let url: URL

    public init(url: URL) {
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        self.blockCount = size / Int64(2_048)
    }

    public func read(block: Int64, count: Int32) throws -> Data {
        let handle = FileHandle(forReadingAtPath: url.path)
        guard let handle else {
            throw PlaybackError.source(.mediaRemoved, message: "メディアを読み取れません",
                                       recovery: .needsUserAction(.insertDisc))
        }
        defer { try? handle.close() }
        let start = block * Int64(blockSize)
        try handle.seek(toOffset: UInt64(start))
        let length = Int(count) * Int(blockSize)
        guard let data = try handle.read(upToCount: length), !data.isEmpty else {
            throw PlaybackError.source(.mediaRemoved, message: "メディアを読み取れません",
                                       recovery: .needsUserAction(.insertDisc))
        }
        return data
    }

    public func prefetch(block: Int64, count: Int32) {}

    public func invalidate() {}
}
