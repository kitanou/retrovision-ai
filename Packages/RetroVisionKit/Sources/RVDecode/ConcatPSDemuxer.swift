import AVFoundation
import CoreMedia
import Foundation
import RVMediaCore

// MARK: - 多重 VOB の連結 demux（03 §4、#3）
//
// 1 タイトル（VTS_*_1..n.VOB のチェーン）を 1 本のタイムラインとして読めるようにする。
//
// 実測で確定した事実（2026-11-16、scratch probe: concatprobe / diffprobe / datacount）:
//   1. AVFoundation は MPEG-PS の素の PTS をファイル単位で 0 起点に正規化する
//      （生素材の先頭 PTS 2.535s → track timeRange.start=0、先頭 sample の PTS=0.0）。
//   2. AVMutableComposition への挿入は **タイムライン構造だけ**を合成し、PS 由来の
//      圧縮 sample の時刻は書き換わらない（part2 の sample がファイル単位の素の
//      時戳のまま供給される。track の timeRange は 6.01s に伸びるのに sample の
//      pts は 2.90s のまま、という実測で確定）。CMSampleBufferCreateCopyWithNewTiming
//      の自前 surgery 以外に composition で解ける道は無い。
//   3. 一方、DVD のタイトルを構成する VOB は「連結すると 1 本の連続した
//      MPEG プログラムストリームになる」ことが仕様で保証されている（1GB 境界での
//      分割は容器のスライスにすぎない）。fixture の 2 分割 VOB を cat すると
//      母素材（ntsc480i-ac3-01.mpg）とバイト一致になることも実測で確認。
//
// よって本実装は **バイト連結**を使う: part を順に一時ファイルへ書き出し、それを
// 実証済みの単一ファイル経路（AVFoundationDemuxer(url:)）で読む。sample 時刻の
// 手 surgery を避けられ、seek・PCM・format description の意味論が単一ファイルと
// 完全に一致する（連結後の検査は「単一ファイルの列と一致」で表現できる —
// ConcatPSDemuxerTests がその兼実測）。
//
// コスト: open 時にタイトル 1 本ぶんの一時コピー（実 DVD で 1〜8GB。シーク自体は
// 一時ファイルに対して行うので以後の往復は無いか同等）。ディスク空き不足の失敗は
// そのまま upper に返す（recovery: retryWith(.systemCopy)? — 01 §7 のコード体系は
// 既存の giveUp で情報だけ残す。将来の無連結 path は OQ のまま）。
public actor ConcatPSDemuxer: Demuxer, PCMSampleSource {
    private let partURLs: [URL]
    private var inner: AVFoundationDemuxer?
    private var tempURL: URL?

    /// チェーンの先頭から順に並べる（呼び出し側が決定的順序を保証する — VideoTsNavigator が排序）。
    public init(partURLs: [URL]) {
        precondition(!partURLs.isEmpty, "空のチェーンでは demux できない")
        self.partURLs = partURLs
    }

    deinit {
        // 一時ファイルの後始末。close 経路は engine の close に同期しないため、
        // 生成物の掃除は deinit に委ねる（09 §4 の一時素材方針と同じ扱い）。
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    public var streamInfo: ProbedStream {
        get async {
            if let inner { return await inner.streamInfo }
            return ProbedStream(tracks: [])
        }
    }

    // MARK: 連結

    /// part を順に連結した一時ファイルを作り、単一ファイル経路の demuxer を作る
    /// （1 回だけ。以降は inner が cached）。単一 part のときはコピーを作らない
    /// （退行防止: FileMediaSource と同じ経路をそのまま使う）。
    @discardableResult
    private func ensureInner() async throws -> AVFoundationDemuxer {
        if let inner { return inner }
        if partURLs.count == 1 {
            let demuxer = AVFoundationDemuxer(url: partURLs[0])
            self.inner = demuxer
            return demuxer
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrovision-concat-\(UUID().uuidString).mpg")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        // 実測: この SDK の FileHandle の初期化ラベルは forReadingFrom / forWritingTo
        // （Cocoa の factory 由来。forReadingAt/forWritingAt は無い — 2026-11-16）。
        guard let out = try? FileHandle(forWritingTo: temp) else {
            throw PlaybackError.source(.unreadable, message: "連結用ファイルを作れません（\(temp.lastPathComponent)）",
                                       recovery: .giveUp(reason: "concat"))
        }
        defer { try? out.close() }
        for part in partURLs {
            guard let input = try? FileHandle(forReadingFrom: part) else {
                throw PlaybackError.source(.notFound, message: "VOB が読めません（\(part.lastPathComponent)）",
                                          recovery: .needsUserAction(.selectDifferentItem))
            }
            defer { try? input.close() }
            // 読み取り・書き出しの失敗は連結の失敗として上げる（素材の破損は probe より
            // この段階で分かるほうが原因が正確 — 03 §6）。
            do {
                while true {
                    // 1MB chunk の逐次写し（全体をメモリに載せない。INV-4 の read 側で走る）。
                    guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                    try out.write(contentsOf: chunk)
                }
            } catch {
                throw PlaybackError.source(.unreadable, message: "VOB の連結に失敗しました（\(part.lastPathComponent)）",
                                          recovery: .needsUserAction(.selectDifferentItem),
                                          cause: String(describing: error))
            }
        }
        // 連結後の書き出し量が期待値と食い違う場合も続ける（AVFoundation 側の probe に
        // 失敗理由を委ねる — 03 §6 の方針。実測: pack 境界分割の fixture では一致する）。

        let demuxer = AVFoundationDemuxer(url: temp)
        self.tempURL = temp
        self.inner = demuxer
        return demuxer
    }

    // MARK: Demuxer 契約（連結ファイルへの転送。意味論は単一ファイルと同一）

    public func probe() async throws -> ProbedStream {
        let demuxer = try await ensureInner()
        return try await demuxer.probe()
    }

    public func samples(for track: TrackID) async -> AsyncThrowingStream<CompressedSample, any Error> {
        let demuxer: AVFoundationDemuxer
        do {
            demuxer = try await ensureInner()
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        return await demuxer.samples(for: track)
    }

    public func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect {
        let demuxer = try await ensureInner()
        return try await demuxer.seek(to: target, tolerance: tolerance)
    }

    public func pcmSamples(for track: TrackID, target: PCMTargetSettings)
        async -> AsyncThrowingStream<AudioPCM, any Error>
    {
        do {
            let demuxer = try await ensureInner()
            return await demuxer.pcmSamples(for: track, target: target)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
    }

    /// 復号器の初期化に必要な format description（連結ファイルから取る — 単一ファイルと同じ）。
    public func seedFormatDescription(for track: TrackID) async throws -> CMFormatDescription? {
        let demuxer = try await ensureInner()
        return try await demuxer.seedFormatDescription(for: track)
    }
}
