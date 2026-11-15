import Foundation

/// 映像の論理記述（01 §2）。像素の解釈ではなく、意味（比・キャデンス・色）を持つ型。
public struct VideoFormatDescription: Sendable, Hashable {
    public var codedSize: PixelSize
    /// ソースが主張する切り出し。無いことがある（05 §6 で補完する）。
    public var statedCleanAperture: PixelRect?
    /// サンプルアスペクト比の断片（BT.601 NTSC / PAL など）。解決は AspectResolver が行う。
    public var sampleAspect: AspectRatio?
    public var frameRate: FrameRate
    public var interlace: InterlaceInfo
    public var color: ColorInfo
    /// MPEG-2 display extension / DVD flag などの比率指示。
    public var aspectSignals: AspectSignals

    public init(codedSize: PixelSize,
                statedCleanAperture: PixelRect? = nil,
                sampleAspect: AspectRatio? = nil,
                frameRate: FrameRate,
                interlace: InterlaceInfo = .progressive,
                color: ColorInfo = .unspecified,
                aspectSignals: AspectSignals = AspectSignals()) {
        self.codedSize = codedSize
        self.statedCleanAperture = statedCleanAperture
        self.sampleAspect = sampleAspect
        self.frameRate = frameRate
        self.interlace = interlace
        self.color = color
        self.aspectSignals = aspectSignals
    }

    /// known standard からのサンプルアスペクト比推定（05 §6 の 3）。
    /// SD DVD で一般的寸法だけを持つ。未知寸法では nil を返し、解決させない。
    public static func guessSampleAspect(codedSize: PixelSize) -> AspectRatio? {
        guard codedSize.width == 720 else { return nil }
        if codedSize.height == 480 { return .bt601NTSCSample }
        if codedSize.height == 576 { return .bt601Palsample }
        return nil
    }
}

public struct InterlaceInfo: Sendable, Hashable {
    public var fieldCount: Int16
    public var fieldOrder: FieldOrder
    public var cadence: Cadence

    public init(fieldCount: Int16, fieldOrder: FieldOrder, cadence: Cadence) {
        self.fieldCount = fieldCount
        self.fieldOrder = fieldOrder
        self.cadence = cadence
    }

    public static let progressive = InterlaceInfo(fieldCount: 0, fieldOrder: .progressive, cadence: .progressive)
    public static let ntscInterlaced = InterlaceInfo(fieldCount: 2, fieldOrder: .topFirst, cadence: .interlaced22)
    public static let palInterlaced = InterlaceInfo(fieldCount: 2, fieldOrder: .topFirst, cadence: .interlaced22)
    public static let telecine = InterlaceInfo(fieldCount: 2, fieldOrder: .topFirst, cadence: .telecine32)
    public static let unknown = InterlaceInfo(fieldCount: 2, fieldOrder: .unknown, cadence: .unknown)

    public var isInterlaced: Bool { fieldCount == 2 }
}

public enum Cadence: String, Sendable, CaseIterable {
    case progressive
    case interlaced22
    case telecine32
    case mixed
    case unknown
}

public enum FieldOrder: String, Sendable, CaseIterable {
    case topFirst
    case bottomFirst
    case progressive
    case unknown
}

public struct ColorInfo: Sendable, Hashable {
    public var primaries: ColorPrimaries
    public var transfer: TransferFunction
    public var matrix: MatrixCoefficients
    public var range: YCbCrRange
    /// メタデータが信用できるかの目印。false のとき 05 §3 の assumption を plan に焼き付ける。
    public var isStated: Bool

    public init(primaries: ColorPrimaries, transfer: TransferFunction,
                matrix: MatrixCoefficients, range: YCbCrRange, isStated: Bool) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.isStated = isStated
    }

    /// SD DVD の MPEG-2 で最も多い構成。assumption なので isStated = false。
    public static let unspecified = ColorInfo(primaries: .unspecified, transfer: .unspecified,
                                             matrix: .unspecified, range: .videoRange, isStated: false)
    public static let bt601VideoRange = ColorInfo(primaries: .bt601, transfer: .bt709,
                                                  matrix: .bt601, range: .videoRange, isStated: true)
}

public enum ColorPrimaries: String, Sendable { case bt601, bt709, smpte240, unspecified }
public enum TransferFunction: String, Sendable { case bt709, gamma22, linear, unspecified }
public enum MatrixCoefficients: String, Sendable { case bt601, bt709, fcc, unspecified }
public enum YCbCrRange: String, Sendable { case videoRange, fullRange }

/// 音声トラックの記述（#4）。
public struct AudioFormatDescription: Sendable, Hashable {
    public enum Codec: String, Sendable { case ac3, dts, lpcm16, aac, mp1, mp2, mp3, unknown }
    public var codec: Codec
    public var sampleRate: Int32
    public var channelCount: Int32
    public var bitDepth: Int32?
    public var bitrate: Int32?
    public var language: String?

    public init(codec: Codec, sampleRate: Int32, channelCount: Int32,
                bitDepth: Int32? = nil, bitrate: Int32? = nil, language: String? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.language = language
    }
}

/// 字幕トラックの記述（04 §7）。
public struct SubtitleFormatDescription: Sendable, Hashable {
    public enum Kind: String, Sendable { case dvdSPU, srt, webVTT, ass, tx3g, unknown }
    public var kind: Kind
    public var language: String?
    public var associatedAudioStream: Bool
    public init(kind: Kind, language: String? = nil, associatedAudioStream: Bool = false) {
        self.kind = kind
        self.language = language
        self.associatedAudioStream = associatedAudioStream
    }
}

public enum FormatDescription: Sendable, Hashable {
    case video(VideoFormatDescription)
    case audio(AudioFormatDescription)
    case subtitle(SubtitleFormatDescription)
    case unknown
}
