import CoreVideo
import Foundation
import RVMediaCore

// MARK: - タイル分割推論（06 §5。固定寸法モデルを任意寸法の frame に使う）
//
// モデルの入力寸法（tile）で frame を覆い、隣り合うタイルは `overlap` px 重ねる。出力は重なり部分を
// 線形に混ぜて（feather）継ぎ目を消す。重みは出力画素ごとに正規化するので、重みの合計は常に 1
// （恒等モデルなら入力が厳密に復元される）。純粋な計画（`TilePlan`）と、実際の推論の駆動
// （`TiledInference`）を分け、前者は Core ML なしで検査できる。

public struct TilePlan: Sendable, Hashable {
    public struct Tile: Sendable, Hashable {
        /// 入力 frame 上の左上（px）。
        public let x: Int
        public let y: Int
    }

    public let imageWidth: Int
    public let imageHeight: Int
    public let tileWidth: Int
    public let tileHeight: Int
    /// 隣り合うタイルの重なり幅（入力 px。16 が既定 — 06 §5）。
    public let overlap: Int
    /// 出力 / 入力の倍率（超解像は 2、同寸法のモデルは 1）。
    public let scale: Int
    public let tiles: [Tile]
    /// 軸ごとの開始位置（tiles は xs × ys の直積。行優先）。
    public let xs: [Int]
    public let ys: [Int]

    /// 計画を作る。frame がタイルより小さい・重なりがタイル以上・倍率が不正のときは nil
    /// （呼び出し側はより小さいモデル variant を選ぶ / 推論しない — 08 §5）。
    public init?(imageWidth: Int, imageHeight: Int, tileWidth: Int, tileHeight: Int,
                 overlap: Int = 16, scale: Int = 1) {
        guard imageWidth >= tileWidth, imageHeight >= tileHeight, tileWidth > 0, tileHeight > 0,
              scale >= 1, overlap >= 0, overlap < tileWidth, overlap < tileHeight else { return nil }
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.tileWidth = tileWidth; self.tileHeight = tileHeight
        self.overlap = overlap; self.scale = scale
        let xPositions = Self.positions(length: imageWidth, tile: tileWidth, overlap: overlap)
        let yPositions = Self.positions(length: imageHeight, tile: tileHeight, overlap: overlap)
        xs = xPositions
        ys = yPositions
        tiles = yPositions.flatMap { y in xPositions.map { Tile(x: $0, y: y) } }
    }

    /// 軸方向の開始位置: stride = tile − overlap で並べ、最後のタイルは frame の端に揃える。
    static func positions(length: Int, tile: Int, overlap: Int) -> [Int] {
        if length <= tile { return [0] }
        let stride = tile - overlap
        var result: [Int] = []
        var p = 0
        while p + tile < length { result.append(p); p += stride }
        let last = length - tile
        if result.last != last { result.append(last) }
        return result
    }

    public var outputWidth: Int { imageWidth * scale }
    public var outputHeight: Int { imageHeight * scale }
    public var outputTileWidth: Int { tileWidth * scale }
    public var outputTileHeight: Int { tileHeight * scale }

    /// 1 軸の重み（出力タイル内の座標 u）。隣のタイルと重なる側だけ、重なり幅（出力 px）で 0→1 に上げる。
    /// frame の端（隣が無い側）は 1。
    private func axisWeight(_ u: Int, length: Int, hasPrevious: Bool, hasNext: Bool) -> Float {
        let ramp = max(overlap * scale, 1)
        var w: Float = 1
        if hasPrevious { w = min(w, Float(u + 1) / Float(ramp + 1)) }
        if hasNext { w = min(w, Float(length - u) / Float(ramp + 1)) }
        return w
    }

    /// タイル（行優先の index）の出力内座標 (u, v) の重み。
    public func weight(tileIndex: Int, u: Int, v: Int) -> Float {
        let ix = tileIndex % xs.count, iy = tileIndex / xs.count
        let wx = axisWeight(u, length: outputTileWidth, hasPrevious: ix > 0, hasNext: ix < xs.count - 1)
        let wy = axisWeight(v, length: outputTileHeight, hasPrevious: iy > 0, hasNext: iy < ys.count - 1)
        return wx * wy
    }

    /// 各タイルの出力（interleaved Float。`channels` 本）を、重みつき平均で 1 枚に合成する（参照実装・CPU）。
    /// `tileOutputs[i]` は `outputTileWidth × outputTileHeight × channels`。
    public func compose(tileOutputs: [[Float]], channels: Int) -> [Float] {
        precondition(tileOutputs.count == tiles.count)
        var acc = [Float](repeating: 0, count: outputWidth * outputHeight * channels)
        var norm = [Float](repeating: 0, count: outputWidth * outputHeight)
        for (index, tile) in tiles.enumerated() {
            let out = tileOutputs[index]
            for v in 0..<outputTileHeight {
                for u in 0..<outputTileWidth {
                    let w = weight(tileIndex: index, u: u, v: v)
                    let ox = tile.x * scale + u, oy = tile.y * scale + v
                    let pix = oy * outputWidth + ox
                    norm[pix] += w
                    let src = (v * outputTileWidth + u) * channels
                    for c in 0..<channels { acc[pix * channels + c] += w * out[src + c] }
                }
            }
        }
        for pix in 0..<(outputWidth * outputHeight) where norm[pix] > 0 {
            for c in 0..<channels { acc[pix * channels + c] /= norm[pix] }
        }
        return acc
    }
}

/// タイル分割で frame 全体を推論する（BGRA の `CVPixelBuffer` 入出力。CPU でタイルを切り出し・合成する）。
/// どのタイルが失敗しても全体を失敗として返す（部分的に強調された frame は出さない — 呼び出し側は
/// その frame を非強調のまま提示する。INV-1）。タイルは直列に投入する（in-flight ≤ 2 の枠内 — 06 §7）。
public enum TiledInference {
    public static func run(frame: InferenceFrame, plan: TilePlan, request: InferenceRequest,
                           runtime: any ModelRuntimeProtocol) async throws -> InferenceFrame {
        let source = frame.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(source) == plan.imageWidth,
              CVPixelBufferGetHeight(source) == plan.imageHeight else {
            throw PlaybackError.model(.shapeMismatch, message: "タイル分割の入力が計画と一致しません")
        }
        var tileOutputs: [[Float]] = []
        tileOutputs.reserveCapacity(plan.tiles.count)
        for tile in plan.tiles {
            let input = try crop(source, x: tile.x, y: tile.y, width: plan.tileWidth, height: plan.tileHeight)
            let tileRequest = InferenceRequest(model: request.model, width: plan.tileWidth, height: plan.tileHeight,
                                               frameID: request.frameID, deadline: request.deadline)
            let output = try await runtime.predict(tileRequest, input: InferenceFrame(input))
            tileOutputs.append(try floats(output.pixelBuffer, width: plan.outputTileWidth, height: plan.outputTileHeight))
        }
        let composed = plan.compose(tileOutputs: tileOutputs, channels: 4)
        return InferenceFrame(try makeBuffer(composed, width: plan.outputWidth, height: plan.outputHeight))
    }

    // MARK: BGRA pixel buffer ↔ Float

    private static func crop(_ source: CVPixelBuffer, x: Int, y: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        let dest = try makePixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let s = CVPixelBufferGetBaseAddress(source), let d = CVPixelBufferGetBaseAddress(dest) else {
            throw PlaybackError.model(.runtimeFailure, message: "pixel buffer を読めません")
        }
        let sStride = CVPixelBufferGetBytesPerRow(source), dStride = CVPixelBufferGetBytesPerRow(dest)
        for row in 0..<height {
            memcpy(d + row * dStride, s + (y + row) * sStride + x * 4, width * 4)
        }
        return dest
    }

    private static func floats(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [Float] {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw PlaybackError.model(.shapeMismatch, message: "モデルの出力寸法が計画と一致しません")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw PlaybackError.model(.runtimeFailure, message: "pixel buffer を読めません")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let p = (base + row * stride).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * 4) { out[row * width * 4 + i] = Float(p[i]) }
        }
        return out
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw PlaybackError.model(.runtimeFailure, message: "pixel buffer を確保できません")
        }
        return pb
    }

    private static func makeBuffer(_ values: [Float], width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try makePixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw PlaybackError.model(.runtimeFailure, message: "pixel buffer を書けません")
        }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for row in 0..<height {
            let p = (base + row * stride).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * 4) { p[i] = UInt8(max(0, min(255, values[row * width * 4 + i].rounded()))) }
        }
        return pb
    }
}
