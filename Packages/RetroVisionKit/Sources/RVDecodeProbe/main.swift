import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RVMediaCore
import RVDecode

// 能力測定・実験の記録用（docs/experiments/）。再生経路には載せない。
//
// 使い方:
//   swift run rvprobe --json fixtures/generated/ntsc480i-22-01.mpg ...
//
// 出力は 1 素材について以下を順に読む:
//   1. AVFoundation が開けるか（開けない場合は理由）→ OQ-01/OQ-02 の判定材料
//   2. demux が何を渡すか（format description の attachment キー・verbatim ヘッダの有無）→ OQ-08
//   3. VideoToolbox で復号できるか、何が出力に復元されるか（field・色・比）→ OQ-08
//   4. 処理スループット（1 帧あたりの wall time）→ 開発計画 §5 の予算検証
struct Options {
    var json = false
    var paths: [URL] = []
    var limit = 0

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        for argument in arguments {
            switch argument {
            case "--json": options.json = true
            case "--limit": options.limit = -2            // 次を取り出す
            default:
                if options.limit == -2 { options.limit = Int(argument) ?? 0; continue }
                if argument.hasPrefix("--limit=") { options.limit = Int(argument.dropFirst(8)) ?? 0; continue }
                options.paths.append(URL(fileURLWithPath: argument))
            }
        }
        return options
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
guard !options.paths.isEmpty else {
    FileHandle.standardError.write("usage: rvprobe [--json] [--limit N] <media>...\n".data(using: .utf8)!)
    exit(64)
}

var report = ProbeReport()
for path in options.paths {
    print("=== \(path.lastPathComponent) ===")
    await report.probe(url: path, frameLimit: options.limit)
}
if options.json {
    let text = try String(data: JSONSerialization.data(withJSONObject: report.jsonValue,
                                                       options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

// MARK: - 計測本体

final class ProbeReport: @unchecked Sendable {
    private(set) var entries: [[String: Any]] = []

    /// --json の出力。実験記録（docs/experiments/EXP-001）にそのまま貼れる形にする。
    var jsonValue: Any { ["entries": entries] }

    func probe(url: URL, frameLimit: Int) async {
        var entry: [String: Any] = ["file": url.lastPathComponent]
        do {
            let demuxer = AVFoundationDemuxer(url: url)
            let opened = Date()
            let stream = try await demuxer.probe()
            entry["openMS"] = milliseconds(from: opened)
            entry["openStatus"] = "ok"
            entry["tracks"] = stream.tracks.map { track -> [String: Any] in
                var info: [String: Any] = ["kind": track.kind.rawValue,
                                           "id": Int(track.id.rawValue),
                                           "name": track.name ?? "",
                                           "language": track.language ?? ""]
                switch track.format {
                case .video(let format): info["video"] = describeVideo(format)
                case .audio(let format):
                    info["audio"] = ["codec": format.codec.rawValue,
                                     "rawFormatType": format.rawFormatTypeString,
                                     "sampleRate": Int(format.sampleRate),
                                     "channels": Int(format.channelCount),
                                     "bitDepth": format.bitDepth.map(Int.init) ?? 0]
                case .subtitle: info["subtitle"] = "track-found"
                case .unknown: info["format"] = "unknown"
                }
                return info
            }
            for warning in stream.warnings {
                let existing = (entry["warnings"] as? [String]) ?? []
                entry["warnings"] = existing + ["\(warning.code.rawValue): \(warning.detail)"]
            }

            guard let videoTrack = stream.tracks.first(where: { $0.kind == .video }) else {
                entry["decodeStatus"] = "no-video-track"
                entries.append(entry)
                print(String(describing: entry))
                return
            }

            // (2) demux が渡す format description の実データ
            var demuxedDescriptions: [CompressedSample] = []
            var ptsList: [MediaTime] = []
            for try await sample in await demuxer.samples(for: videoTrack.id) {
                demuxedDescriptions.append(sample)
                ptsList.append(sample.pts)
                if frameLimit > 0, demuxedDescriptions.count >= frameLimit { break }
            }
            entry["demuxedSampleCount"] = demuxedDescriptions.count
            let samplesCarryFormatDescription = demuxedDescriptions.contains {
                $0.videoFormatDescription != nil
            }
            entry["samplesCarryFormatDescription"] = samplesCarryFormatDescription
            if let first = demuxedDescriptions.first(where: { $0.videoFormatDescription != nil }) {
                entry["sampleFormatDescription"] = describeAttachmentKeys(of: first.sampleBuffer)
            }
            // 容器（track）側の format description。sample に付かない場合の差し替え口として使う（04 §2）
            let seed = try await demuxer.seedFormatDescription(for: videoTrack.id)
            entry["containerFormatDescription"] = seed.map { describeFormatDescription($0) } ?? "none"
            entry["frameRateByPTSInference"] = RVMediaCore.frameRate(fromPTSs: ptsList).map { String(describing: $0) } ?? "unresolved"
            // sample のデータそのもの（ES access unit）から sequence header を読む経路。
            // 実測: AVFoundation は MPEG-PS の PES ヘッダを外した ES を渡す。
            // sequence header は最初の sample の先頭に付いている（firstBytesHex が 000001b3）。
            let isMPEG2Video = seed.map { CMFormatDescriptionGetMediaSubType($0) }
                == kCMVideoCodecType_MPEG2Video
            if isMPEG2Video,
               let first = demuxedDescriptions.first(where: \.hasSampleData),
               let block = CMSampleBufferGetDataBuffer(first.sampleBuffer) {
                var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr {
                    let data = Data(bytes)
                    if let header = MPEG2Bitstream.sequenceHeader(in: data) {
                        entry["bitstreamFromSampleData"] = describeSequenceHeader(header)
                    } else {
                        entry["bitstreamFromSampleData"] = "not found"
                    }
                    // field 順は picture 层の信号。実測の per-frame flags（ffprobe と照合する）。
                    if let pce = MPEG2Bitstream.pictureCodingExtension(in: data) {
                        entry["pictureCodingExtensionFromSampleData"] = [
                            "pictureStructure": pce.pictureStructure,
                            "topFieldFirst": pce.topFieldFirst,
                            "repeatFirstField": pce.repeatFirstField,
                            "progressiveFrame": pce.progressiveFrame,
                        ]
                    }
                } else {
                    entry["bitstreamFromSampleData"] = "copy failed"
                }
            }

            // (3)(4) 復号
            let decoder = VideoToolboxDecoder()
            if let format = videoFormat(of: stream) {
                try await decoder.configure(format, policy: DecodePolicy(),
                                           formatDescriptionHint: seed)
            }
            var decodeTimes: [Double] = []
            var decodedFrames: [DecodedVideoFrame] = []
            var decodeError: String?
            let decodeStart = Date()
            do {
                for try await sample in await demuxer.samples(for: videoTrack.id) {
                    let began = Date()
                    if let frame = try await decoder.decode(sample) {
                        decodedFrames.append(frame)
                        decodeTimes.append(milliseconds(from: began))
                    }
                    if frameLimit > 0, decodedFrames.count >= frameLimit { break }
                }
                let flushed = await decoder.flush()
                decodedFrames.append(contentsOf: flushed)
            } catch let error as PlaybackError {
                decodeError = "\(error.userMessage) [\(String(describing: error.kind))] recovery=\(String(describing: error.recovery)) cause=\(error.causeDescription ?? "-")"
            }
            let totalDecodeMS = milliseconds(from: decodeStart)
            let pathInfo = await decoder.pathInfo
            entry["decodeStatus"] = decodeError == nil ? "ok" : "failed"
            entry["decodeError"] = decodeError ?? ""
            entry["decodePath"] = ["path": pathInfo.path.rawValue,
                                   "reason": pathInfo.reason ?? "",
                                   "codec": pathInfo.codecName ?? ""]
            entry["decodedFrameCount"] = decodedFrames.count
            entry["decodeTotalMS"] = totalDecodeMS
            entry["decodePerFrameMS"] = statistics(decodeTimes)
            entry["decodeThroughputFPS"] = decodedFrames.isEmpty ? 0
                : Double(decodedFrames.count) * 1_000 / max(totalDecodeMS, 0.001)
            if let first = decodedFrames.first {
                entry["decodedFormat"] = describeVideo(first.format)
                entry["decodedAttachments"] = attachmentKeys(of: first.pixelBuffer)
                entry["decodedPixelFormat"] = FourCC.string(CVPixelBufferGetPixelFormatType(first.pixelBuffer))
                entry["decodedDimensions"] = "\(CVPixelBufferGetWidth(first.pixelBuffer))x\(CVPixelBufferGetHeight(first.pixelBuffer))"
            }
            entry["decodedFieldRetention"] = decodedFrames.map { frame in
                ["pts": frame.pts.seconds,
                 "fieldCount": Int(frame.format.interlace.fieldCount),
                 "fieldSource": frame.format.interlace.fieldSource.rawValue,
                 "fieldOrder": frame.format.interlace.fieldOrder.rawValue]
            }
        } catch let error as PlaybackError {
            entry["openStatus"] = "failed"
            entry["error"] = error.userMessage
            entry["errorKind"] = String(describing: error.kind)
            entry["recovery"] = String(describing: error.recovery)
        } catch {
            entry["openStatus"] = "failed"
            entry["error"] = String(describing: error)
        }
        entries.append(entry)
        dump(entry)
    }

    private func videoFormat(of stream: ProbedStream) -> VideoFormatDescription? {
        for track in stream.tracks {
            if case .video(let format) = track.format { return format }
        }
        return nil
    }

    private func describeVideo(_ format: VideoFormatDescription) -> [String: Any] {
        var value: [String: Any] = [
            "codedSize": "\(format.codedSize.width)x\(format.codedSize.height)",
            "rawFormatType": FourCC.string(format.rawFormatType),
            "frameRate": format.frameRate.map { String(describing: $0) } ?? "unresolved",
            "frameRateFPS": format.frameRate?.framesPerSecond ?? 0,
            "interlaceFieldCount": Int(format.interlace.fieldCount),
            "fieldOrder": format.interlace.fieldOrder.rawValue,
            "fieldSource": format.interlace.fieldSource.rawValue,
            "statedCleanAperture": format.statedCleanAperture.map {
                "\($0.width)x\($0.height)+\($0.x)+\($0.y)"
            } ?? "none",
            "sampleAspect": format.sampleAspect.map { String(describing: $0) } ?? "none",
            "mpegAspectInformation": format.aspectSignals.mpegAspectInformation.map { $0.rawValue } ?? 0,
            "colorStated": format.color.isStated,
            "colorPrimaries": format.color.primaries.rawValue,
            "colorTransfer": format.color.transfer.rawValue,
            "colorMatrix": format.color.matrix.rawValue,
        ]
        if format.rawFormatType == FourCC.code("mp2v") {
            // bitstream の verbatim ヘッダはここでは持たない。demux 側の出力で確認する。
            value["note"] = "MPEG-2"
        }
        return value
    }

    private func describeAttachmentKeys(of sample: CMSampleBuffer) -> [String: Any] {
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            return ["error": "no format description"]
        }
        var value = describeFormatDescription(description)
        // sample 側の事実（実測記録用。ES を pack header 付きで渡しているかを見る）
        if let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: min(16, length))
            if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr {
                value["firstBytesHex"] = bytes.map { String(format: "%02x", $0) }.joined()
            }
            value["blockBufferLength"] = length
        } else {
            value["blockBufferLength"] = -1
        }
        return value
    }

    private func describeFormatDescription(_ description: CMFormatDescription) -> [String: Any] {
        let ext = AttachmentValues(CMFormatDescriptionGetExtensions(description))
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        var value: [String: Any] = [
            "subtype": FourCC.string(CMFormatDescriptionGetMediaSubType(description)),
            "dimensions": "\(dimensions.width)x\(dimensions.height)",
            "extensionKeys": ext.keys,
        ]
        if let verbatim = ext.data(MediaAttachmentKey.verbatimSampleDescription) {
            value["verbatimSampleDescriptionBytes"] = verbatim.count
            if let header = MPEG2Bitstream.sequenceHeader(in: verbatim) {
                value["bitstreamSequenceHeader"] = describeSequenceHeader(header)
            } else {
                value["bitstreamSequenceHeader"] = "not found"
            }
        } else {
            value["verbatimSampleDescriptionBytes"] = 0
        }
        return value
    }

    /// MPEG-2 の sequence header（+ sequence 层 extension）の実測値。表にしやすいよう平坦な key にする。
    private func describeSequenceHeader(_ h: MPEG2SequenceHeader) -> [String: Any] {
        let value: [String: Any] = [
            "codedSize": "\(h.horizontalSize)x\(h.verticalSize)",
            "aspectInformation": h.aspectRatioInformation.map { $0.rawValue } ?? 0,
            "displayExtensionPresent": h.displayExtensionPresent,
            "frameRate": h.frameRate.map { String(describing: $0) } ?? "unresolved",
            "frameRateFPS": h.frameRate?.framesPerSecond ?? 0,
            "progressiveSequence": h.progressiveSequence,
            "profile": h.profile ?? -1,
            "level": h.level ?? -1,
            "chromaFormat": h.chromaFormat,
            "bitRateValue": h.bitRateValue,
            "constrainedParameterFlag": h.constrainedParameterFlag,
            "displayVideoFormat": h.displayVideoFormat ?? -1,
            "displayColourDescription": h.displayColourDescription,
            "displayColorPrimaries": h.displayColorPrimaries ?? -1,
            "displayTransfer": h.displayTransferCharacteristics ?? -1,
            "displayMatrix": h.displayMatrixCoefficients ?? -1,
            "displayHorizontalSize": h.displayHorizontalSize ?? -1,
            "displayVerticalSize": h.displayVerticalSize ?? -1,
        ]
        return value
    }

    private func attachmentKeys(of buffer: CVPixelBuffer) -> [String] {
        AttachmentValues(CVBufferCopyAttachments(buffer, .shouldPropagate)).keys
    }

    private func statistics(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func at(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded(.up))))]
        }
        return ["count": sorted.count,
                "p50MS": at(0.5), "p95MS": at(0.95), "maxMS": sorted[sorted.count - 1],
                "meanMS": sorted.reduce(0, +) / Double(sorted.count)]
    }
}

private var probeStart = Date()

private func milliseconds(from date: Date) -> Double {
    Date().timeIntervalSince(date) * 1_000
}
