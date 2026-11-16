import AVFoundation
import CoreMedia
import Foundation
import RVMediaCore

// MARK: - 多重 VOB の無連結 demux + 時刻縫合（03 §4、#3。設計の差し替え 2026-11-17）
//
// ConcatPSDemuxer（バイト連結 → 単一 AVURLAsset）は合成 fixture では成立したが、
// 実写の長いマルチパート VTS で壊れることが実測で確定した（issue #3、PICHI 実 ISO）:
//   * 実測: 4 パート連結の duration が 76.064 s に崩壊。最後の part 単体でも
//     duration 92,865 s と誤読され reader が 3.2 s / 92 sample で停止した。
//     直接原因は part 内部のプログラム再開始（PTS の -2,935 s 逆行。03 §9.2）。
//   * 対して part を個別に読むと 1〜3 は完全に正常（885.7/884.7/884.1 s。連結時の
//     2,654.6 s と一致）。壊れるのは連結という器だけだった。
//
// よって本増分は 03 §4 に保留されていた**無連結・part 単位 demux + engine 側の
// 時刻縫合**へ切り替える。実装は demux 層に寄せる（engine・session は単一の
// sample 列を見る — 04 §2 の契約のまま。実測で生じる sample 時刻の surgery
// （CMSampleBufferCreateCopyWithNewTiming）は、03 §9.2 で「避ける」とした設計から
// 方針を変え、demux の内側に閉じ込める: 連結が壊れる以上、 surgery を避けられる
// 経路が存在しない）。
//
// 縫合の時間基盤: 各 part の sample 列は AVFoundation がファイル単位で 0 起点へ
// 正規化する（03 §9.2 実測事実 1。この性質に依存する）。part 境界のオフセットは
// probe で得た各 part の duration の累積和。境界の実寸（authoring が空ける
// 0.5 s 級の穴）は縮まるが、同一タイトルの続きとしての位置・音声同期は
// part 内の一貫性を保ったまま続く（検査 SegmentPSDemuxerTests が兼実測）。
//
// 程序再開始を含む part は ProgramStreamRepair の修復コピーへ載せ替える
// （発火はスキャン検出。再開始の無い part はコピーを作らない — PICHI で実測）。
public actor SegmentPSDemuxer: Demuxer, PCMSampleSource {
    private struct Part {
        let url: URL
        let demuxer: AVFoundationDemuxer
        let duration: MediaTime
        let offset: MediaTime   // グローバル時間軸上の開始（先行 part の duration 累積）
    }

    private let requestedPartURLs: [URL]
    private var parts: [Part]?
    private var mergedInfo: ProbedStream?
    /// 直近のシーク位置（グローバル）。次の samples(for:) / pcmSamples の開始点。
    private var readingFrom: MediaTime = .zero
    private var repairTemps: [URL] = []

    /// チェーンの先頭から順（呼び出し側が決定的順序を保証する — VideoTsNavigator が排序）。
    public init(partURLs: [URL]) {
        precondition(!partURLs.isEmpty, "空のチェーンでは demux できない")
        self.requestedPartURLs = partURLs
    }

    deinit {
        // 修復コピーの後始末（open 経路が中断した場合も含む。09 §4 の一時素材方針）。
        // 通常の解除は下の close()（明示契約）で済む — deinit は actor で非同期かつ
        // process 終末では走らないため、当てにしている側（source・engine）は close を呼ぶ。
        for temp in repairTemps {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    /// 資源の明示解除（RVDecode.Contracts の Demuxer.close 契約）。修復写しをここで
    /// **同期的に**消す（実測 2026-11-17: 終了処理の close→exit 順では actor の
    /// deinit が走る前に process が終り、430 MB の temp が残った）。close 後の
    /// probe/samples は ensureParts で作り直しになる（cache を落とす）。
    public func close() async {
        let temps = repairTemps
        repairTemps = []
        for temp in temps {
            try? FileManager.default.removeItem(at: temp)
        }
        parts = nil
        mergedInfo = nil
    }

    public var streamInfo: ProbedStream {
        get async { mergedInfo ?? ProbedStream(tracks: []) }
    }

    // MARK: 構築

    /// 各 part を個別に probe し、修復の要否を決め、時間軸オフセットとトラック表の
    /// 対応を作る（1 度だけ。以後は cache — VideoTsMediaSource の open 冪等と同一思想）。
    @discardableResult
    private func ensureParts() async throws -> [Part] {
        if let parts { return parts }
        var built: [Part] = []
        var warnings: [StructureWarning] = []
        var referenceTracks: [TrackInfo]?
        var offset = CMTime.zero

        for (index, url) in requestedPartURLs.enumerated() {
            let label = url.lastPathComponent
            var effectiveURL = url
            // 程序再開始の検出 → 修復コピー（実測: PICHI part 1〜3 はスキャンのみで写し無し）。
            if let repaired = await ProgramStreamRepair.repairedCopyIfNeeded(of: url) {
                self.repairTemps.append(repaired.repairedURL)
                effectiveURL = repaired.repairedURL
                warnings.append(StructureWarning(code: .ptsRestartRepaired,
                                                detail: "\(label) 内にプログラム再開始を検出"
                                                    + "（逆行点 \(repaired.finding.breakOffsets.map { String($0) }.joined(separator: ",")) バイト、"
                                                    + "時刻フィールド \(repaired.finding.shiftedFieldCount) 個を前方へ寄せて continuation として続けた）。"
                                                    + "境界より後の章区切り（IFO PGCI）は未解析のまま — 増分で切り分ける"))
            }
            let demuxer = AVFoundationDemuxer(url: effectiveURL)
            let stream: ProbedStream
            do {
                stream = try await demuxer.probe()
            } catch {
                if built.isEmpty { throw error }   // 先頭 part が読めない = タイトル全体が読めない
                warnings.append(StructureWarning(code: .containerUnreadable,
                                                detail: "\(label) が読めないためチェーンを part \(index + 1)"
                                                    + " で打ち切った（\(built.count) part まで再生可能）"))
                break
            }
            guard let duration = stream.programDuration,
                  CMTimeGetSeconds(duration).isFinite, CMTimeGetSeconds(duration) > 0 else {
                if built.isEmpty {
                    throw PlaybackError.source(.unreadable,
                                              message: "先頭 part の長さを確定できません（\(label)）",
                                              recovery: .needsUserAction(.selectDifferentItem))
                }
                warnings.append(StructureWarning(code: .containerUnreadable,
                                                detail: "\(label) の長さを確定できないためチェーンを part \(index + 1)"
                                                    + " で打ち切った"))
                break
            }
            if let reference = referenceTracks {
                if reference.count != stream.tracks.count
                    || !zip(reference, stream.tracks).allSatisfy({ $0.kind == $1.kind }) {
                    warnings.append(StructureWarning(code: .trackTableMismatch,
                                                    detail: "\(label) のトラック表が先行 part と一致しない"
                                                        + "（sample 列は同一 kind 内の並び順で対応づけて読む）"))
                }
            } else {
                referenceTracks = stream.tracks
                warnings.append(contentsOf: stream.warnings)
            }
            built.append(Part(url: effectiveURL, demuxer: demuxer, duration: duration, offset: offset))
            offset = CMTimeAdd(offset, duration)
        }

        guard !built.isEmpty, let tracks = referenceTracks else {
            throw PlaybackError.source(.unreadable,
                                      message: "チェーンのどの part も読めません",
                                      recovery: .needsUserAction(.selectDifferentItem))
        }
        let probed = ProbedStream(tracks: tracks, programDuration: offset, warnings: warnings)
        self.parts = built
        self.mergedInfo = probed
        return built
    }

    // MARK: Demuxer 契約

    public func probe() async throws -> ProbedStream {
        _ = try await ensureParts()
        return mergedInfo!
    }

    public func samples(for track: TrackID) async -> AsyncThrowingStream<CompressedSample, any Error> {
        let snapshot: [Part]
        do {
            snapshot = try await ensureParts()
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let start = readingFrom
        return Self.compressedStream(parts: snapshot, track: track, globalStart: start)
    }

    public func pcmSamples(for track: TrackID, target: PCMTargetSettings)
        async -> AsyncThrowingStream<AudioPCM, any Error>
    {
        let snapshot: [Part]
        do {
            snapshot = try await ensureParts()
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let start = readingFrom
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startIndex = Self.startPartIndex(in: snapshot, globalStart: start)
                for (index, part) in snapshot.enumerated() where index >= startIndex {
                    let localStart = index == startIndex ? CMTimeSubtract(start, part.offset) : .zero
                    _ = try? await part.demuxer.seek(to: localStart, tolerance: .exact)
                    do {
                        for try await chunk in await part.demuxer.pcmSamples(for: track, target: target) {
                            if part.offset == .zero {
                                continuation.yield(chunk)
                            } else if let shifted = Self.shiftedTiming(chunk.buffer, by: part.offset) {
                                continuation.yield(AudioPCM(track: track, buffer: shifted))
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    if Task.isCancelled { return }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect {
        let built = try await ensureParts()
        let clamped = CMTimeCompare(target, .zero) < 0 ? .zero : target
        readingFrom = clamped
        let index = Self.startPartIndex(in: built, globalStart: clamped)
        let part = built[index]
        let local = CMTimeSubtract(clamped, part.offset)
        let effect = try await part.demuxer.seek(to: local, tolerance: tolerance)
        return SeekEffect(landedAt: CMTimeAdd(part.offset, effect.landedAt),
                          videoDiscardCount: effect.videoDiscardCount)
    }

    /// 復号器の初期化用 format description（現在位置の part から取る。同一タイトルの
    /// part 間なので記述は同一 — 実測で parameter set の変化は観測されない）。
    public func seedFormatDescription(for track: TrackID) async throws -> CMFormatDescription? {
        let built = try await ensureParts()
        let index = Self.startPartIndex(in: built, globalStart: readingFrom)
        return try await built[index].demuxer.seedFormatDescription(for: track)
    }

    // MARK: sample 列の縫合

    /// part 群を順に読み、globalStart 以降の圧縮 sample 列を **グローバル時刻に寄して**
    /// 1 本へつなぐ。各 part 側は 0 起点正規化（03 §9.2 実測事実 1）なので、
    /// 寄与は累積 offset の加算だけ。
    private static func compressedStream(parts: [Part], track: TrackID,
                                        globalStart: MediaTime)
        -> AsyncThrowingStream<CompressedSample, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startIndex = startPartIndex(in: parts, globalStart: globalStart)
                for (index, part) in parts.enumerated() where index >= startIndex {
                    let localStart = index == startIndex ? CMTimeSubtract(globalStart, part.offset) : .zero
                    _ = try? await part.demuxer.seek(to: localStart, tolerance: .exact)
                    do {
                        for try await sample in await part.demuxer.samples(for: track) {
                            if part.offset == .zero {
                                continuation.yield(sample)
                            } else if let shifted = shiftedTiming(sample.sampleBuffer, by: part.offset) {
                                continuation.yield(CompressedSample(track: track, sampleBuffer: shifted))
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    if Task.isCancelled { return }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func startPartIndex(in parts: [Part], globalStart: MediaTime) -> Int {
        var index = 0
        for (i, part) in parts.enumerated() where CMTimeCompare(part.offset, globalStart) <= 0 {
            index = i
        }
        return index
    }

    /// PTS/DTS を offset だけ平行移動した copy を作る（時刻 surgery。sample データは
    /// 共有のまま — alwaysCopiesSampleData=false の block buffer を書き換えない）。
    private static func shiftedTiming(_ buffer: CMSampleBuffer, by offset: MediaTime) -> CMSampleBuffer? {
        guard offset.isValid, offset != .zero else { return buffer }
        var info = CMSampleTimingInfo(duration: .invalid,
                                      presentationTimeStamp: .invalid,
                                      decodeTimeStamp: .invalid)
        guard CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &info) == noErr else {
            return nil
        }
        if !CMTIME_IS_INVALID(info.presentationTimeStamp) {
            info.presentationTimeStamp = CMTimeAdd(info.presentationTimeStamp, offset)
        }
        if !CMTIME_IS_INVALID(info.decodeTimeStamp) {
            info.decodeTimeStamp = CMTimeAdd(info.decodeTimeStamp, offset)
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                          sampleBuffer: buffer,
                                                          sampleTimingEntryCount: 1,
                                                          sampleTimingArray: [info],
                                                          sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}
