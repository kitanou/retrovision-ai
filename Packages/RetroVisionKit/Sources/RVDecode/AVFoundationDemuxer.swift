import AVFoundation
import CoreMedia
import Foundation
import RVMediaCore

// MARK: - 単一ファイル（MP4 / MOV など）の demux（04 §2、03 §2）
//
// AVAssetReader を使う。目的は 2 つ:
//   1. 復号に必要な format description を失わずに渡せること（CompressedSample）。
//   2. MPEG-PS など AVFoundation が扱えない容器で**失敗する理由**を計測できること（OQ-01/OQ-02 の判定材料）。
//
// 実測（docs/experiments/EXP-001）:
//   - outputSettings = nil で「圧縮サンプルのまま」取れる。これが CompressedSample の前提。
//   - AVFoundation が読める容器でも、format description の extension に field・色・比の
//     attachment が付かない素材がある（MPEG-2 由来の素材で実測）。欠けている情報を bridge では埋めない
//     （05 §3、§6 で plan を作るときに決める）。
//   - AVFoundation は frame rate を有理数では渡さない（`nominalFrameRate` は float）。
//     標準レートに一致する場合だけ有理数に直し、一致しないものは nil のまま残す（01 §2）。
//
// スレッド要件: probe と read 開始は demuxQueue からのみ呼ぶ（INV-4）。
// sample 列を作る Task の中には AVFoundation のオブジェクトを持ち込まない
// （AVFoundation の型は Sendable でないため、URL からその場で作り直す。AVURLAsset の生成自体は軽く、
// 重いのは track の読み込みなので、read ごとに 1 回だけ発生する）。
public actor AVFoundationDemuxer: Demuxer {
    private let url: URL
    private let asset: AVURLAsset
    private var info: ProbedStream?
    /// 直近のシーク位置。次の samples(for:) に引き継がれる（04 §6 の read 開始位置）。
    private var readingFrom: MediaTime = .zero
    private var readRangeEnd: MediaTime?
    /// TrackID → (media type, 同種トラック中の並び順)。sample 列を作る Task で再現できるキー。
    private var trackKeys: [TrackID: (mediaType: AVMediaType, index: Int)] = [:]

    public init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
    }

    // MARK: Demuxer 契約

    public var streamInfo: ProbedStream { info ?? ProbedStream(tracks: []) }

    public func probe() async throws -> ProbedStream {
        if let info { return info }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let legible = try await legibleTracks()
        let duration = try await asset.load(.duration)

        var tracks: [TrackInfo] = []
        var warnings: [StructureWarning] = []

        for (index, track) in videoTracks.enumerated() {
            let id = TrackID(UInt32(100 + index))
            let format = try await videoFormat(of: track)
            tracks.append(TrackInfo(id: id, kind: .video,
                                    language: nil, name: nil,
                                    format: .video(format),
                                    isDefault: index == 0))
            trackKeys[id] = (.video, index)
        }
        for (index, track) in audioTracks.enumerated() {
            let id = TrackID(UInt32(200 + index))
            let description = try await audioFormat(of: track)
            tracks.append(TrackInfo(id: id, kind: .audio,
                                    language: nil, name: nil,
                                    format: .audio(description),
                                    isDefault: index == 0))
            trackKeys[id] = (.audio, index)
        }
        for (index, entry) in legible.enumerated() {
            let id = TrackID(UInt32(300 + index))
            tracks.append(TrackInfo(id: id, kind: .subtitle,
                                    language: nil, name: nil,
                                    format: .subtitle(SubtitleFormatDescription(kind: .unknown)),
                                    isDefault: index == 0))
            trackKeys[id] = (entry.mediaType, index)
        }
        if videoTracks.isEmpty {
            warnings.append(StructureWarning(code: .noVideoTrack, detail: "video track がありません"))
        }
        let probed = ProbedStream(tracks: tracks,
                                  programDuration: duration.timescale != 0 && duration.seconds.isFinite ? duration : nil,
                                  warnings: warnings)
        info = probed
        return probed
    }

    public func samples(for track: TrackID) async -> AsyncThrowingStream<CompressedSample, any Error> {
        let url = self.url
        let start = readingFrom
        let end = readRangeEnd
        let key = trackKeys[track]
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard let key else {
                        throw PlaybackError.source(.notFound, message: "トラックが見つかりません",
                                                  recovery: .needsUserAction(.selectDifferentItem))
                    }
                    let asset = AVURLAsset(url: url)
                    // 同期的な track 取得: この Task は後方スレッドで動く（INV-4 の read 側）。
                    // macOS 13 で deprecated だが、非同期版は Task 内で再度 async を積む意味が無い
                    // （後方スレッドに限定して同期 API を使う。AVFoundation 自体は thread safe な読み取り）。
                    let candidates = asset.tracks(withMediaType: key.mediaType)
                    guard candidates.count > key.index else {
                        throw PlaybackError.source(.notFound, message: "トラックが見つかりません",
                                                  recovery: .needsUserAction(.selectDifferentItem))
                    }
                    let reader = try AVAssetReader(asset: asset)
                    // nil = 圧縮サンプルのまま（format description ごと復号へ渡すため必须。04 §2）
                    let output = AVAssetReaderTrackOutput(track: candidates[key.index], outputSettings: nil)
                    output.alwaysCopiesSampleData = false
                    reader.timeRange = CMTimeRange(start: start, end: end ?? .invalid)
                    // 実測: canAdd(_:) は追加しない（適合性を調べるだけ）。addOutput が必須。
                    // 忘れると copyNextSampleBuffer が例外を投げる（crash ではなく错误で返す）。
                    guard reader.canAdd(output) else {
                        throw PlaybackError.decode(.formatRejected, message: "読み出し形式を受け付けられません",
                                                  recovery: .retryWith(.softwareDecode),
                                                  cause: reader.error.map { String(describing: $0) } ?? "canAdd=false")
                    }
                    reader.add(output)
                    guard reader.startReading() else {
                        throw PlaybackError.decode(.corruptStream, message: "読み始められません",
                                                  recovery: .giveUp(reason: "read"),
                                                  cause: reader.error.map { String(describing: $0) })
                    }
                    while !Task.isCancelled {
                        guard let raw = output.copyNextSampleBuffer() else { break }
                        let sample = CompressedSample(track: track, sampleBuffer: raw)
                        // 実測: 先頭にデータを持たない buffer が混ざる（VideoToolbox は -12902 で弾く）。
                        // sample 数を数えないことで、decode 段の「受け取った sample 数」と
                        // 「実際に復号要求した sample 数」を一致させる（04 §9 の dropped 計上を正確にする）。
                        if !sample.hasSampleData { continue }
                        continuation.yield(sample)
                    }
                    if let error = reader.error {
                        throw PlaybackError.decode(.corruptStream, message: "読み取りに失敗しました",
                                                  recovery: .giveUp(reason: "read"),
                                                  cause: String(describing: error))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// PCM 変換読み出し（04 §4・EXP-002 A1）。`AVAssetReaderTrackOutput` の
    /// outputSettings に線形 PCM を要求すると、システムが AC-3 等を復号・変換して渡す
    /// （依存ゼロで成立する実測確認済み）。変換 chunk は ~8192 帧に結合されて届く（A2）。
    /// 映像と違い PCM は reader 内部の buffer を再利用しうるのでコピーを保たせる
    /// （alwaysCopiesSampleData を既定のままにする）。
    public func pcmSamples(for track: TrackID, target: PCMTargetSettings)
        async -> AsyncThrowingStream<AudioPCM, any Error>
    {
        let url = self.url
        let start = readingFrom
        let end = readRangeEnd
        let key = trackKeys[track]
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // dict は non-Sendable なので sending 境界をまたがない（tasks の内側で組む）。
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: target.sampleRate,
                    AVNumberOfChannelsKey: target.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                do {
                    guard let key, key.mediaType == .audio else {
                        throw PlaybackError.source(.notFound, message: "音声トラックが見つかりません",
                                                  recovery: .needsUserAction(.selectDifferentItem))
                    }
                    let asset = AVURLAsset(url: url)
                    let candidates = asset.tracks(withMediaType: .audio)
                    guard candidates.count > key.index else {
                        throw PlaybackError.source(.notFound, message: "音声トラックが見つかりません",
                                                  recovery: .needsUserAction(.selectDifferentItem))
                    }
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: candidates[key.index], outputSettings: outputSettings)
                    reader.timeRange = CMTimeRange(start: start, end: end ?? .invalid)
                    guard reader.canAdd(output) else {
                        throw PlaybackError.decode(.formatRejected, message: "PCM 変換を受け付けられません",
                                                  recovery: .giveUp(reason: "audio"),
                                                  cause: reader.error.map { String(describing: $0) } ?? "canAdd=false")
                    }
                    reader.add(output)
                    guard reader.startReading() else {
                        throw PlaybackError.decode(.corruptStream, message: "音声の読み始めに失敗しました",
                                                  recovery: .giveUp(reason: "read"),
                                                  cause: reader.error.map { String(describing: $0) })
                    }
                    while !Task.isCancelled {
                        guard let raw = output.copyNextSampleBuffer() else { break }
                        if CMSampleBufferGetNumSamples(raw) <= 0 { continue }
                        continuation.yield(AudioPCM(track: track, buffer: raw))
                    }
                    if let error = reader.error {
                        throw PlaybackError.decode(.corruptStream, message: "音声の読み取りに失敗しました",
                                                  recovery: .giveUp(reason: "read"),
                                                  cause: String(describing: error))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// probe 段で読んだ生の format description（04 §2 の `FormatDescriptionHolder` へ渡す）。
    /// sample に format description が添えられない容器で、復号器を作るために使う（実測: EXP-001）。
    public func seedFormatDescription(for track: TrackID) async throws -> CMFormatDescription? {
        guard let key = trackKeys[track] else { return nil }
        let candidates = try await asset.loadTracks(withMediaType: key.mediaType)
        guard candidates.count > key.index else { return nil }
        return try await formatDescription(of: candidates[key.index])
    }

    public func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect {
        // AVFoundation は編集表で key frame へ寄せる。実際の着地位置は sample の PTS で確認する（04 §6）。
        let clamped = CMTimeCompare(target, .zero) < 0 ? .zero : target
        readingFrom = clamped
        return SeekEffect(landedAt: clamped, videoDiscardCount: 0)
    }

    // MARK: 内部

    /// 字幕に相当するトラック。
    /// 実測: AVAssetTrack 側に言語・表示名の async property は無い（languageIdentifier は
    /// AVMediaSelectionOption 側にある）。トラック表には出さない（04 §7 で selection 機構を作る）。
    private func legibleTracks() async throws -> [(AVAssetTrack, mediaType: AVMediaType)] {
        let subtitles = try await asset.loadTracks(withMediaType: .subtitle)
        let captions = try await asset.loadTracks(withMediaType: .closedCaption)
        return subtitles.map { ($0, .subtitle) } + captions.map { ($0, .closedCaption) }
    }

    private func videoFormat(of track: AVAssetTrack) async throws -> VideoFormatDescription {
        guard let description = try await formatDescription(of: track) else {
            throw PlaybackError.decode(.unsupportedCodec, message: "映像の形式を判定できません",
                                       recovery: .giveUp(reason: "probe"))
        }
        let hint = await frameRateHint(of: track)
        var format = VideoFormatDescription(sampleFormatDescription: description, frameRateHint: hint)
        // MPEG-2 で容器が何も語らない項目は、sample 先頭の bitstream（sequence header）から取る。
        // 実測（docs/experiments/EXP-001）: AVFoundation は PES ヘッダを外した ES access unit を渡すため、
        // 先頭 sample に sequence header がそのまま付いている（firstBytesHex が 000001b3…）。
        if CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_MPEG2Video,
           format.frameRate == nil || format.aspectSignals.mpegAspectInformation == nil
               || !format.interlace.isInterlaced || format.interlace.fieldOrder == .unknown {
            if let bytes = await firstSampleBytes(of: track),
               let header = MPEG2Bitstream.sequenceHeader(in: bytes) {
                if format.frameRate == nil { format.frameRate = header.frameRate }
                if format.aspectSignals.mpegAspectInformation == nil {
                    format.aspectSignals.mpegAspectInformation = header.effectiveDisplayAspect
                }
                if !format.interlace.isInterlaced, !header.progressiveSequence {
                    // field 順序は picture 层（picture_coding_extension）の信号。実測: 生成素材は
                    // 帧単位 top_field_first=0（ffprobe field_order=bb）。per-frame で読み直す前提で、
                    // ここは最初の PCE が語ればそれを使い、無ければ既定（下位フィールド先行）に置く。
                    let topFirst = MPEG2Bitstream.pictureCodingExtension(in: bytes)?.topFieldFirst ?? false
                    format.interlace = InterlaceInfo(
                        fieldCount: 2,
                        fieldOrder: topFirst ? .topFirst : .bottomFirst,
                        cadence: .unknown, fieldSource: .formatDescription)
                } else if format.interlace.isInterlaced, format.interlace.fieldOrder == .unknown,
                          let pce = MPEG2Bitstream.pictureCodingExtension(in: bytes) {
                    // 実測: MPEG-2 の容器（format description）は field 数（CVFieldCount）だけ渡し、
                    // 順序は渡さない。順序は bitstream の picture_coding_extension のみが知る信号。
                    // format 段の値は最初の access unit の符号（典型的には GOP 先頭）で、
                    // 05 §4 の plan 段では sample ごとに読み直す前提の「手がかり」に留める。
                    format.interlace.fieldOrder = pce.topFieldFirst ? .topFirst : .bottomFirst
                }
            }
        }
        if format.frameRate == nil {
            // 容器が frame rate を渡さない素材の救済: sample の PTS 列から特定する（01 §2）。
            let pts = try await firstSamplePTSs(of: track, count: 32)
            format.frameRate = RVMediaCore.frameRate(fromPTSs: pts)
        }
        if format.frameRate == nil {
            throw PlaybackError.decode(.formatRejected, message: "フレームレートを特定できません",
                                       recovery: .giveUp(reason: "probe"),
                                       cause: "container・bitstream とも frame rate 情報なし")
        }
        // 比の情報（clean aperture / DAR / PAR）が取れない場合、ここで 4:3 に倒さない。
        // 解決は AspectResolver が policy に従って行う（05 §6）。
        return format
    }

    private func audioFormat(of track: AVAssetTrack) async throws -> AudioFormatDescription {
        guard let description = try await formatDescription(of: track) else {
            throw PlaybackError.decode(.unsupportedCodec, message: "音声の形式を判定できません",
                                       recovery: .giveUp(reason: "probe"))
        }
        return AudioFormatDescription(sampleFormatDescription: description)
    }

    private func formatDescription(of track: AVAssetTrack) async throws -> CMFormatDescription? {
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.first
    }

    /// AVAssetTrack が持つ frame rate（float）から、**標準レートの候補に一致する場合だけ**有理数を作る。
    /// 一致しない場合は nil（推測で NTSC / PAL に倒さない — 01 §2）。
    private func frameRateHint(of track: AVAssetTrack) async -> FrameRate? {
        let nominal = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        guard nominal > 0, nominal.isFinite else { return nil }
        let thousandth = FrameRate(numerator: 1_000, denominator: 1_001)
        let candidates = [
            FrameRate.film24, FrameRate.film24.multiplying(thousandth),
            FrameRate.pal, FrameRate(value: 25).multiplying(thousandth),
            FrameRate(value: 30).multiplying(thousandth), FrameRate(value: 30),
        ]
        for candidate in candidates where abs(nominal - candidate.framesPerSecond) < 0.02 {
            return candidate
        }
        return nil
    }

    private func firstSamplePTSs(of track: AVAssetTrack, count: Int) async throws -> [MediaTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: 4, preferredTimescale: 600))
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var result: [MediaTime] = []
        while result.count < count, let sample = output.copyNextSampleBuffer() {
            result.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        reader.cancelReading()
        return result
    }

    /// 最初のデータ付き sample のバイト列（先頭 maxBytes）。MPEG-2 の sequence header 参照用。
    /// 実測（docs/experiments/EXP-001）: AVFoundation は PES ヘッダを外した ES access unit を渡す。
    private func firstSampleBytes(of track: AVAssetTrack, maxBytes: Int = 1 << 16) async -> Data? {
        let reader = try? AVAssetReader(asset: asset)
        guard let reader else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: 4, preferredTimescale: 600))
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = min(maxBytes, CMBlockBufferGetDataLength(block))
            guard length > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                             destination: &bytes) == noErr else { return nil }
            return Data(bytes)
        }
        return nil
    }
}
