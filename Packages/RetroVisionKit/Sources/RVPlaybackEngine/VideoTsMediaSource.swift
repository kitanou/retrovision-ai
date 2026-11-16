import Foundation
import RVMediaCore
import RVMediaSources
import RVDecode

// MARK: - DVD-Video（VIDEO_TS フォルダ）の MediaSource（03 §3、§4。#3）
//
// 構造（タイトル列）は VideoTsNavigator のファイル名走査で作り、トラック表と
// フォーマットは各チェーンの demuxer を open 時に probe して埋める
// （IFO 実パースが権威になるのは増分。v1 は VOB 側の実測で構成する — 03 §4 の
// 「IFO と VOB の長さが食い違う」を検出できる形にするため、ズレは warning で残す）。
//
// 多重 VOB（1 タイトル = VTS_nn_1..k.VOB）は ConcatPSDemuxer で 1 本のタイムラインに
// 連結して読む（03 §4。実装の実測根拠は ConcatPSDemuxer の頭注）。
// open 時の probe は連結のための一時コピーを伴う（実 DVD で 1〜8GB。ディスク空きが
// 無い失敗はそのまま upper へ。将来の無連結経路は OQ のまま）。

public actor VideoTsMediaSource: MediaSource, DemuxerProviding {
    public let rootURL: URL
    private var chainsByID: [ItemID: VideoTsChain] = [:]
    private var demuxers: [ItemID: any Demuxer] = [:]
    /// open の結果（冪等化）。タイトル切り替えは「同じ source の再 open」で再 loadされるが、
    /// 再 probe（= 多重 VOB の再連結コピー、実 DVD で 1〜8GB）をやり直さないための cache。
    /// demuxer の同一实例契約（track id 対応）とも整合する（DemuxerProviding の注記）。
    private var opened: OpenedSource?

    public init(rootURL: URL) { self.rootURL = rootURL }

    nonisolated public var descriptor: SourceDescriptor {
        SourceDescriptor(id: SourceID(Self.stableID(for: rootURL.standardizedFileURL.path)),
                         kind: .videoTsFolder,
                         displayName: "DVD-Video（\(rootURL.lastPathComponent)）",
                         location: .directoryURL(rootURL))
    }

    public func open() async throws -> OpenedSource {
        if let opened { return opened }   // 冪等（タイトル切り替えの再 load で再 probe・再連結しない）
        guard let found = VideoTsNavigator.chains(in: rootURL) else {
            throw PlaybackError(kind: .source(.unsupportedStructure),
                                causeDescription: "VIDEO_TS ディレクトリが見つかりません（\(rootURL.lastPathComponent)）",
                                recovery: .needsUserAction(.insertDisc),
                                userMessage: "DVD-Video として認識できる構造（VIDEO_TS）が見つかりません。"
                                    + "DVD のフォルダ（またはマウントしたディスクのボリューム）を選んでください。")
        }
        var warnings = found.warnings
        var items: [MediaItem] = []
        for chain in found.chains {
            let itemId = ItemID(UInt64(chain.vtsNumber))
            let demuxer = Self.makeDemuxer(for: chain)
            do {
                let stream = try await demuxer.probe()
                self.chainsByID[itemId] = chain
                self.demuxers[itemId] = demuxer
                guard let video = stream.tracks.first(where: { $0.kind == .video }),
                      case .video(let videoFormat) = video.format else {
                    warnings.append(StructureWarning(code: .noVideoTrack,
                                                    detail: "VTS_\(String(format: "%02d", chain.vtsNumber))"
                                                        + " に映像トラックが無い（AVFoundation が読めなかった）"))
                    continue
                }
                items.append(MediaItem(id: itemId,
                                       titleNumber: chain.vtsNumber,
                                       duration: stream.programDuration,
                                       trackTable: stream.tracks,
                                       videoFormat: videoFormat))
                warnings.append(contentsOf: stream.warnings)
            } catch let error as PlaybackError {
                warnings.append(StructureWarning(code: .containerUnreadable,
                                                detail: "VTS_\(String(format: "%02d", chain.vtsNumber))"
                                                    + " が読めません: \(error.userMessage)"))
            } catch {
                warnings.append(StructureWarning(code: .containerUnreadable,
                                                detail: "VTS_\(String(format: "%02d", chain.vtsNumber))"
                                                    + " の probe に失敗: \(error)"))
            }
        }
        guard let first = items.first else {
            throw PlaybackError(kind: .source(.unreadable),
                                causeDescription: "VIDEO_TS に再生できるタイトルがありません（警告: \(warnings.count) 件）",
                                recovery: .needsUserAction(.selectDifferentItem),
                                userMessage: "VIDEO_TS は見つかりましたが、再生できるタイトルがありません。"
                                    + "CSS 保護や破損の可能性があります（#3 のスコープ外）。")
        }
        let structure = MediaStructure(itemKind: .dvdTitles, items: items, warnings: warnings)
        // BlockReader は契約充足と mediaRemoved 検出用（FileMediaSource と同じ位置）。
        // 本来はディスク単位の_reader_が要るが、v1 は先頭チェーンの先頭 part に寄せる
        // （ISO 経路ではマウント点の実ファイル。03 §2 の optical 実装時に置き換える）。
        let probePart = self.chainsByID[first.id]?.partURLs.first
            ?? rootURL.appendingPathComponent("VIDEO_TS")
        let opened = OpenedSource(reader: FileBlockReader(url: probePart),
                                  structure: structure,
                                  formatHint: .mpegProgramStream)
        self.opened = opened
        return opened
    }

    /// Engine 向けの配線口（DemuxerProviding。open() で probe 済みの同一实例を返す —
    /// 新しい instance だと track id が対応しない。DemuxerProviding.swift の契約）。
    public func makeDemuxer(itemId: ItemID) async -> any Demuxer {
        if let cached = demuxers[itemId] { return cached }
        if let chain = chainsByID[itemId] {
            let demuxer = Self.makeDemuxer(for: chain)
            demuxers[itemId] = demuxer
            return demuxer
        }
        // engine は structure の通った item しか選ばない。想定外は先頭タイトルに寄せる。
        if let firstChain = chainsByID.values.min(by: { $0.vtsNumber < $1.vtsNumber }),
           let d = demuxers[ItemID(UInt64(firstChain.vtsNumber))] {
            return d
        }
        // open() 以前（構造未知）の呼び出し: 空のチェーンは作れないので、root の
        // VIDEO_TS を直接指す file demuxer へのフォールバックも無い = probe 待ち。
        // ここに来る経路は engine の契約外（open 前に wirePipeline は走らない）。
        return AVFoundationDemuxer(url: rootURL.appendingPathComponent("VIDEO_TS"))
    }

    /// demuxer cache を降ろす（DiscImageMediaSource の close から呼ぶ。AVFoundation が
    /// ボリューム上の file を開いたままにすると eject が失敗するため — 実測で順序を固定）。
    public func releaseDemuxers() {
        demuxers.removeAll()
    }

    private static func makeDemuxer(for chain: VideoTsChain) -> any Demuxer {
        if chain.partURLs.count == 1 {
            return AVFoundationDemuxer(url: chain.partURLs[0])
        }
        return ConcatPSDemuxer(partURLs: chain.partURLs)
    }

    /// パスから決定的な SourceID（FNV-1a。FileMediaSource と同じ作り方）。
    private static func stableID(for path: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
