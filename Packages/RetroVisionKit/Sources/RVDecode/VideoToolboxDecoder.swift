import CoreMedia
import CoreVideo
import Foundation
import RVMediaCore
import VideoToolbox

// MARK: - VideoToolbox 復号（04 §3 の案 B）
//
// `VTDecompressionSession` を直接扱う。FFmpeg の hwdevice 経由（案 A）との比較は OQ-08。
// 案 B を先に置く理由: 出力の像素形式を要求できることと、メタデータの受け渡しを握れることが
// deinterlace・色処理の品質に直結するから（実測: docs/experiments/EXP-001）。
//
// 実装の約束（この SDK で確認した API 事実に基づく）:
//   - `VTDecompressionSessionDecodeFrameWithOutputHandler` を使う。options に non-blocking を
//     立てないため同期復号になり、出力はこの呼び出しが返る前に handler へ届く。
//     時刻の扱いが決定論的になる（09 §3）。非同期化の判断は decode 段の実測が取れてから（04 §9）。
//   - `VTDecompressionSessionCopyDestinationPool` はこの SDK に存在しない。
//     出力 pool は VideoToolbox の内部管理に任せ、返却の寿命管理は `DecodedVideoFrame.lease` と
//     pipeline 側のプールで行う（01 §4、05 §4）。
//   - 出力は提示順（PTS 昇順）に返す。B 帧で復号完了順と提示順が違うため、内部で並び替える。
//
// スレッド要件: 単一の直列キュー（decodeQueue）からのみ呼ぶ（00 §5）。
// lock/unlock を async 関数内で使えないため、状態へのアクセスは直列 queue 経由に統一する。
public final class VideoToolboxDecoder: VideoDecoder, @unchecked Sendable {
    public let path: DecodePath = .videoToolbox

    private let queue = DispatchQueue(label: "retrovision.decode.videotoolbox", qos: .userInteractive)
    private var policy = DecodePolicy()
    private var source: VideoFormatDescription?
    private var decoded: VideoFormatDescription?
    private var info = DecodePathInfo(path: .videoToolbox)

    private var session: VTDecompressionSession?
    /// sample に format description が無い容器のための差し替え口（04 §2 の実測）
    private var formatDescriptionHint: CMVideoFormatDescription?
    /// 提示順に出すための待機列（PTS 昇順を維持）。
    private var completed: [DecodedVideoFrame] = []
    private var frameCounter: UInt64 = 0
    private var lastError: PlaybackError?

    /// 復号に失敗した帧を数える（04 §9 の dropped 計上）。
    public var failedDecodeCount: Int { queue.sync { _failedDecodeCount } }
    private var _failedDecodeCount = 0

    public init() {}

    // MARK: VideoDecoder 契約

    public var pathInfo: DecodePathInfo { queue.sync { info } }
    public var sourceFormat: VideoFormatDescription? { queue.sync { source } }
    public var decodedFormat: VideoFormatDescription? { queue.sync { decoded } }

    public func configure(_ format: VideoFormatDescription, policy: DecodePolicy,
                         formatDescriptionHint: CMVideoFormatDescription?) async throws {
        let hintHolder = FormatDescriptionHolder(formatDescriptionHint)
        queue.sync {
            self.source = format
            self.policy = policy
            self.formatDescriptionHint = hintHolder.value
            self.completed.removeAll()
            self.lastError = nil
            if let session = self.session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
        }
        // session は最初の sample の format description（無ければ hint）から作る（容器側の記述を正とする）。
    }

    public func decode(_ sample: CompressedSample) async throws -> DecodedVideoFrame? {
        try makeSessionIfNeeded(for: sample)
        let session = queue.sync { self.session }
        guard let session else {
            throw PlaybackError.decode(.hwDecodeUnavailable, message: "復号器を作成できません",
                                       recovery: .retryWith(.softwareDecode))
        }

        var infoFlags = VTDecodeInfoFlags()
        // 実測: Swift 側の名前は `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)`
        // （C の …WithOutputHandler は renamed）。options を立てないので同期復号になる。
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample.sampleBuffer, flags: [], infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, imageBuffer, _, _ in
            guard let self else { return }
            // 実測: kVTDecodeInfo_FrameDropped は Swift から import されない（VTDecodeInfoFlags は
            // OptionSet として渡る）。bit 値で判定する（VTErrors.h の kVTDecodeInfo_FrameDropped = 1<<1）。
            if status != noErr || imageBuffer == nil || (flags.rawValue & (1 << 1)) != 0 {
                self.queue.sync {
                    self._failedDecodeCount += 1
                    self.lastError = PlaybackError.decode(
                        .corruptStream, message: "復号に失敗しました",
                        recovery: .retryWith(.softwareDecode),
                        cause: "VT status=\(status) flags=\(flags.rawValue)")
                }
                return
            }
            guard let imageBuffer else { return }
            self.accept(output: imageBuffer, for: sample)
        }
        if status != noErr {
            throw PlaybackError.decode(.corruptStream, message: "復号を要求できません",
                                       recovery: .retryWith(.softwareDecode),
                                       cause: "VTDecodeFrame status=\(status)")
        }
        // handler が失敗を記録していたら、次回の呼び出しに上げる前にここで返す（04 §3 の回復方針）
        let handlerFailure = queue.sync { () -> (String, PlaybackError)? in
            guard let error = self.lastError else { return nil }
            self.lastError = nil
            return (error.causeDescription ?? "", error)
        }
        if let (cause, error) = handlerFailure {
            throw PlaybackError(kind: error.kind, causeDescription: cause,
                                recovery: error.recovery, userMessage: error.userMessage,
                                diagnosticRef: error.diagnosticRef)
        }
        return takeNextPresentable()
    }

    public func flush() async -> [DecodedVideoFrame] {
        let session = queue.sync { self.session }
        if let session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        return queue.sync {
            let out = completed
            completed.removeAll()
            return out
        }
    }

    public func reset(at pts: MediaTime) async {
        let session = queue.sync { () -> VTDecompressionSession? in
            let session = self.session
            self.session = nil
            self.completed.removeAll()
            self.lastError = nil
            self.decoded = nil
            return session
        }
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    // MARK: 内部

    private func accept(output pixelBuffer: CVPixelBuffer, for sample: CompressedSample) {
        queue.sync {
            guard let source else { return }
            frameCounter += 1
            let description = VideoFormatDescription(decodedPixelBuffer: pixelBuffer, source: source)
            let frame = DecodedVideoFrame.make(
                id: FrameID(frameCounter),
                pixelBuffer: pixelBuffer,
                format: description,
                pts: sample.pts, duration: sample.duration, isKey: sample.isKey,
                onLeaseViolation: { _ in
                    // 資源の寿命違反は復号側の責任として数える（01 §4、08 §3 の leaseViolation）。
                })
            decoded = description
            // 提示順に出すため PTS 昇順で挿入する。
            let index = completed.firstIndex { $0.pts.compared(to: frame.pts) == .orderedDescending }
                ?? completed.endIndex
            completed.insert(frame, at: index)
        }
    }

    /// 次に提示すべき frame を取り出す。まだ復号が追いついていなければ nil（04 §3 の契約）。
    ///
    /// 実測（docs/experiments/EXP-001、B 帧のある素材）: 同期 decode では出力が **decode 順**で
    /// handler を通る。挿入並べ替えだけでは、後から来る B 帧より先に P 帧が先頭として出てしまい、
    /// presentation 順が壊れる（統合テストで検出された。3003 が 9009 の後に来る等）。
    /// B 帧は anchor の decode より前に供給される（GOP の decode 順の構造）ため、
    /// **「次に供給される sample が現れるまで先頭を出さない」**（= completed が 2 件以上あるときだけ
    /// 先頭を取り出す）で、GOP の深さに関係なく presentation 順が成立する。
    /// 残余は flush() が昇順のまま取り出す。
    private func takeNextPresentable() -> DecodedVideoFrame? {
        queue.sync {
            guard completed.count >= 2 else { return nil }
            return completed.removeFirst()
        }
    }

    private func makeSessionIfNeeded(for sample: CompressedSample) throws {
        if queue.sync(execute: { self.session != nil }) { return }
        let formatDescription = sample.videoFormatDescription ?? queue.sync { self.formatDescriptionHint }
        guard let formatDescription else {
            throw PlaybackError.decode(.formatRejected, message: "復号に必要な形式情報がありません",
                                       recovery: .giveUp(reason: "format"))
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        var destination: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): policy.requestedOutputPixelFormat,
            String(kCVPixelBufferWidthKey): Int(dimensions.width),
            String(kCVPixelBufferHeightKey): Int(dimensions.height),
            String(kCVPixelBufferIOSurfacePropertiesKey): [:],
            String(kCVPixelBufferMetalCompatibilityKey): true,
        ]
        // 色域の指定は source が知っているときだけ（05 §3 の assumption は plan を作る側で決める）。
        // 像素形式と同じ語彙（kCVImageBuffer*）を使う。kCVPixelBuffer*ColorPrimariesKey は存在しない。
        if let source, source.color.isStated {
            switch source.color.primaries {
            case .bt709: destination[MediaAttachmentKey.colorPrimaries] = MediaAttachmentValue.primariesBT709
            case .bt601EBU: destination[MediaAttachmentKey.colorPrimaries] = MediaAttachmentValue.primariesEBU3213
            case .bt601SMPTEC: destination[MediaAttachmentKey.colorPrimaries] = MediaAttachmentValue.primariesSMPTEC
            case .bt2020: destination[MediaAttachmentKey.colorPrimaries] = MediaAttachmentValue.primariesBT2020
            default: break
            }
            if source.color.transfer != .unspecified {
                destination[MediaAttachmentKey.transferFunction] = Self.transferValue(of: source.color.transfer)
            }
            if source.color.matrix != .unspecified {
                destination[MediaAttachmentKey.ycbcrMatrix] = Self.matrixValue(of: source.color.matrix)
            }
        }

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destination as CFDictionary,
            outputCallback: nil,          // block 版を使うときは nil（04 §3）
            decompressionSessionOut: &sessionOut)
        let codecName = FourCC.string(CMFormatDescriptionGetMediaSubType(formatDescription))
        guard status == noErr, let created = sessionOut else {
            queue.sync {
                info = DecodePathInfo(path: .videoToolbox,
                                      reason: "session create status=\(status)",
                                      codecName: codecName)
            }
            throw PlaybackError.decode(.hwDecodeUnavailable, message: "ハードウェア復号を使用できません",
                                       recovery: .retryWith(.softwareDecode),
                                       cause: "VTDecompressionSessionCreate status=\(status)")
        }
        queue.sync {
            session = created
            info = DecodePathInfo(path: .videoToolbox, reason: nil, codecName: codecName)
        }
    }

    private static func transferValue(of transfer: TransferFunction) -> String {
        switch transfer {
        case .bt709OrBT601: return MediaAttachmentValue.transferBT709
        case .sRGB: return MediaAttachmentValue.transferSRGB
        case .pq: return MediaAttachmentValue.transferPQ
        case .hlg: return MediaAttachmentValue.transferHLG
        case .linear: return MediaAttachmentValue.transferLinear
        default: return MediaAttachmentValue.transferBT709
        }
    }

    private static func matrixValue(of matrix: MatrixCoefficients) -> String {
        switch matrix {
        case .bt601_4: return MediaAttachmentValue.matrixBT601
        case .bt709_2: return MediaAttachmentValue.matrixBT709
        case .smpte240M: return MediaAttachmentValue.matrixSMPTE240M
        case .bt2020NonConstantLuminance: return MediaAttachmentValue.matrixBT2020
        default: return MediaAttachmentValue.matrixBT601
        }
    }
}
