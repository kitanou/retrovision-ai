import CoreMedia
import CoreVideo
import Foundation
import RVMediaCore

// MARK: - デコード・同期の契約（04）
//
// 復号・同期の実装は AVFoundation / VideoToolbox 経路を先に持つ（04 §3 の案 B に相当）。
// FFmpeg 由来の経路（案 A）は、AVFoundation で読めない容器が確定してから C シムと共に追加する（OQ-01 / OQ-02）。

/// 圧縮された 1 帧分のサンプル。demux 側の自然な出力形に寄せる（04 §2）。
///
/// 契約を変更した理由（実測に基づく）: AVFoundation の demux は `CMSampleBuffer` を単位に出力する。
/// `Data` に切り出すと、復号が必要とする format description（SAR / field / color のメタデータ）を
/// 呼び出し側で再現できず、情報を失う。FFmpeg 経路でも packet と codec parameters をこの型へ
/// 変換して同じ契約に通す（shim 内で変換し、Swift 側は二つの形を見ない）。
public struct CompressedSample: @unchecked Sendable {
    public let track: TrackID
    public let sampleBuffer: CMSampleBuffer

    public init(track: TrackID, sampleBuffer: CMSampleBuffer) {
        self.track = track
        self.sampleBuffer = sampleBuffer
    }

    public var pts: MediaTime { CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
    public var dts: MediaTime { CMSampleBufferGetDecodeTimeStamp(sampleBuffer) }
    public var duration: MediaTime { CMSampleBufferGetDuration(sampleBuffer) }

    /// 映像の format description（復号器がそのまま使える形）。
    public var videoFormatDescription: CMVideoFormatDescription? {
        CMSampleBufferGetFormatDescription(sampleBuffer)
    }

    /// 像素データを持つ sample か。
    /// 実測（docs/experiments/EXP-001）: AVFoundation（outputSettings = nil）は先頭に
    /// データを持たない buffer（numSamples == 0）を渡すことがある。VideoToolbox に渡すと
    /// kVTParameterErr（-12902）になる。IO 段で間引くための判定をここに置く。
    public var hasSampleData: Bool {
        CMSampleBufferGetNumSamples(sampleBuffer) > 0
            && (CMSampleBufferGetDataBuffer(sampleBuffer).map { CMBlockBufferGetDataLength($0) > 0 } ?? false)
    }

    /// key frame かどうか（demux 側で解析済みの情報）。
    public var isKey: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CMSampleBuffer.AttachmentKey: Any]],
              let first = attachments.first else { return false }
        let value = first[CMSampleBuffer.AttachmentKey(rawValue: kCMSampleAttachmentKey_NotSync)] as? Bool
        return value != true
    }
}

/// 非圧縮の PCM。音声側はこれを復号出力とする（04 §4）。
public struct AudioPCM: @unchecked Sendable {
    public let track: TrackID
    public let buffer: CMSampleBuffer

    public init(track: TrackID, buffer: CMSampleBuffer) {
        self.track = track
        self.buffer = buffer
    }

    public var pts: MediaTime { CMSampleBufferGetPresentationTimeStamp(buffer) }
}

/// トラック単位の出力。`Demuxer` が返す stream の要素（04 §2）。
public enum DemuxedItem: @unchecked Sendable {
    case video(CompressedSample)
    case audio(CompressedSample)
    case audioPCM(AudioPCM)
    case subtitle(SubtitleCue)
}

/// 字幕の 1 cue（04 §7）。Phase 2 では DVD SPU の RLE 列をそのまま保持する。
public struct SubtitleCue: Sendable, Hashable {
    public enum Payload: Sendable, Hashable {
        case text(String)
        case bitmapSPU(Data)      // DVD SPU の RLE 符号列（復号は RVVideoPipeline 側で行う）
    }
    public let track: TrackID
    public let start: MediaTime
    public let end: MediaTime
    public let payload: Payload

    public init(track: TrackID, start: MediaTime, end: MediaTime, payload: Payload) {
        self.track = track; self.start = start; self.end = end; self.payload = payload
    }
}

public struct ProbedStream: Sendable, Hashable {
    public var tracks: [TrackInfo]
    public var programDuration: MediaTime?
    public var warnings: [StructureWarning]
    public init(tracks: [TrackInfo], programDuration: MediaTime? = nil, warnings: [StructureWarning] = []) {
        self.tracks = tracks
        self.programDuration = programDuration
        self.warnings = warnings
    }
}

public struct SeekEffect: Sendable, Hashable {
    /// 実際にシークが着た位置（demux 上）。
    public var landedAt: MediaTime
    /// 音声・映像で開始位置が異なる場合の、映像側の破棄必要帧数。
    public var videoDiscardCount: Int
    public init(landedAt: MediaTime, videoDiscardCount: Int = 0) {
        self.landedAt = landedAt
        self.videoDiscardCount = videoDiscardCount
    }
}

/// demux の入口。`async` をつけるのは、AVFoundation 経路が actor（内部に reader を持つ）から
/// 実装されることが確定しているため（04 §2）。同期プロトコルにすると actor 適合ができない。
public protocol Demuxer: Sendable {
    func probe() async throws -> ProbedStream
    /// 1 トラック分の圧縮サンプル列。demux は IO キューからのみ呼ぶ（INV-4）。
    func samples(for track: TrackID) async -> AsyncThrowingStream<CompressedSample, any Error>
    func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect
    var streamInfo: ProbedStream { get async }
}

public enum DecodePath: String, Sendable, CaseIterable { case videoToolbox, software }

public struct DecodePathInfo: Sendable, Hashable {
    public var path: DecodePath
    public var reason: String?
    public var codecName: String?
    public var profileName: String?
    public init(path: DecodePath, reason: String? = nil, codecName: String? = nil, profileName: String? = nil) {
        self.path = path; self.reason = reason; self.codecName = codecName; self.profileName = profileName
    }
}

public struct DecodePolicy: Sendable, Hashable {
    public var preferHardware: Bool
    public var maxFrameCountPerDecode: Int
    /// 復号出力の望ましい像素形式（01 §4 のプール要求に直結）。既定は video-range 4:2:0。
    public var requestedOutputPixelFormat: OSType
    public init(preferHardware: Bool = true, maxFrameCountPerDecode: Int = 16,
                requestedOutputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.preferHardware = preferHardware
        self.maxFrameCountPerDecode = maxFrameCountPerDecode
        self.requestedOutputPixelFormat = requestedOutputPixelFormat
    }
}

/// 復号器に渡す format description の差し出し口。
///
/// 実測（docs/experiments/EXP-001）: AVAssetReader は outputSettings = nil のとき
/// sample 自身に format description を添えないことがある（MPEG-PS で実測）。
/// 一方 AVAssetTrack の `formatDescriptions` には付いている。そのため probe 段で得た
/// description を hint として復号器に渡せるようにする（CMVideoFormatDescription は Sendable でない
/// ので、転送可能な保持型で包む）。
public final class FormatDescriptionHolder: @unchecked Sendable {
    public let value: CMVideoFormatDescription?
    public init(_ value: CMVideoFormatDescription?) { self.value = value }
}

/// 復号器（04 §3）。HW/SW の差はこの契約に隠す。
public protocol VideoDecoder: Sendable {
    var path: DecodePath { get async }
    /// 選択された復号経路の理由（02 §4 の診断表示）。
    var pathInfo: DecodePathInfo { get async }
    /// probe 結果から作った論理記述。`.unspecified` の色はここで assumption を確定させる（05 §3）。
    var sourceFormat: VideoFormatDescription? { get async }
    var decodedFormat: VideoFormatDescription? { get async }
    /// - Parameter formatDescriptionHint: sample に format description が添えられない容器のための
    ///   差し替え口（`FormatDescriptionHolder` の実測注記）。nil の場合は sample 側だけを使う。
    func configure(_ format: VideoFormatDescription, policy: DecodePolicy,
                   formatDescriptionHint: CMVideoFormatDescription?) async throws
    func decode(_ sample: CompressedSample) async throws -> DecodedVideoFrame?
    func flush() async -> [DecodedVideoFrame]
    func reset(at pts: MediaTime) async
}

/// 音声復号（04 §4）。PCM は CoreAudio 側ではなくここで PCM 化して渡す。
public protocol AudioDecoderProtocol: Sendable {
    var pathInfo: DecodePathInfo { get async }
    func configure(_ format: AudioFormatDescription, policy: DecodePolicy) async throws
    func decode(_ sample: CompressedSample) async throws -> AudioPCM?
    func flush() async -> [AudioPCM]
    func reset(at pts: MediaTime) async
}

/// 音声出力（04 §4）。realtime thread では確保しない。
public protocol AudioSink: Sendable {
    func start() throws
    func stop()
    func flush()
    /// 再生されたフレーム位置（クロックの原料）。
    func renderedFramePosition() -> Int64
    var outputLatencyMS: Double { get }
}

/// audio master clock（04 §5）。音声側を権威とする。
public protocol MediaClock: TimeSource {
    func mediaTime(at host: HostTime) -> MediaTime
    func hostTime(for media: MediaTime) -> HostTime
    var currentDriftMS: Double { get async }
}

/// 同期判定の入力値（04 §5 のテーブルは `DriftPolicy` が持つ）。
public struct DriftPolicy: Sendable, Hashable {
    public var deadbandMS: Double = 8
    public var videoOnlyMS: Double = 40
    public var dropOrRepeatMS: Double = 80
    public var pitchNudgeMS: Double = 250
    public var hardResyncMS: Double = 250
    public var maxPitchNudge: Double = 0.002

    public init() {}

    public enum Action: Sendable, Equatable {
        case none
        case adjustPresentTime
        case dropOrRepeatFrame
        case nudgeAudioPitch
        case flushAndSeek
    }

    public func action(forDriftMS drift: Double) -> Action {
        let d = abs(drift)
        switch d {
        case ..<deadbandMS: return .none
        case ..<videoOnlyMS: return .adjustPresentTime
        case ..<dropOrRepeatMS: return .dropOrRepeatFrame
        case ..<pitchNudgeMS: return .nudgeAudioPitch
        default: return .flushAndSeek
        }
    }
}
