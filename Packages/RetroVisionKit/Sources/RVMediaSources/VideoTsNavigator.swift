import Foundation
import RVMediaCore

// MARK: - VIDEO_TS 構造のタイトル走査（03 §3、§4。#3 の v1: ファイル名のみ）
//
// v1 の決定（#3 のスコープ）: タイトル列挙は VIDEO_TS のファイル名走査だけ行う。
// IFO の実パース（タイトル数・時間・トラック表の権威）と CSS/AACS の判定は
// 増分として OQ のまま（03 §4）。IFO が無い・読めないタイトルは warning を残す
// （#3 の受入基準「IFO と VOB の長さが食い違う等を列挙する」の名簿の最初の項）。
//
// 純 Foundation: RVMediaSources は RVDecode を import しない（00 §2 / ArchitectureTests）。

/// 1 タイトル = 1 VOB チェーン（VTS_nn_1.VOB .. VTS_nn_k.VOB、順序付き）。
public struct VideoTsChain: Sendable, Hashable {
    /// VTS_01 → 1。ファイル名の数字から取る。
    public let vtsNumber: Int
    /// 連結順（VTS_nn_1, VTS_nn_2, ...）。
    public let partURLs: [URL]
    /// VTS_nn_0.IFO か VTS_nn_1.IFO が見つかっているか（v1 は「存在」のみを見る）。
    public let hasIfo: Bool

    public init(vtsNumber: Int, partURLs: [URL], hasIfo: Bool) {
        self.vtsNumber = vtsNumber
        self.partURLs = partURLs
        self.hasIfo = hasIfo
    }
}

public enum VideoTsNavigator {
    /// root（DVD-Video のルート、または VIDEO_TS を直接指す URL）からタイトル列を作る。
    /// VIDEO_TS ディレクトロが見つからなければ nil（呼び出し側は「DVD-Video ではない」と扱う）。
    /// 戻り値の chains は vtsNumber の昇順、partURLs は part 番号の昇順（決定的順序）。
    public static func chains(in root: URL) -> (chains: [VideoTsChain], warnings: [StructureWarning])? {
        let fm = FileManager.default
        let videoTS = findVideoTSDirectory(in: root)
        guard let videoTS else { return nil }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: videoTS,
                                                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                options: [.skipsSubdirectoryDescendants,
                                                          .skipsPackageDescendants])
        } catch {
            return (chains: [], warnings: [StructureWarning(code: .unreadableIFO,
                                                            detail: "VIDEO_TS を列挙できません: \(error)")])
        }

        // VTS_nn_p.ext（小文字系も許す: macOS へのコピーで case が揺れる実運用対策。
        // ISO9660/Joliet 上の実名は大文字だが、検査は名前の一致ではなく「構造」の意味で見る）。
        struct Entry { let vts: Int; let part: Int; let ext: String; let url: URL }
        var grouped: [Int: [Entry]] = [:]
        var ignored: [String] = []
        var warnings: [StructureWarning] = []

        for url in entries.sorted(by: { $0.path < $1.path }) {
            let name = url.lastPathComponent
            guard isRegularFile(url) else { continue }
            guard let parsed = Self.parseTitleFileName(name) else {
                // VIDEO_TS.IFO/BUP はディスク情報のため対象外（正常。warning は出さない）。
                // VTS_VO.* はオーサリングツールが置くことがある（title0 menu。v1 は対象外）。
                let base = (name as NSString).deletingPathExtension.uppercased()
                if base != "VIDEO_TS" && base != "VTS_VO" {
                    ignored.append(name)
                }
                continue
            }
            grouped[parsed.vts, default: []].append(Entry(vts: parsed.vts, part: parsed.part,
                                                          ext: parsed.ext, url: url))
        }

        var chains: [VideoTsChain] = []
        for vts in grouped.keys.sorted() {
            let items = grouped[vts]!
            // VTS_nn_0.VOB はメニュー用（title 0）でタイトル本体ではない（実 DVD 配置）。
            // 列からは除外し、part 0 のみの VTS は menu-only として静かに skip する（正常形）。
            let vobs = items.filter { $0.ext == "VOB" && $0.part >= 1 }
                .sorted { $0.part < $1.part }
            guard !vobs.isEmpty else { continue }
            if vobs.first?.part != 1 {
                warnings.append(StructureWarning(code: .missingVOB,
                                                detail: "VTS_\(pad(vts)) に VTS_\(pad(vts))_1.VOB が無い"
                                                    + "（先頭 part 無しは扱わない）"))
                continue
            }
            // part 番号の連続性（1,2,3,...）を確認。飛びは missingVOB の実例（#3 の受入基準）。
            var expected = 1
            var contiguous: [Entry] = []
            for v in vobs {
                if v.part == expected {
                    contiguous.append(v)
                    expected += 1
                } else if contiguous.isEmpty {
                    break
                }   // 以降は列挙に残しても繋がらない（warning だけ残す）
            }
            if contiguous.count < vobs.count {
                let missing = Set(vobs.map(\.part)).subtracting(contiguous.map(\.part)).sorted()
                warnings.append(StructureWarning(code: .missingVOB,
                                                detail: "VTS_\(pad(vts)) の part が飛んでいる: \(missing)"
                                                    + "（繋がった範囲 \(contiguous.map(\.part)) までを使う）"))
            }
            let hasIfo = items.contains { $0.ext == "IFO" && ($0.part == 0 || $0.part == 1) }
            if !hasIfo {
                warnings.append(StructureWarning(code: .unreadableIFO,
                                                detail: "VTS_\(pad(vts)) の IFO が見つからない"
                                                    + "（v1 はファイル名のみで列挙。IFO の実パースは増分）"))
            }
            chains.append(VideoTsChain(vtsNumber: vts, partURLs: contiguous.map(\.url), hasIfo: hasIfo))
        }

        // 0 バイトの IFO（fixture・破損ディスク）は「読めない」の実例として残す。
        for url in entries {
            let ext = url.pathExtension.uppercased()
            guard ext == "IFO" else { continue }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 0 {
                warnings.append(StructureWarning(code: .unreadableIFO,
                                                detail: "\(url.lastPathComponent) が 0 バイト（読めない）"
                                                    + "（v1 はタイトル列挙に使わない）"))
            }
        }

        if !ignored.isEmpty {
            // 名前の付かない VOB 系ファイル（破損・名前変更）は列挙できない実例として残す。
            let vobLike = ignored.filter { name in
                ["VOB", "IFO", "BUP"].contains(where: { $0 == (name as NSString).pathExtension.uppercased() })
            }
            if !vobLike.isEmpty {
                warnings.append(StructureWarning(code: .missingVOB,
                                                detail: "VTS_nn_p 形式でない名前を無視した: \(vobLike.joined(separator: ", "))"))
            }
        }
        return (chains: chains, warnings: warnings)
    }

    /// root 自身か、その直下・ひとつ下の深さで VIDEO_TS ディレクトリを探す（大文字小文字無視）。
    /// 実 DVD のマウント点は root = VIDEO_TS を含むボリューム。ユーザーが VIDEO_TS を
    /// 直接選んだ場合は root 自身を使う（App のディレクトリ選択の実運用に合わせる）。
    static func findVideoTSDirectory(in root: URL) -> URL? {
        let fm = FileManager.default
        if isDirectory(root) && root.lastPathComponent.lowercased() == "video_ts" {
            return root
        }
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsSubdirectoryDescendants]) else { return nil }
        for url in entries where isDirectory(url) && url.lastPathComponent.lowercased() == "video_ts" {
            return url
        }
        return nil
    }

    /// "VTS_01_2.VOB" → (1, 2, "VOB")。VIDEO_TS.* 等は nil。
    private static func parseTitleFileName(_ name: String)
        -> (vts: Int, part: Int, ext: String)? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.uppercased()
        guard ["VOB", "IFO", "BUP"].contains(where: { $0 == ext }) else { return nil }
        let parts = base.uppercased().split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "VTS",
              parts[1].allSatisfy { $0.isNumber }, parts[1].count == 2,
              let vts = Int(parts[1]),
              parts[2].allSatisfy { $0.isNumber }, !parts[2].isEmpty,
              let part = Int(parts[2]) else { return nil }
        return (vts, part, ext)
    }

    private static func pad(_ n: Int) -> String { String(format: "%02d", n) }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
