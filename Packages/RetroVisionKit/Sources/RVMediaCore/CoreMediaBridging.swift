import CoreMedia
import CoreVideo
import Foundation

// MARK: - CoreMedia / CoreVideo の記述を、プロジェクトの論理記述に翻訳する（01 §2）
//
// INV-3 の前提: 翻訳は 1 か所でだけ行う。pipeline と UI は `VideoFormatDescription` だけを見る。
//
// 実測の方針（docs/experiments/EXP-001）:
//   - MPEG-2 では clean aperture・pixel aspect・field 情報・色の attachment が欠けることがある。
//     欠けているものを推測で埋めない。補完は AspectResolver と色 assumption の段だけで行う（05 §3、§6）。
//   - 容器が渡さない場合、MPEG-2 は verbatim の sample description（sequence header）から取る経路を持つ。
//
// 実測の型事実（この SDK で確認）:
//   - `kCVImageBuffer*Key` などの定数は Swift では CFString として import される。
//     `[String: Any]` の key として使うには `as String` が必要（忘れると subscript が解決できない）。
//   - 値側（color primaries などの文字列）も CFString。String として読むのはこの 1 か所に閉じる。

/// attachment / extension の key・値の文字列。
/// 実測の型事実: `kCVImageBuffer*Key` などの C 定数は Swift では CFString として import される。
/// CFString をそのまま String 期待の値や dictionary key に使うと
/// 「expression pattern of type CFString cannot match values of type String」などで失敗する
/// （`as String` は pattern 文脈では効かない）。`String(... as NSString)` で先に文字列化する。
/// key 名・値語彙の対応表はこの 1 か所にだけ置く（INV-3）。
public enum MediaAttachmentKey {
    public static let cleanAperture = String(kCVImageBufferCleanApertureKey as NSString)
    public static let cleanApertureWidth = String(kCVImageBufferCleanApertureWidthKey as NSString)
    public static let cleanApertureHeight = String(kCVImageBufferCleanApertureHeightKey as NSString)
    public static let cleanApertureHorizontalOffset = String(kCVImageBufferCleanApertureHorizontalOffsetKey as NSString)
    public static let cleanApertureVerticalOffset = String(kCVImageBufferCleanApertureVerticalOffsetKey as NSString)

    public static let pixelAspectRatio = String(kCVImageBufferPixelAspectRatioKey as NSString)
    public static let pixelAspectRatioHorizontalSpacing = String(kCVImageBufferPixelAspectRatioHorizontalSpacingKey as NSString)
    public static let pixelAspectRatioVerticalSpacing = String(kCVImageBufferPixelAspectRatioVerticalSpacingKey as NSString)

    public static let fieldCount = String(kCVImageBufferFieldCountKey as NSString)
    public static let fieldDetail = String(kCVImageBufferFieldDetailKey as NSString)

    public static let colorPrimaries = String(kCVImageBufferColorPrimariesKey as NSString)
    public static let transferFunction = String(kCVImageBufferTransferFunctionKey as NSString)
    public static let ycbcrMatrix = String(kCVImageBufferYCbCrMatrixKey as NSString)

    public static let verbatimSampleDescription = String(kCMFormatDescriptionExtension_VerbatimSampleDescription as NSString)
}

/// attachment 値が取りうる文字列（CoreVideo の定数と同じ語彙。翻訳表の右辺）
public enum MediaAttachmentValue {
    public static let fieldDetailTopFirst = String(kCVImageBufferFieldDetailTemporalTopFirst as NSString)
    public static let fieldDetailBottomFirst = String(kCVImageBufferFieldDetailTemporalBottomFirst as NSString)

    public static let primariesBT709 = String(kCVImageBufferColorPrimaries_ITU_R_709_2 as NSString)
    public static let primariesEBU3213 = String(kCVImageBufferColorPrimaries_EBU_3213 as NSString)
    public static let primariesSMPTEC = String(kCVImageBufferColorPrimaries_SMPTE_C as NSString)
    public static let primariesBT2020 = String(kCVImageBufferColorPrimaries_ITU_R_2020 as NSString)

    public static let transferBT709 = String(kCVImageBufferTransferFunction_ITU_R_709_2 as NSString)
    public static let transferSRGB = String(kCVImageBufferTransferFunction_sRGB as NSString)
    public static let transferPQ = String(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as NSString)
    public static let transferHLG = String(kCVImageBufferTransferFunction_ITU_R_2100_HLG as NSString)
    public static let transferLinear = String(kCVImageBufferTransferFunction_Linear as NSString)

    public static let matrixBT601 = String(kCVImageBufferYCbCrMatrix_ITU_R_601_4 as NSString)
    public static let matrixBT709 = String(kCVImageBufferYCbCrMatrix_ITU_R_709_2 as NSString)
    public static let matrixSMPTE240M = String(kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as NSString)
    public static let matrixBT2020 = String(kCVImageBufferYCbCrMatrix_ITU_R_2020 as NSString)
}

/// attachment / extension 辞書。呼び出し側には文字列 key で渡す。
public struct AttachmentValues {
    let dictionary: [String: Any]

    public init(_ dictionary: CFDictionary?) {
        self.dictionary = (dictionary as? [String: Any]) ?? [:]
    }

    public init(_ dictionary: [String: Any]?) {
        self.dictionary = dictionary ?? [:]
    }

    public subscript(_ key: String) -> Any? { dictionary[key] }
    public func number(_ key: String) -> NSNumber? { dictionary[key] as? NSNumber }
    public func string(_ key: String) -> String? { (dictionary[key] as? NSString) as String? }
    public func dictionaryValue(_ key: String) -> [String: Any]? { dictionary[key] as? [String: Any] }
    public func data(_ key: String) -> Data? { dictionary[key] as? Data }
    public var keys: [String] { dictionary.keys.sorted() }
}

extension VideoFormatDescription {
    /// attachment として付いていた key 名（実験・診断の記録用。値は解釈しない）。
    public static func attachmentKeyNames(of pixelBuffer: CVPixelBuffer) -> [String] {
        AttachmentValues(CVBufferCopyAttachments(pixelBuffer, .shouldPropagate)).keys
    }

    /// demux が渡す format description（AVFoundation / VideoToolbox 側の形）から作る。
    ///
    /// - Parameter frameRateHint: 容器側が有理数で知っているフレームレート（AVAssetTrack の timescale 等）。
    ///   有理数が取れる場所では必ず hint 経由で渡すこと（01 §2）。
    public init(sampleFormatDescription fd: CMFormatDescription, frameRateHint: FrameRate? = nil) {
        let size = CMVideoFormatDescriptionGetDimensions(fd)
        let ext = AttachmentValues(CMFormatDescriptionGetExtensions(fd))
        let coded = PixelSize(width: size.width, height: size.height)

        var signals = AspectSignals()
        signals.statedCleanAperture = Self.cleanAperture(
            ext.dictionaryValue(MediaAttachmentKey.cleanAperture),
            coded: coded)
        signals.sampleAspectFromStandard = Self.pixelAspectRatio(
            ext.dictionaryValue(MediaAttachmentKey.pixelAspectRatio))

        var interlace = Self.interlace(ext)
        var frameRate = frameRateHint

        // 容器が MPEG-2 のメタデータを渡さない場合、verbatim の sequence header から取る。
        if CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_MPEG2Video,
           let verbatim = ext.data(MediaAttachmentKey.verbatimSampleDescription),
           let header = MPEG2Bitstream.sequenceHeader(in: verbatim) {
            if signals.mpegAspectInformation == nil {
                signals.mpegAspectInformation = header.effectiveDisplayAspect
            }
            if frameRate == nil { frameRate = header.frameRate }
            if !interlace.isInterlaced, !header.progressiveSequence {
                // field 順序は picture 层の信号（MPEG2PictureCodingExtension）で、format 段には無い。
                // 実測（docs/experiments/EXP-001）: flag 無し時の既定は下位フィールド先行（ffprobe の
                // field_order=bb）。05 §4 の plan 段で per-frame の PCE を読み直して確定させる。
                interlace = InterlaceInfo(fieldCount: 2,
                                          fieldOrder: .bottomFirst,
                                          cadence: .unknown, fieldSource: .formatDescription)
            }
        }

        self.init(
            codedSize: coded,
            statedCleanAperture: signals.statedCleanAperture,
            sampleAspect: signals.sampleAspectFromStandard,
            frameRate: frameRate,   // 取れなければ nil のまま。呼び出し側が .formatRejected で断る（01 §2）
            interlace: interlace,
            color: Self.color(ext),
            aspectSignals: signals,
            rawFormatType: CMFormatDescriptionGetMediaSubType(fd)
        )
    }

    /// 復号出力の pixel buffer から、実際に得られた記述を作る（04 §3 の実測点）。
    ///
    /// 復号器が attachment を変換・破棄していることがあるため、`source` との差分を診断に出すのは
    /// 呼び出し側（probe・統合テスト）に任せる。
    public init(decodedPixelBuffer pb: CVPixelBuffer, source: VideoFormatDescription) {
        var desc = source
        let ext = AttachmentValues(CVBufferCopyAttachments(pb, .shouldPropagate))
        if let field = ext.number(MediaAttachmentKey.fieldCount)?.int16Value, field >= 2 {
            let detail = ext.string(MediaAttachmentKey.fieldDetail)
            desc.interlace = InterlaceInfo(
                fieldCount: field,
                fieldOrder: detail == MediaAttachmentValue.fieldDetailTopFirst ? .topFirst
                          : (detail == MediaAttachmentValue.fieldDetailBottomFirst ? .bottomFirst : .unknown),
                cadence: source.interlace.cadence,
                fieldSource: .decodedBufferAttachment)
        } else if source.interlace.isInterlaced {
            // 源は interlaced なのに、出力の buffer に field 情報が付かなかった。
            desc.interlace = InterlaceInfo(fieldCount: 0, fieldOrder: .progressive,
                                           cadence: source.interlace.cadence, fieldSource: .lostByDecoder)
        }
        if let par = ext.dictionaryValue(MediaAttachmentKey.pixelAspectRatio),
           let aspect = Self.pixelAspectRatio(par) {
            desc.sampleAspect = aspect
        }
        let parsed = Self.color(ext)
        if parsed.isStated { desc.color = parsed }
        self.init(codedSize: desc.codedSize, statedCleanAperture: desc.statedCleanAperture,
                  sampleAspect: desc.sampleAspect, frameRate: desc.frameRate,
                  interlace: desc.interlace, color: desc.color, aspectSignals: desc.aspectSignals,
                  rawFormatType: desc.rawFormatType)
    }

    // MARK: 個別項目

    /// clean aperture。offset は「画像中心からのオフセット」（SDK の定義）。top-left 系には換算しない。
    private static func cleanAperture(_ dict: [String: Any]?, coded: PixelSize) -> PixelRect? {
        let values = AttachmentValues(dict)
        guard let w = values.number(MediaAttachmentKey.cleanApertureWidth)?.int32Value,
              let h = values.number(MediaAttachmentKey.cleanApertureHeight)?.int32Value,
              let horiz = values.number(MediaAttachmentKey.cleanApertureHorizontalOffset)?.int32Value,
              let vert = values.number(MediaAttachmentKey.cleanApertureVerticalOffset)?.int32Value,
              w > 0, h > 0 else { return nil }
        // rect の中点を image buffer の中点 + offset に置く形で作る。
        let centerX = Int32(coded.width / 2) + horiz
        let centerY = Int32(coded.height / 2) + vert
        return PixelRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
    }

    /// pixel aspect ratio（horizontal / vertical spacing）。1:1 は「情報なし」と同じなので nil。
    private static func pixelAspectRatio(_ dict: [String: Any]?) -> AspectRatio? {
        let values = AttachmentValues(dict)
        let h = values.number(MediaAttachmentKey.pixelAspectRatioHorizontalSpacing)?.int32Value
        let v = values.number(MediaAttachmentKey.pixelAspectRatioVerticalSpacing)?.int32Value
        guard let h, let v, h > 0, v > 0, h != v else { return nil }
        return AspectRatio(w: h, h: v)
    }

    private static func interlace(_ ext: AttachmentValues) -> InterlaceInfo {
        let fieldCount = ext.number(MediaAttachmentKey.fieldCount)?.int16Value ?? 0
        guard fieldCount >= 2 else { return .progressive }
        switch ext.string(MediaAttachmentKey.fieldDetail) {
        case MediaAttachmentValue.fieldDetailTopFirst:
            return InterlaceInfo(fieldCount: fieldCount, fieldOrder: .topFirst, cadence: .unknown,
                                 fieldSource: .formatDescription)
        case MediaAttachmentValue.fieldDetailBottomFirst:
            return InterlaceInfo(fieldCount: fieldCount, fieldOrder: .bottomFirst, cadence: .unknown,
                                 fieldSource: .formatDescription)
        default:
            return .unknown
        }
    }

    private static func color(_ ext: AttachmentValues) -> ColorInfo {
        let primaries = ext.string(MediaAttachmentKey.colorPrimaries).flatMap(primaries(from:)) ?? .unspecified
        let transfer = ext.string(MediaAttachmentKey.transferFunction).flatMap(transfer(from:)) ?? .unspecified
        let matrix = ext.string(MediaAttachmentKey.ycbcrMatrix).flatMap(matrix(from:)) ?? .unspecified
        let stated = primaries != .unspecified || transfer != .unspecified || matrix != .unspecified
        return ColorInfo(primaries: primaries, transfer: transfer, matrix: matrix,
                         range: .videoRange, isStated: stated)
    }

    private static func primaries(from s: String) -> ColorPrimaries? {
        switch s {
        case MediaAttachmentValue.primariesBT709: return .bt709
        case MediaAttachmentValue.primariesEBU3213: return .bt601EBU
        case MediaAttachmentValue.primariesSMPTEC: return .bt601SMPTEC
        case MediaAttachmentValue.primariesBT2020: return .bt2020
        default: return nil
        }
    }

    private static func transfer(from s: String) -> TransferFunction? {
        switch s {
        case MediaAttachmentValue.transferBT709: return .bt709OrBT601
        case MediaAttachmentValue.transferSRGB: return .sRGB
        case MediaAttachmentValue.transferPQ: return .pq
        case MediaAttachmentValue.transferHLG: return .hlg
        case MediaAttachmentValue.transferLinear: return .linear
        default: return nil
        }
    }

    private static func matrix(from s: String) -> MatrixCoefficients? {
        switch s {
        case MediaAttachmentValue.matrixBT601: return .bt601_4
        case MediaAttachmentValue.matrixBT709: return .bt709_2
        case MediaAttachmentValue.matrixSMPTE240M: return .smpte240M
        case MediaAttachmentValue.matrixBT2020: return .bt2020NonConstantLuminance
        default: return nil
        }
    }

    // フレームレートの最終手段は置かない。
    // 容器の hint（AVAssetTrack の nominalFrameRate）・MPEG-2 の sequence header・PTS 積算のいずれでも
    // 決まらなかった素材は、ここで `.ntsc` などに倒さず nil のまま返し、demux 側が `.formatRejected` で断る（01 §2）。
}

extension AudioFormatDescription {
    /// demux が渡す音声 format description から作る（04 §2）。
    public init(sampleFormatDescription fd: CMFormatDescription) {
        let srd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        let subType = CMFormatDescriptionGetMediaSubType(fd)
        self.init(
            codec: Self.codec(forSubType: subType),
            rawFormatType: UInt32(truncatingIfNeeded: subType),
            sampleRate: Int32(srd?.mSampleRate ?? 0),
            channelCount: Int32(srd?.mChannelsPerFrame ?? 0),
            bitDepth: srd == nil ? nil : Int32(srd!.mBitsPerChannel),
            bitrate: nil,
            language: nil
        )
    }

    /// 音声の sub type → codec。未知のものは `.unknown` のまま `rawFormatType` に code を残す
    /// （推測で AC3 にしない。#4 の診断で code を表示できる）。
    private static func codec(forSubType code: FourCharCode) -> Codec {
        switch code {
        case FourCC.code("ac-3"), FourCC.code("ac3 "): return .ac3
        case FourCC.code("dtsh"), FourCC.code("dts "): return .dts
        case FourCC.code("mp4a"): return .aac
        case FourCC.code("mp2f"), FourCC.code("mp2c"), FourCC.code("mp2 "): return .mp2
        case FourCC.code(".mp3"), FourCC.code("MP3 "): return .mp3
        case FourCC.code("lpcm"): return .lpcm16
        default: return .unknown
        }
    }
}

/// 4 文字の codec code（'ac-3' のような sub type を書くため。CoreAudio の定数を import しない）。
public enum FourCC {
    public static func callAsFunction(_ s: String) -> FourCharCode { code(s) }

    public static func code(_ s: String) -> FourCharCode {
        let units = Array(s.unicodeScalars)
        precondition(units.count == 4, "four character code required: \(s)")
        var value: FourCharCode = 0
        for u in units { value = (value << 8) | FourCharCode(u.value & 0xFF) }
        return value
    }

    /// 診断表示用（印字できない文字は '?'）。
    public static func string(_ code: some BinaryInteger) -> String {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes: [UInt8] = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "?" })
    }
}
