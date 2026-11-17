import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import RVDecode
import RVMediaCore

/// 測定用（A1e Step 1）。環境変数 RV_MEASURE_PATH のファイルを復号し、frame ごとの縞の指標と PCE フラグを出力する。
/// 設定が無ければ何もしない（CI では走らない）。
final class CombMeasurementTests: XCTestCase {
    private func lumaStats(_ pb: CVPixelBuffer) -> (tooth: Double, adjSAD: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return (0, 0) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var teeth = 0, total = 0
        var sad = 0.0, sadCount = 0
        let thr = 12   // 輝度 12 階調（video range）以上の「歯」だけ数える
        for y in 1..<(h - 1) {
            for x in 0..<w {
                let c = Int(p[y * stride + x]), u = Int(p[(y - 1) * stride + x]), d = Int(p[(y + 1) * stride + x])
                let a = c - u, b = c - d
                // 歯: 上下の両隣に対して同じ向きに大きく外れる（同符号で両方 thr 超）
                if (a > thr && b > thr) || (a < -thr && b < -thr) { teeth += 1 }
                total += 1
                sad += Double(abs(a)); sadCount += 1
            }
        }
        return (Double(teeth) / Double(total), sad / Double(sadCount))
    }

    func testMeasure() async throws {
        guard let path = ProcessInfo.processInfo.environment["RV_MEASURE_PATH"] else { return }
        let limit = Int(ProcessInfo.processInfo.environment["RV_MEASURE_FRAMES"] ?? "") ?? 60
        let skip = Int(ProcessInfo.processInfo.environment["RV_MEASURE_SKIP"] ?? "") ?? 0
        let demuxer = AVFoundationDemuxer(url: URL(fileURLWithPath: path))
        let stream = try await demuxer.probe()
        guard let track = stream.tracks.first(where: { $0.kind == .video }), case let .video(format) = track.format else {
            return XCTFail("映像 track が無い")
        }
        let seed = try await demuxer.seedFormatDescription(for: track.id)
        let decoder = VideoToolboxDecoder()
        try await decoder.configure(format, policy: DecodePolicy(), formatDescriptionHint: seed)

        var flagsByPTS: [Int64: String] = [:]
        var frames: [DecodedVideoFrame] = []
        var n = 0
        for try await sample in await demuxer.samples(for: track.id) {
            if let buf = CMSampleBufferGetDataBuffer(sample.sampleBuffer) {
                var len = 0; var ptr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(buf, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
                if let ptr, let pce = MPEG2Bitstream.pictureCodingExtension(in: Data(bytes: ptr, count: min(len, 4096))) {
                    flagsByPTS[Int64(sample.pts.seconds * 1000)] = "prog=\(pce.progressiveFrame ? 1 : 0) rff=\(pce.repeatFirstField ? 1 : 0) tff=\(pce.topFieldFirst ? 1 : 0)"
                }
            }
            if let f = try await decoder.decode(sample) { frames.append(f) }
            n += 1
            if frames.count >= limit + skip { break }
        }
        var lines: [String] = []
        for (i, f) in frames.dropFirst(skip).prefix(limit).enumerated() {
            let s = lumaStats(f.pixelBuffer)
            let flags = flagsByPTS[Int64(f.pts.seconds * 1000)] ?? "-"
            lines.append(String(format: "%3d pts=%8.3f tooth=%.5f adjSAD=%6.2f %@", i, f.pts.seconds, s.tooth, s.adjSAD, flags))
        }
        print("COMBMEASURE \(path)\n" + lines.joined(separator: "\n"))
    }
}
