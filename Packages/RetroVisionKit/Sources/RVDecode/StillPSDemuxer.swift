import CoreMedia
import Foundation
import RVMediaCore

// MARK: - 静止画 1 枚だけの MPEG-2 program stream（DVD のタイトルメニュー。VTS_nn_0.VOB）
//
// 実測（2026-11-17、PICHI_PICHI_PITCH1.ISO の VTS_01_0.VOB。235 KB）: 映像は sequence_header・
// GOP・I picture 1 枚・sequence_end だけで、ffmpeg は読めるが、**AVFoundation は長さが不定
// （NaN）のまま sample を 1 枚も渡さない**（同じファイルを 2〜3 回つないでも変わらない）。
// 次の picture の開始を見て初めて前の picture を確定する作りで、静止画のメニューはこれに当たる。
//
// そこで AVFoundation を通さず、program stream から**映像の ES（PES の payload）を自前で取り出し**、
// 1 枚の access unit として VideoToolbox へ渡す。字幕（ボタンの絵・ハイライト）、音声、NAV pack は
// 読まない（ボタンの操作は未実装）。映像の PES は 0xE0〜0xEF。DVD の program stream は
// pack header（0xBA）→ system header（0xBB）→ PES / private stream の並び。

public actor StillPSDemuxer: Demuxer {
    private let url: URL
    private var loaded: Loaded?

    private struct Loaded {
        var elementaryStream: Data
        var header: MPEG2SequenceHeader
        var format: VideoFormatDescription
        var frameDuration: CMTime
    }

    public init(url: URL) { self.url = url }

    private static let videoTrack = TrackID(1)

    // MARK: Demuxer

    public func probe() async throws -> ProbedStream {
        let loaded = try load()
        let track = TrackInfo(id: Self.videoTrack, kind: .video, format: .video(loaded.format), isDefault: true)
        return ProbedStream(tracks: [track], programDuration: loaded.frameDuration)
    }

    public var streamInfo: ProbedStream {
        get async { (try? await probe()) ?? ProbedStream(tracks: []) }
    }

    public func samples(for track: TrackID) async -> AsyncThrowingStream<CompressedSample, any Error> {
        AsyncThrowingStream { continuation in
            do {
                let loaded = try self.loadSync()
                continuation.yield(try Self.makeSample(loaded: loaded, track: track))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect {
        SeekEffect(landedAt: .zero)   // 1 枚だけ。どこへ seek しても先頭（その 1 枚）
    }

    // MARK: 読み込み

    private func load() throws -> Loaded { try loadSync() }

    private func loadSync() throws -> Loaded {
        if let loaded { return loaded }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw PlaybackError.source(.unreadable, message: "メニューの VOB を読めません（\(url.lastPathComponent)）",
                                       cause: String(describing: error))
        }
        let es = Self.extractVideoES(from: data)
        guard !es.isEmpty, let header = MPEG2Bitstream.sequenceHeader(in: es) else {
            throw PlaybackError.decode(.unsupportedCodec, message: "メニューの映像（MPEG-2）を取り出せません（\(url.lastPathComponent)）")
        }
        let frameRate = header.frameRate ?? .ntsc
        var signals = AspectSignals(mpegAspectInformation: header.effectiveDisplayAspect)
        switch header.verticalSize {
        case 480: signals.sampleAspectFromStandard = .bt601NTSCSample
        case 576: signals.sampleAspectFromStandard = AspectRatio(w: 12, h: 11)
        default: break
        }
        // 静止画のメニューは progressive frame（実測 interlaced_frame=0）。field 順の判断も deinterlace も不要。
        let format = VideoFormatDescription(
            codedSize: PixelSize(width: Int32(header.horizontalSize), height: Int32(header.verticalSize)),
            sampleAspect: signals.sampleAspectFromStandard,
            frameRate: frameRate,
            interlace: .progressive,
            aspectSignals: signals,
            rawFormatType: kCMVideoCodecType_MPEG2Video)
        let duration = CMTime(value: Int64(frameRate.denominator), timescale: Int32(clamping: frameRate.numerator))
        let loaded = Loaded(elementaryStream: es, header: header, format: format, frameDuration: duration)
        self.loaded = loaded
        return loaded
    }

    private static func makeSample(loaded: Loaded, track: TrackID) throws -> CompressedSample {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_MPEG2Video,
                                             width: Int32(loaded.header.horizontalSize),
                                             height: Int32(loaded.header.verticalSize),
                                             extensions: nil, formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else {
            throw PlaybackError.decode(.unsupportedCodec, message: "メニューの映像の形式記述を作れません")
        }
        let bytes = loaded.elementaryStream
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes.count, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                      offsetIntoDestination: 0, dataLength: bytes.count) })
                  == kCMBlockBufferNoErr else {
            throw PlaybackError.decode(.unsupportedCodec, message: "メニューの映像を buffer に載せられません")
        }
        var timing = CMSampleTimingInfo(duration: loaded.frameDuration, presentationTimeStamp: .zero,
                                        decodeTimeStamp: .zero)
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else {
            throw PlaybackError.decode(.unsupportedCodec, message: "メニューの映像の sample を作れません")
        }
        return CompressedSample(track: track, sampleBuffer: sample)
    }

    // MARK: program stream から映像 ES を取り出す（純粋関数。テストで検査する）

    /// program stream の映像 PES（stream_id 0xE0〜0xEF）の payload を順に連結する。
    /// 壊れた長さ・途中で切れた packet は、そこまでで打ち切る（読めた分だけ返す）。
    static func extractVideoES(from data: Data) -> Data {
        var es = Data()
        let n = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 4 <= n {
                // 開始コード 00 00 01 xx を探す。
                guard b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 else { i += 1; continue }
                let code = b[i + 3]
                switch code {
                case 0xBA:   // pack header: MPEG-2 は 14 byte + stuffing（最後の byte の下位 3 bit）
                    guard i + 14 <= n else { return }
                    i += 14 + Int(b[i + 13] & 0x07)
                case 0xB9:   // program end
                    return
                case 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0...0xDF, 0xE0...0xEF, 0xF0...0xFF:
                    guard i + 6 <= n else { return }
                    let length = Int(b[i + 4]) << 8 | Int(b[i + 5])
                    let end = i + 6 + length
                    guard length > 0, end <= n else { return }
                    if (0xE0...0xEF).contains(code), length >= 3 {
                        // PES header: flags 2 byte + header_data_length 1 byte + header data。payload はその後ろ。
                        let headerDataLength = Int(b[i + 8])
                        let payloadStart = i + 9 + headerDataLength
                        if payloadStart < end {
                            es.append(Data(bytes: raw.baseAddress!.advanced(by: payloadStart), count: end - payloadStart))
                        }
                    }
                    i = end
                default:
                    i += 4
                }
            }
        }
        return es
    }
}
