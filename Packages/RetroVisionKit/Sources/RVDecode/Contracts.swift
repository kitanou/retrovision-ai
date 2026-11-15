import CoreVideo
import Foundation
import RVMediaCore

// MARK: - デコード・同期の契約（04）
//
// FFmpeg / VideoToolbox の実装は C シムが決まってから加える（OQ-01 / OQ-02 / OQ-08）。
// ここでは境界の型だけを持つ。

public struct Packet: Sendable, Hashable {
    public let track: TrackID
    public let bytes: Data
    public let pts: MediaTime?
    public let dts: MediaTime?
    public let duration: MediaTime?
    public let isKey: Bool

    public init(track: TrackID, bytes: Data, pts: MediaTime?, dts: MediaTime? = nil,
                duration: MediaTime? = nil, isKey: Bool = false) {
        self.track = track
        self.bytes = bytes
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.isKey = isKey
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

public protocol Demuxer: Sendable {
    func probe() async throws -> ProbedStream
    func packets(for track: TrackID) -> AsyncThrowingStream<Packet, any Error>
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
    public init(preferHardware: Bool = true, maxFrameCountPerDecode: Int = 16) {
        self.preferHardware = preferHardware
        self.maxFrameCountPerDecode = maxFrameCountPerDecode
    }
}

/// 復号器（04 §3）。HW/SW の差はこの契約に隠す。
public protocol VideoDecoder: Sendable {
    var path: DecodePath { get async }
    var outputDescription: VideoFormatDescription { get async }
    func configure(_ format: FormatDescription, policy: DecodePolicy) async throws
    func decode(_ packet: Packet) async throws -> DecodedVideoFrame?
    func flush() async -> [DecodedVideoFrame]
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
