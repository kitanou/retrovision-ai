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
// 多重 VOB（1 タイトル = VTS_nn_1..k.VOB）は SegmentPSDemuxer で無連結・part 単位
// demux + 時刻縫合として 1 本のタイムラインに読む（03 §4・§9.2。実測による設計差し替えは
// SegmentPSDemuxer 頭注。open 時の走査は demuxQueue 側で走り、再 open では作らない —
// 冪等 cache と同じ思想）。

public actor VideoTsMediaSource: MediaSource, DemuxerProviding, DVDMenuAssetProviding {
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

    public func close() async {
        // 資源の明示 release（03 §1 の MediaSource.close 契約）。SegmentPSDemuxer は
        // 修復写しの temp を deinit で掃除する — その参照をここでまとめて手放す。
        // opened cache も落とす（次の open は再走査・再 probe — close は「開き直し」の
        // 区切りであり、タイトル切り替えの再 load は close を通らない — 03 §9.6）。
        opened = nil
        // demuxer の明示 close（修復写しの削除 — Demuxer.close 契約）をしてから手放す。
        let old = demuxers
        demuxers.removeAll()
        chainsByID.removeAll()
        for (_, demuxer) in old {
            await demuxer.close()
        }
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
            // menu chain（vtsNumber 0）は ItemID(0) / titleNumber 0。列の先頭に有る（実盤の
            // first-play 入口。政策は PlayerViewModel — 03 §5 の実挙動合わせ）。
            let itemId = Self.itemID(for: chain)
            let demuxer = Self.makeDemuxer(for: chain)
            do {
                let stream = try await demuxer.probe()
                self.chainsByID[itemId] = chain
                self.demuxers[itemId] = demuxer
                guard let video = stream.tracks.first(where: { $0.kind == .video }),
                      case .video(let videoFormat) = video.format else {
                    warnings.append(StructureWarning(code: .noVideoTrack,
                                                    detail: "\(chain.label) に映像トラックが無い（AVFoundation が読めなかった）"))
                    continue
                }
                // menu（VMGM もタイトルメニューも）は titleNumber 0。タイトルメニューは静止画
                // （stillImage）で、UI は「タイトルメニュー」と表示し、VMGM の後で進む先になる。
                items.append(MediaItem(id: itemId,
                                       titleNumber: chain.isMenu ? 0 : chain.vtsNumber,
                                       duration: stream.programDuration,
                                       trackTable: stream.tracks,
                                       videoFormat: videoFormat,
                                       stillImage: chain.isTitleMenu))
                warnings.append(contentsOf: stream.warnings)
            } catch let error as PlaybackError {
                warnings.append(StructureWarning(code: .containerUnreadable,
                                                detail: "\(chain.label) が読めません: \(error.userMessage)"))
            } catch {
                warnings.append(StructureWarning(code: .containerUnreadable,
                                                detail: "\(chain.label) の probe に失敗: \(error)"))
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
        // engine は structure の通った item しか選ばない。想定外は先頭タイトルに寄せる
        // （menu を飛ばす — menu 目的の呼び出しなら itemId が先にヒットしている）。
        if let firstChain = chainsByID.values.filter({ !$0.isMenu })
                .min(by: { $0.vtsNumber < $1.vtsNumber }),
           let d = demuxers[Self.itemID(for: firstChain)] {
            return d
        }
        // open() 以前（構造未知）の呼び出し: 空のチェーンは作れないので、root の
        // VIDEO_TS を直接指す file demuxer へのフォールバックも無い = probe 待ち。
        // ここに来る経路は engine の契約外（open 前に wirePipeline は走らない）。
        return AVFoundationDemuxer(url: rootURL.appendingPathComponent("VIDEO_TS"))
    }

    /// タイトルメニュー（静止画）の VOB と IFO（同じ名前の .IFO）。
    public func menuAssets(for item: ItemID) async -> DVDMenuAssets? {
        guard let chain = chainsByID[item], chain.isTitleMenu, let vob = chain.partURLs.first else { return nil }
        let dir = vob.deletingLastPathComponent()
        let base = vob.deletingPathExtension().lastPathComponent
        let ifo = ["IFO", "ifo"].map { dir.appendingPathComponent("\(base).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return DVDMenuAssets(vobURL: vob, ifoURL: ifo, vtsNumber: chain.vtsNumber)
    }

    /// demuxer cache を降ろす（DiscImageMediaSource の close から呼ぶ。AVFoundation が
    /// ボリューム上の file を開いたままにすると eject が失敗するため — 実測で順序を固定）。
    public func releaseDemuxers() {
        demuxers.removeAll()
    }

    private static func makeDemuxer(for chain: VideoTsChain) -> any Demuxer {
        // タイトルメニュー（VTS_nn_0.VOB）は静止画 1 枚。AVFoundation は 1 枚だけの program stream から
        // sample を渡さない（実測 — StillPSDemuxer 頭注）ので、自前で映像 ES を取り出す。
        if chain.isTitleMenu, let url = chain.partURLs.first { return StillPSDemuxer(url: url) }
        // 単一 part も同じ経路（offset 0 で素の demux と逐語一致 — SegmentPSDemuxerTests §5 で実測。
        // 単一 part 内部の程序再開始も ProgramStreamRepair で修復できる利点がある）。
        // 旧 ConcatPSDemuxer は実写マルチパートで崩壊するため退場 — SegmentPSDemuxer 頭注。
        return SegmentPSDemuxer(partURLs: chain.partURLs)
    }

    /// chain の ItemID。VMGM は 0、タイトル本体は vts 番号、タイトルメニュー（VTS_nn_0.VOB）は
    /// 1000 + vts（本体の ItemID と衝突しない）。
    static func itemID(for chain: VideoTsChain) -> ItemID {
        chain.isTitleMenu ? ItemID(UInt64(1_000 + chain.vtsNumber)) : ItemID(UInt64(chain.vtsNumber))
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
