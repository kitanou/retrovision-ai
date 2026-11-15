import Foundation

// MARK: - MPEG-2 ビットストリームからの信号取得（01 §2、05 §6）
//
// AVFoundation / VideoToolbox は MPEG-2 のメタデータ（frame rate・field 符号化・色）を
// 常に渡すとは限らない（実測: docs/experiments/EXP-001）。その場合に備えて、sample の ES
// バイト列から直接信号を読む経路を持つ。推測で埋めないための準備。

/// sequence_header() と、その直後にある sequence 層 extension から読める情報。
/// GOP / picture unit の per-frame 信号（field 順）は MPEG2PictureCodingExtension を使う。
public struct MPEG2SequenceHeader: Sendable, Hashable {
    public var horizontalSize: Int
    public var verticalSize: Int
    public var aspectRatioInformation: AspectSignals.MPEGAspectInfo?
    public var frameRate: FrameRate?
    public var progressiveSequence: Bool
    public var chromaFormat: Int          // sequence_extension(): 1=4:2:0 2=4:2:2 3=4:4:4
    public var bitRateValue: Int
    public var constrainedParameterFlag: Bool

    // sequence_extension()（profile / level は表の診断に使うが、plan 段では使わない）
    public var profile: Int?
    public var level: Int?

    // sequence_display_extension()
    public var displayExtensionPresent: Bool
    public var displayVideoFormat: Int?
    public var displayColourDescription: Bool
    /// 8 bit の MPEG-2 色 code（ISO/IEC 13818-2 Table 6-5 footnote の語彙。
    /// ColorPrimaries  enum とは別体系なので raw value のまま保持し、変換は 05 §6 の解決表で行う）。
    public var displayColorPrimaries: Int?
    public var displayTransferCharacteristics: Int?
    public var displayMatrixCoefficients: Int?
    public var displayHorizontalSize: Int?
    public var displayVerticalSize: Int?

    /// aspect_ratio_information から目標 DAR（ISO/IEC 13818-2 Table 6-3）。
    public static func dar(for info: AspectSignals.MPEGAspectInfo?) -> AspectRatio? {
        switch info {
        case .dar4x3: return .dar4x3
        case .dar16x9: return .dar16x9
        case .dar2p21x1: return .dar2p21x1
        case .unspecified, .none: return nil
        }
    }

    /// frame_rate_code の表（ISO/IEC 13818-2 Table 6-7、MPEG-1 からの踏襲）。
    /// 実測（docs/experiments/EXP-001）: 生成した 24/25/29.97 の各素材が書き込む code は
    /// それぞれ 2 / 3 / 4 で、この表と一致する。DVD で出てくるのは 3（PAL）と 4（NTSC）だけ。
    /// extension を伴う高い frame rate（code 9 以上）は SD 素材に現れないため未対応。
    public static func baseFrameRate(forCode code: Int) -> FrameRate? {
        switch code {
        case 2: return .film24      // 24/1
        case 3: return .pal         // 25/1
        case 4: return .ntsc        // 30000/1001
        case 5: return FrameRate(value: 30)
        case 6: return FrameRate(value: 50)
        case 7: return FrameRate(value: 60)
        default: return nil
        }
    }

    /// 目標 DAR の符号。sequence_extension / display_extension は aspect を含まないため
    /// sequence_header のものだけを使う（display size は pan-scan 用の別情報。実測でも coded size と同値）。
    public var effectiveDisplayAspect: AspectSignals.MPEGAspectInfo? { aspectRatioInformation }
}

/// picture_coding_extension()（000001B5 + identifier 1000）の per-frame 符号化信号。
/// 実測（docs/experiments/EXP-001）: MPEG-2 では field 順・progressive 判定は picture 层にしかない。
/// VideoToolbox の出力 attachment には field order が残らない（fieldCount のみ）ため、
/// 05 §4 の plan 段で field 順を決める唯一の信頼できる情報源になる。
public struct MPEG2PictureCodingExtension: Sendable, Hashable {
    public var pictureStructure: Int      // 1=top field 2=bottom field 3=frame
    public var topFieldFirst: Bool
    public var repeatFirstField: Bool
    public var progressiveFrame: Bool
}

public enum MPEG2Bitstream {
    /// `Data` の中から最初の sequence_header() を探す。program stream・ES のどちらでも使える。
    public static func sequenceHeader(in data: Data) -> MPEG2SequenceHeader? {
        var reader = BitReader(data)
        while reader.remainingBits >= 32 {
            guard let code = reader.peekBits(32) else { break }
            let payload = Int(code & 0xFF)
            if payload == 0xB3 {
                guard reader.readBits(32) != nil else { break }
                return parseSequenceHeader(&reader)
            }
            guard reader.skipBits(8) else { break }
        }
        return nil
    }

    /// 最初の access unit などから picture_coding_extension() を読む（field 順の決定用）。
    public static func pictureCodingExtension(in data: Data) -> MPEG2PictureCodingExtension? {
        var r = BitReader(data)
        func bits(_ n: Int) -> Int? { r.readBits(n).map { Int($0) } }
        while r.remainingBits >= 36 {
            guard let code = r.peekBits(32) else { break }
            guard Int(code & 0xFF) == 0xB5, r.readBits(32) != nil, let id = bits(4) else {
                guard r.skipBits(8) else { break }
                continue
            }
            if id == 0x8 {
                // payload は identifier の直後から始まる（f_code の先 4 bit は identifier と
                // 同じ byte にある。実測で確認: ここを byte 境界に寄せると 4 bit ずれて
                // picture_structure が 0 などの無意味な値になる）。
                guard bits(16) != nil,                  // f_code ×4（値は使わない）
                      bits(2) != nil,                   // intra_dc_precision
                      let structure = bits(2),
                      let tff = bits(1), bits(1) != nil,       // top_field_first, frame_pred_frame_dct
                      bits(1) != nil, bits(1) != nil,          // concealment, q_scale_type
                      bits(1) != nil, bits(1) != nil,          // intra_vlc_format, alternate_scan
                      let repeatFirst = bits(1), bits(1) != nil,  // repeat_first_field, chroma_420_type
                      let progFrame = bits(1) else { return nil }
                return MPEG2PictureCodingExtension(pictureStructure: structure,
                                                  topFieldFirst: tff == 1,
                                                  repeatFirstField: repeatFirst == 1,
                                                  progressiveFrame: progFrame == 1)
            }
            // 8 でない extension は byte 境界に見送って次の start code を探す。
            guard r.alignToByte() else { break }
            // 他の extension（quant matrix など）の中で 000001B5 と同じ byte 列が現れることは
            // SD 素材では実測されていない。byte スキャンで次の extension へ進む。
        }
        return nil
    }

    /// sequence_header() の核心部 + sequence 层 extension。
    ///
    /// 実測で確定した構文（docs/experiments/EXP-001: 生成素材のバイト列を ffprobe の
    /// profile / level / r_frame_rate / field_order / 帧単位の top_field_first とバイト単位で照合。
    /// ffmpeg の mpeg12enc.c / mpeg12dec.c の読み書きと一致）:
    ///   - bit_rate の後ろに marker_bit、vbv_buffer_size の後ろにも marker_bit がある。
    ///     消費しないと以降が 1 bit ずつずれる。
    ///   - constrained_parameters_flag == 0 でも、MPEG-2 追加 header フィールド
    ///     （video_format / progressive_sequence / color_description / display_extension、
    ///     ISO 6.2.2.2）を書かない符号化器がある（ffmpeg は byte 境界まで padding して
    ///     directly extension へ進む）。そのため核心部より後ろを bit で辿らず、
    ///     byte 位置の start code 000001B5 から extension を読む（どちらの形状でも読める）。
    ///   - 全ての sequence / picture 层 extension は 000001B5 + identifier 4 bit で区別される
    ///     （0001=sequence_extension, 0010=sequence_display_extension, 1000=picture_coding_extension。
    ///     000001B8 は GOP header であり extension ではない）。
    ///   - sequence_extension() = esc(1) profile(3) level(4) progressive_sequence(1) chroma_format(2)
    ///     拡張サイズ(2+10+2+10) bit_rate_extension(12) marker_bit(1) vbv_delay_extension(18)
    ///     low_delay(1) frame_rate_extension_n(2) frame_rate_extension_d(5)。
    ///     実測では拡張サイズ=0,0 vbv_delay_extension=0 low_delay=0（SD 素材の定型）。
    ///   - sequence_display_extension() = video_format(3) colour_description(1)
    ///     [colour_primaries(8) transfer_characteristics(8) matrix_coefficients(8)]
    ///     display_horizontal_size(14) marker_bit display_vertical_size(14)。
    ///     生成素材の code は 2,2,2（= unspecified）。VideoToolbox が SD MPEG-2 に bt709 を
    ///     付帯させるのはこの状態での推測（ColorInfoGuessedBy 付き）なので計画段では信用しない（05 §3）。
    ///   - field 符号化でも sequence_extension の top_field_first は無い（picture 层の信号）。
    ///     ffmpeg の書く field 符号化素材は progressive_sequence=0 + 帧単位 top_field_first=0
    ///     （ffprobe の field_order=bb）だった。
    private static func parseSequenceHeader(_ r: inout BitReader) -> MPEG2SequenceHeader? {
        func bits(_ n: Int) -> Int? { r.readBits(n).map { Int($0) } }
        guard let h = bits(12), let v = bits(12),
              let aspectCode = bits(4), let frameRateCode = bits(4),
              let bitRate = bits(18), bits(1) != nil,              // marker_bit（実測: 必須）
              bits(10) != nil, bits(1) != nil,                     // vbv_buffer_size + marker_bit
              let constrained = bits(1) else { return nil }
        var header = MPEG2SequenceHeader(
            horizontalSize: h, verticalSize: v,
            aspectRatioInformation: aspectInfo(aspectCode),
            frameRate: MPEG2SequenceHeader.baseFrameRate(forCode: frameRateCode),
            progressiveSequence: false, chromaFormat: 1,
            bitRateValue: bitRate, constrainedParameterFlag: constrained == 1,
            profile: nil, level: nil,
            displayExtensionPresent: false, displayVideoFormat: nil, displayColourDescription: false,
            displayColorPrimaries: nil, displayTransferCharacteristics: nil, displayMatrixCoefficients: nil,
            displayHorizontalSize: nil, displayVerticalSize: nil)

        // extension_and_user_data(0) を byte 位置で歩き、sequence_extension と
        // sequence_display_extension だけを読む。start code は常に byte 境界に現れるため、
        // 核心部（63 bit + 符号化器依存の追加フィールド）の直後は byte 境界に寄せる。
        // 途中の追加フィールド（ISO 6.2.2.2 の video_format など）は byte スキャンで読み飛ばす。
        var sawSeqExtension = false, sawDisplayExtension = false
        guard r.alignToByte() else { return header }
        while r.remainingBits >= 36 {
            guard let code = r.peekBits(32) else { break }
            let payload = Int(code & 0xFF)
            guard payload == 0xB5 else {
                guard r.skipBits(8) else { return header }
                continue
            }
            guard r.readBits(32) != nil, let extID = bits(4) else { return header }
            switch extID {
            case 0x1:   // sequence_extension()
                bits(1)                              // esc
                header.profile = bits(3)
                header.level = bits(4)
                let progSeq = bits(1)
                header.chromaFormat = bits(2) ?? header.chromaFormat
                header.progressiveSequence = progSeq == 1
                // chroma_format より後ろ（拡張サイズ・vbv_delay_extension）は、規格文法と
                // ffmpeg 実装で bit 数が違う（拡張は次の start code で再同期されるため後続の
                // 其他信号には影響しない）。frame_rate_extension は code 8 以上の高いレート
                // 専用で SD 素材には現れないため読まない（実測素材でも n/d は 0）。
                guard r.alignToByte() else { return header }   // 残りの padding/未使用部をスキップ
                sawSeqExtension = true
                if sawDisplayExtension { return header }
            case 0x2:   // sequence_display_extension()
                header.displayExtensionPresent = true
                header.displayVideoFormat = bits(3)
                let colorDesc = bits(1)
                header.displayColourDescription = colorDesc == 1
                if colorDesc == 1 {
                    header.displayColorPrimaries = bits(8)
                    header.displayTransferCharacteristics = bits(8)
                    header.displayMatrixCoefficients = bits(8)
                }
                let displayW = bits(14)
                bits(1)                              // marker_bit
                let displayH = bits(14)
                header.displayHorizontalSize = displayW
                header.displayVerticalSize = displayH
                guard r.alignToByte() else { return header }
                sawDisplayExtension = true
                if sawSeqExtension { return header }
            default:    // quant matrix / user data など。SD 素材で必要な信号は含まないが、
                        // 語彙が不明なだけで後ろに display extension が続く場合があるため、
                        // byte 境界に寄走って次の extension を探し続ける（start code は escape で
                        // 偽装されない: slice / user data 内に 000001 が現れないため誤検出しない）。
                guard r.alignToByte() else { return header }
                continue
            }
        }
        return header
    }

    private static func aspectInfo(_ code: Int) -> AspectSignals.MPEGAspectInfo? {
        AspectSignals.MPEGAspectInfo(rawValue: Int32(code))
    }
}
