import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import RVMediaCore
import RVDecode
import RVPlaybackEngine

// 能力測定・実験の記録用（docs/experiments/）。再生経路には載せない。
//
// 使い方:
//   swift run rvprobe --json fixtures/generated/ntsc480i-22-01.mpg ...
//   swift run rvprobe --json --play fixtures/generated/ntsc480i-22-01.mpg ...
//
// 出力は 1 素材について以下を順に読む:
//   1. AVFoundation が開けるか（開けない場合は理由）→ OQ-01/OQ-02 の判定材料
//   2. demux が何を渡すか（format description の attachment キー・verbatim ヘッダの有無）→ OQ-08
//   3. VideoToolbox で復号できるか、何が出力に復元されるか（field・色・比）→ OQ-08
//   4. 処理スループット（1 帧あたりの wall time）→ 開発計画 §5 の予算検証
//   --play は EngineCore を通した実時間再生を測る（#11 の G1 前半資料: 提示間隔・late・起動遅延）
struct Options {
    var json = false
    var play = false
    var paths: [URL] = []
    var limit = 0

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        for argument in arguments {
            switch argument {
            case "--json": options.json = true
            case "--play": options.play = true
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
    FileHandle.standardError.write("usage: rvprobe [--json] [--play] [--limit N] <media>...\n".data(using: .utf8)!)
    exit(64)
}

var report = ProbeReport()
for path in options.paths {
    print("=== \(path.lastPathComponent) ===")
    if options.play {
        await report.playEntry(url: path)
    } else {
        await report.probe(url: path, frameLimit: options.limit)
    }
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

            // (5) 音声経路の実験（OQ-19 / issue #10）: AC-3 → PCM を AVFoundation だけでできるか。
            // 再生線には載せず、判定材料だけを JSON に残す。
            if stream.tracks.contains(where: { $0.kind == .audio }) {
                await audioExperiment(url: url, entry: &entry)
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

    /// 音声実験（OQ-19）。2 経路を測る:
    ///  a) passthrough（outputSettings=nil）— 自作 AudioDecoder に ES を渡す前提のサンプルと PTS
    ///  b) linearPCM 要求 — AVFoundation 内蔵の復号が成立するか、実際の出力仕様と実時間率
    private func audioExperiment(url: URL, entry: inout [String: Any]) async {
        var results: [[String: Any]] = []
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            entry["audioExperiment"] = [["error": "loadTracks: \(error)"]]
            return
        }
        for track in tracks {
            var one: [String: Any] = [:]
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            one["sourceSubtypes"] = descriptions.map { FourCC.string(CMFormatDescriptionGetMediaSubType($0)) }
            one["estimatedDataRate"] = (try? await track.load(.estimatedDataRate)) ?? -1
            one["passthrough"] = await audioStep(track: track, asset: asset, settings: nil)
            one["linearPCM"] = await audioStep(track: track, asset: asset, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            results.append(one)
        }
        entry["audioExperiment"] = results
    }

    private func audioStep(track: AVAssetTrack, asset fallbackAsset: AVAsset, settings: [String: Any]?) async -> [String: Any] {
        var step: [String: Any] = [:]
        do {
            let reader = try AVAssetReader(asset: track.asset ?? fallbackAsset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else {
                step["status"] = "cannot-add"
                return step
            }
            reader.add(output)
            guard reader.startReading() else {
                step["status"] = "start-failed"
                step["readerError"] = reader.error?.localizedDescription ?? "?"
                return step
            }
            let began = Date()
            var count = 0
            var totalBytes = 0
            var firstPTS: CMTime = .invalid
            var lastPTS: CMTime = .invalid
            var firstFrames = 0
            var maxFrames = 0
            var firstOutputFormat: [String: Any] = [:]
            while let sample = output.copyNextSampleBuffer() {
                let frames = CMSampleBufferGetNumSamples(sample)
                if count == 0 {
                    firstPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                    firstFrames = frames
                    if let description = CMSampleBufferGetFormatDescription(sample) {
                        firstOutputFormat = describeAudioFormat(description)
                    }
                }
                maxFrames = max(maxFrames, frames)
                if frames > 0, let block = CMSampleBufferGetDataBuffer(sample) {
                    totalBytes += CMBlockBufferGetDataLength(block)
                }
                lastPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                count += 1
                if count >= 5_000 { reader.cancelReading(); break }   // 実験の保護上限
            }
            let elapsedMS = milliseconds(from: began)
            step["status"] = (reader.error == nil) ? "ok" : reader.error?.localizedDescription ?? "error"
            step["sampleBufferCount"] = count
            step["totalBytes"] = totalBytes
            step["wallMS"] = elapsedMS
            step["firstOutputFormat"] = firstOutputFormat
            // 音声サンプルの PTS が有效か（クロックの原料にできるかの一次判定）
            step["firstPTSValid"] = firstPTS.isValid
            step["lastPTSValid"] = lastPTS.isValid
            // 1 バッファあたりのフレーム数（結合の実態。04 §4 の quantum 分割ポリシーの材料）
            step["firstBufferFrames"] = firstFrames
            step["maxBufferFrames"] = maxFrames
            if count > 1, firstPTS.isValid, lastPTS.isValid {
                let span = CMTimeGetSeconds(lastPTS) - CMTimeGetSeconds(firstPTS)
                step["spanSeconds"] = span
                // 1.0 以上なら「実時間再生の間に解ける」。音声だけのバースト計測である点に注意（EXP-002 に明記）。
                step["realtimeFactor"] = span * 1_000 / max(elapsedMS, 0.001)
            }
        } catch {
            step["status"] = "exception"
            step["error"] = String(describing: error)
        }
        return step
    }

    private func describeAudioFormat(_ description: CMFormatDescription) -> [String: Any] {
        var value: [String: Any] = ["subtype": FourCC.string(CMFormatDescriptionGetMediaSubType(description))]
        if let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let asbd = pointer.pointee
            value["formatID"] = FourCC.string(asbd.mFormatID)
            value["sampleRate"] = asbd.mSampleRate
            value["channelsPerFrame"] = Int(asbd.mChannelsPerFrame)
            value["bitsPerChannel"] = Int(asbd.mBitsPerChannel)
            value["bytesPerFrame"] = Int(asbd.mBytesPerFrame)
            value["framesPerPacket"] = Int(asbd.mFramesPerPacket)
            value["formatFlags"] = Int(asbd.mFormatFlags)
        }
        if let layoutPointer = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil) {
            value["channelLayoutTag"] = Int(layoutPointer.pointee.mChannelLayoutTag)
        }
        return value
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

    /// EngineCore を通した実時間再生の測定（#11 の G1 前半資料）。
    /// 提示間隔・late・起動遅延・スループットを JSON に残す。
    func playEntry(url: URL) async {
        var entry: [String: Any] = ["file": url.lastPathComponent, "mode": "playback"]
        let engine = EngineCore()
        let events = await engine.events()
        // 比率の宣言がない素材（H.264 mp4 等）は設計どおり load が user action を要求する
        // （chooseAspect。推測で 4:3 に倒さない）。headless の実測には「明示指定したユーザー」の
        // 代理として 4:3 を適用し、その事実を JSON に残す。
        do {
            let scout = AVFoundationDemuxer(url: url)
            let stream = try await scout.probe()
            if let video = stream.tracks.first(where: { $0.kind == .video }),
               case .video(let format) = video.format {
                let resolution = AspectResolver.resolve(codedSize: format.codedSize,
                                                       signals: format.aspectSignals,
                                                       policy: .followSource)
                if resolution.source == .unresolved {
                    var settings = PlayerSettings()
                    settings.aspectPolicy = .explicit(.dar4x3)
                    await engine.apply(settings)
                    entry["aspectPolicyApplied"] = "explicit 4:3（素材に比率宣言なし。chooseAspect の headless 代理）"
                }
            }
        } catch {}
        do {
            try await engine.load(FileMediaSource(url: url), selection: PlaybackSelection(item: ItemID(1)))
        } catch {
            entry["playStatus"] = "load-failed"
            entry["loadError"] = String(describing: error)
            entries.append(entry)
            print(entry)
            return
        }
        // 目標値（フレームレート）は demux と同じ規則で読む（比較対象のための静的値）。
        if let stream = try? await AVFoundationDemuxer(url: url).probe(),
           let video = stream.tracks.first(where: { $0.kind == .video }),
           case .video(let format) = video.format, let rate = format.frameRate {
            entry["targetFrameRate"] = String(describing: rate)
            entry["targetFrameIntervalMS"] = 1_000 / rate.framesPerSecond
        }
        let began = Date()
        await engine.play()
        var endState: String?
        let deadline = began.addingTimeInterval(300)   // 10 秒素材に対する安全側上限
        for await event in events {
            if case .phaseChanged(let phase) = event {
                switch phase {
                case .ended: endState = "ended"
                case .failed(let error): endState = "failed: \(error.userMessage)"
                default: break
                }
            }
            if endState != nil || Date() > deadline { break }
        }
        entry["playStatus"] = endState ?? "timeout"
        entry["wallMS"] = Date().timeIntervalSince(began) * 1_000
        if let outcome = await engine.playbackOutcome() {
            let stats = outcome.stats
            entry["presented"] = stats.presented
            entry["late"] = stats.late
            entry["demuxedSampleCount"] = outcome.demuxedSampleCount
            entry["firstPresentDelayMS"] = outcome.firstPresentDelayMS
            entry["totalWallMS"] = outcome.totalWallMS
            entry["mediaDurationMS"] = outcome.mediaDurationMS
            entry["realTimeFactor"] = outcome.totalWallMS > 0 ? outcome.mediaDurationMS / outcome.totalWallMS : 0
            entry["presentIntervalMS"] = statistics(outcome.presentIntervalMS)
            entry["decodeStageMS"] = statistics(outcome.decodeStageMS)
            if !outcome.errors.isEmpty { entry["errors"] = outcome.errors }
        }
        entries.append(entry)
        print(entry)
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
