import Foundation

// MARK: - MPEG-PS のプログラム内 PTS 再開始の修復（03 §9.2、#3。実測 2026-11-17）
//
// 実測（ユーザー実機の PICHI_PICHI_PITCH1.iso、issue #3 に全表記録）:
//   * 実写 DVD の VTS チェーンは part 跨ぎで PES の raw PTS が連続している
//     （VTS_01_1: 0.189→885.6s、_2: 886.1→1770.5s、_3: 1771.0→2654.7s）。
//   * 最後の part（VTS_01_4）だけが内部にプログラム境界を持ち、バイト位置
//     338,876,430 で PTS が 0.553 s に再開始して -2,935 s の逆行になっていた。
//   * この形では AVFoundation が破綻する: part 4 単体で duration 92,865 s と誤読し
//     reader は 3.2 s（92 sample）で停止。4 part をバイト連結すると全体が 76.064 s に
//     崩壊した（#22/#3 の「01:16 で終わる」の直接原因）。
//   * 修復実験（同会话の psrepair で実測）: 逆行以降の全 PES（映像・音声）の
//     PTS/DTS を逆行量だけ前方へ寄した写しを作ると、part 4 全体が AVFoundation で
//     読めるようになった（319 s / 9,529 sample。修復前の 92 sample と対照）。
//
// 方針（決定 2026-11-17）: 無連結の part 単位 demux + sample 時刻の縫合
// （SegmentPSDemuxer）と組み合わせる。修復は**スキャンによる検出で発火**する
// （期間の長さ等のはぎ合い判定ではない）。再開始の無い part は写しを作らない
// （PICHI の part 1〜3 で実測: 走査のみでコピー無し）。境界より後の別プログラム
// （main feature の後に続く追加コンテンツ）は時間軸として続けるが、本来の権威は
// IFO の PGCI/cell 時間である（03 §4 の保留事項 — 増分で切り分ける。OQ-16 の実写
// fixture registry で再測定するまで「続きが続く」ことの暫定既定とする）。
//
// 実装は 2 段: (a) mmap 読み取り専用マッピングでのスキャン（ファイル全体をメモリに
// 載せない。430 MB で 1 秒未満の実測めど）、(b) パッチ表を適用しながらの写し出し
// （4MB window の逐次写し。全載せしない）。
public enum ProgramStreamRepair {
    public struct Finding: Sendable {
        /// 逆行（プログラム再開始）を検出したバイトオフセット。
        public let breakOffsets: [Int64]
        /// 書き換えた PTS/DTS フィールドの数。
        public let shiftedFieldCount: Int
    }

    /// 「プログラム境界」として扱う逆行の最小量（秒）。これ未満の逆行は通常の
    /// 振幅（音声・映像の交互送信や authoring の小刻みな揺れ）として修復しない。
    static let programBreakSeconds: Double = 2.0

    struct Patch {
        let at: Int        // 5-byte timestamp field の絶対オフセット
        let delta: Int64   // 加算する 90 kHz tick 数
    }

    /// 必要なら修復コピーを作って (URL, finding) を返す。不要（再開始なし・読めない）は nil。
    /// 呼び出し側が寿命を持つ（SegmentPSDemuxer の deinit で掃除する — ConcatPSDemuxer の
    /// 一時ファイルと同じ約束）。
    public static func repairedCopyIfNeeded(of url: URL) async -> (repairedURL: URL, finding: Finding)? {
        guard let (patches, breaks) = plan(url), !patches.isEmpty else { return nil }
        if ProcessInfo.processInfo.environment["RV_DEBUG_PSREPAIR"] != nil {
            let breakList = breaks.map { String($0) }.joined(separator: ",")
            let deltaList = patches.prefix(6).map { String($0.delta) }.joined(separator: ",")
            let line = "psrepair: \(url.lastPathComponent) breaks=\(breakList) firstDeltas=\(deltaList)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrovision-psfix-\(UUID().uuidString).mpg")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let input = try? FileHandle(forReadingFrom: url),
              let output = try? FileHandle(forWritingTo: temp) else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        defer { try? input.close(); try? output.close() }
        var written: Int = 0
        var patchIndex = 0
        var failed = false
        while true {
            guard let chunk = try? input.read(upToCount: 4_194_304), !chunk.isEmpty else { break }
            var bytes = [UInt8](chunk)
            while patchIndex < patches.count && patches[patchIndex].at < written + bytes.count {
                let patch = patches[patchIndex]
                if patch.at >= written, patch.at + 5 <= written + bytes.count {
                    applyWriteShift(&bytes, local: patch.at - written, delta: patch.delta)
                }
                patchIndex += 1
            }
            do {
                try output.write(contentsOf: bytes)
            } catch {
                failed = true
                break
            }
            written += bytes.count
        }
        if failed {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        return (temp, Finding(breakOffsets: breaks, shiftedFieldCount: patches.count))
    }

    // MARK: スキャン（mmap）

    /// PES start code を辿って、映像・音声 PES の PTS/DTS の逆行計画を作る。
    /// mmap 失败時は nil（呼び出し側は「修復できない=そのまま読む」にフォールバック）。
    private static func plan(_ url: URL) -> (patches: [Patch], breaks: [Int64])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size: Int
        do { size = try Int(handle.seekToEnd()) } catch { return nil }
        guard size > 16, let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0)
        else { return nil }
        defer { munmap(base, size) }
        let buf = UnsafeRawBufferPointer(start: base, count: size)
        return plan(in: buf)
    }

    /// PS を start code に従って歩き、5-byte タイムスタンプフィールド（lead '0011' PTS、
    /// 直後に lead '0001' が続くなら DTS を伴う）ごとに visitor を呼ぶ共通走査。
    ///
    /// PES ヘッダの実形は 2 種を観測（両方読む。03 §9.2 の実測）:
    ///   * '10xx' marker 形（実写 PICHI: 0xE0 PES の flags 0x81/0xC1、PTS は q+3 に実在を round-trip 検証済み。
    ///     FFmpeg の PS  demuxer も同形式をこの順序で読む — mpegps_read_pes_header）
    ///   * '0011' PTS 直接形（ffmpeg 生成 fixture の PES1 旧形: length の直後に 5-byte PTS、
    ///     続けて lead '0001' なら DTS。ffprobe の pts/dts とバイト一致で確定）
    static func scanFields(in buf: UnsafeRawBufferPointer, visitor: (_ at: Int, _ hasDTS: Bool) -> Void) {
        let n = buf.count
        var p = 0
        while p + 4 <= n {
            var sc = p
            while sc + 3 < n, !(buf[sc] == 0 && buf[sc + 1] == 0 && buf[sc + 2] == 1) { sc += 1 }
            if sc + 3 >= n { break }
            let sid = buf[sc + 3]
            switch sid {
            case 0xBA:   // pack header（GStreamer と同じ 14 + stuff 式で進む。PICHI 実測で一致。
                         // FFmpeg の PS demuxer は pack header を完全に読み飛ばす — 03 §9.2 の実測根拠）
                guard sc + 14 <= n else { p = n; break }
                p = sc + 14 + Int(buf[sc + 13] & 0x07)
            case 0xBB, 0xBC, 0xBE, 0xB9, 0xB7, 0xB8:   // system header / PSM / padding / end code 類
                guard sc + 6 <= n else { p = n; break }
                let len = Int(buf[sc + 4]) << 8 | Int(buf[sc + 5])
                p = len > 0 ? sc + 6 + len : sc + 4
            case 0xBD, 0xBF, 0xC0...0xDF, 0xE0...0xEF:  // PES（映像・音声・private）
                guard sc + 6 <= n else { p = n; break }
                let len = Int(buf[sc + 4]) << 8 | Int(buf[sc + 5])
                var q = sc + 6
                while q < n, buf[q] == 0xFF { q += 1 }
                let head = q < n ? buf[q] : 0
                if (head & 0xE0) == 0x80 {
                    // PES-2 形: marker '10xx' + flags + header_data_length。
                    let flags = q + 1 < n ? buf[q + 1] : 0
                    if flags & 0x80 != 0 { visitor(q + 3, flags & 0x40 != 0) }
                } else if (head & 0xE0) == 0x20 {
                    // PES-1 旧形（FFmpeg の mpegps_read_pes_header と同じ判別 (c & 0xE0) == 0x20:
                    // '001x' lead の 5-byte timestamp が length 直後。bit4（'0011'）で
                    // 直後に '0001' DTS フィールドが続く）。
                    visitor(q, head & 0x10 != 0)
                }
                if len > 0 {
                    p = sc + 6 + len
                } else {
                    // 長さ指定の無い映像 PES（DVD authoring では稀）: 次の pack header まで。
                    var next = q
                    while next + 3 < n, !(buf[next] == 0 && buf[next + 1] == 0 && buf[next + 2] == 1 && buf[next + 3] == 0xBA) {
                        next += 1
                    }
                    p = next < n ? next : sc + 6
                }
            default:
                guard sc + 6 <= n else { p = n; break }
                let len = Int(buf[sc + 4]) << 8 | Int(buf[sc + 5])
                p = len > 0 ? sc + 6 + len : sc + 4
            }
            if p <= sc { p = sc + 4 }   // 常に前進
        }
    }

    /// 純粋なスキャン本体（マッピング由来の不変バイト列から計画を作る。検査から直接叩ける）。
    static func plan(in buf: UnsafeRawBufferPointer) -> (patches: [Patch], breaks: [Int64]) {
        var patches: [Patch] = []
        var breaks: [Int64] = []
        var delta: Int64 = 0
        var lastSeen: Int64 = -1          // 直近の実効 PTS（90kHz）。-1 = まだ無い
        let n = buf.count
        let threshold = Int64(programBreakSeconds * 90_000)

        /// 1 つのタイムスタンプフィールド（5 byte）の実効 PTS を追跡し、現 delta の
        /// 適用パッチを必要分だけ登録する。dtsFollows は直後の DTS フィールド continuation。
        func note(_ at: Int, dtsFollows: Bool) {
            guard at + 5 <= n else { return }
            let raw = timestampValue(buf, at: at)
            if lastSeen < 0 {
                lastSeen = raw + delta
            } else if raw + delta < lastSeen - threshold {
                // プログラム再開始: 以降を lastSeen の直後に続ける。
                delta = lastSeen - raw
                breaks.append(Int64(at))
                patches.append(Patch(at: at, delta: delta))
            } else if delta != 0 {
                patches.append(Patch(at: at, delta: delta))
            }
            let eff = raw + delta
            if eff > lastSeen { lastSeen = eff }
            if dtsFollows, delta != 0, at + 10 <= n {
                patches.append(Patch(at: at + 5, delta: delta))   // DTS continuation
            }
        }

        scanFields(in: buf) { at, hasDTS in note(at, dtsFollows: hasDTS) }
        return (patches, breaks)
    }

    /// すべてのタイムスタンプフィールドの位置列（後方へ時刻を寄せる試験素材の構成用。internal）。
    static func timestampFields(in buf: UnsafeRawBufferPointer) -> [(at: Int, hasDTS: Bool)] {
        var out: [(at: Int, hasDTS: Bool)] = []
        scanFields(in: buf) { at, hasDTS in out.append((at, hasDTS)) }
        return out
    }

    // MARK: 5-byte timestamp（'0011' PTS / '0101' DTS の lead nibble は保持して再符号化）

    static func timestampValue(_ buf: UnsafeRawBufferPointer, at: Int) -> Int64 {
        let v: UInt64 = (UInt64(buf[at]) << 32) | (UInt64(buf[at + 1]) << 24)
            | (UInt64(buf[at + 2]) << 16) | (UInt64(buf[at + 3]) << 8) | UInt64(buf[at + 4])
        // 明示分解（CI の swift build で単一式の型検査が指数爆発した実測: 2026-11-17）。
        let p3032: UInt64 = (v >> 33) & 7
        let p1529: UInt64 = (v >> 17) & 0x7FFF
        let p014: UInt64 = (v >> 1) & 0x7FFF
        let pts: UInt64 = (p3032 << 30) | (p1529 << 15) | p014
        return Int64(pts)
    }

    /// window 内のフィールドを delta だけシフトして書き戻す。33-bit の範囲を跨ぐ場合は
    /// ラップさせる（PS の timestamp 空間は 33-bit。跨ぎ越しの複数学びは plan 側で
    /// 逆行として別 break になるため、ここで跨ぐのは「続けた結果のラップ」のみ）。
    static func applyWriteShift(_ bytes: inout [UInt8], local: Int, delta: Int64) {
        guard local >= 0, local + 5 <= bytes.count else { return }
        let v: UInt64 = (UInt64(bytes[local]) << 32) | (UInt64(bytes[local + 1]) << 24)
            | (UInt64(bytes[local + 2]) << 16) | (UInt64(bytes[local + 3]) << 8) | UInt64(bytes[local + 4])
        let lead = (v >> 36) & 0xF
        let p3032r: UInt64 = (v >> 33) & 7
        let p1529r: UInt64 = (v >> 17) & 0x7FFF
        let p014r: UInt64 = (v >> 1) & 0x7FFF
        let pts: UInt64 = (p3032r << 30) | (p1529r << 15) | p014r
        let shifted: UInt64 = UInt64((Int64(bitPattern: pts) &+ delta) &+ 0x2_0000_0000) & 0x1_FFFF_FFFF
        // 5-byte 符号法: lead(4) P[32:30](3) '1' P[29:15](15) '1' P[14:0](15) '1'
        let p3032: UInt64 = ((shifted >> 30) & 0x7) << 33
        let marker32: UInt64 = 1 << 32
        let p1529: UInt64 = ((shifted >> 15) & 0x7FFF) << 17
        let marker16: UInt64 = 1 << 16
        let p014: UInt64 = (shifted & 0x7FFF) << 1
        let tailMarker: UInt64 = 1
        let enc: UInt64 = (lead << 36) | p3032 | marker32 | p1529 | marker16 | p014 | tailMarker
        bytes[local] = UInt8((enc >> 32) & 0xFF)
        bytes[local + 1] = UInt8((enc >> 24) & 0xFF)
        bytes[local + 2] = UInt8((enc >> 16) & 0xFF)
        bytes[local + 3] = UInt8((enc >> 8) & 0xFF)
        bytes[local + 4] = UInt8(enc & 0xFF)
    }
}
