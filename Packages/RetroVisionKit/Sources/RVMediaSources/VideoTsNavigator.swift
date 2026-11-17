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
/// menu チェーン = VMGM（VIDEO_TS.VOB。03 §5 のメニュー増分）: vtsNumber 0、isMenu true。
/// 列挙側はこれを常に先頭に置く（first-play 政策は PlayerViewModel。#17 系）。
/// タイトルメニュー（VTS_nn_0.VOB。実盤の「本当のメニュー」。静止画 1 枚 + ボタンの字幕）も
/// menu チェーン: vtsNumber = nn（> 0）、isMenu true。VMGM の直後、タイトル本体の前に並ぶ。
public struct VideoTsChain: Sendable, Hashable {
    /// VTS_01 → 1。ファイル名の数字から取る。menu は 0（titleNumber 0 と同じ約束）。
    public let vtsNumber: Int
    /// 連結順（VTS_nn_1, VTS_nn_2, ...）。
    public let partURLs: [URL]
    /// VTS_nn_0.IFO か VTS_nn_1.IFO が見つかっているか（v1 は「存在」のみを見る）。
    public let hasIfo: Bool
    /// VMGM メニュー（VIDEO_TS.VOB）のチェーン。
    public let isMenu: Bool

    public init(vtsNumber: Int, partURLs: [URL], hasIfo: Bool, isMenu: Bool = false) {
        self.vtsNumber = vtsNumber
        self.partURLs = partURLs
        self.hasIfo = hasIfo
        self.isMenu = isMenu
    }

    /// warning 文面などに使う表示名（実体名で出す — 「VTS_00」のような機械名にしない）。
    public var label: String {
        if isMenu {
            return vtsNumber == 0 ? "VMGM menu (VIDEO_TS.VOB)"
                : "VTS_\(String(format: "%02d", vtsNumber)) menu (VTS_\(String(format: "%02d", vtsNumber))_0.VOB)"
        }
        return "VTS_\(String(format: "%02d", vtsNumber))"
    }

    /// タイトルメニュー（VTS_nn_0.VOB）か。VMGM（vtsNumber 0）は含まない。
    public var isTitleMenu: Bool { isMenu && vtsNumber > 0 }
}

public enum VideoTsNavigator {
    /// root（DVD-Video のルート、または VIDEO_TS を直接指す URL）からタイトル列を作る。
    /// VIDEO_TS ディレクトロが見つからなければ nil（呼び出し側は「DVD-Video ではない」と扱う）。
    /// 戻り値の chains は menu（VMGM・VIDEO_TS.VOB）があれば先頭に 1 本、以下 vtsNumber の
    /// 昇順。partURLs は part 番号の昇順（決定的順序）。
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
        // VMGM メニュー（VIDEO_TS.VOB。03 §5 のメニュー増分）。多重 part の VMGM は
        // 観測例の無い形なので単一 VIDEO_TS.VOB のみ（未来の OQ — 他 VIDEO_T* 名は
        // 下の「形式外 name」warning に残る）。
        var menuVOBs: [URL] = []
        var menuHasIfo = false

        for url in entries.sorted(by: { $0.path < $1.path }) {
            let name = url.lastPathComponent
            guard isRegularFile(url) else { continue }
            let baseName = (name as NSString).deletingPathExtension.uppercased()
            let nameExt = (name as NSString).pathExtension.uppercased()
            if baseName == "VIDEO_TS" {
                // 大文字小文字は無視（macOS へのコピーで case が揺れる実運用対策）。
                switch nameExt {
                case "VOB": menuVOBs.append(url)
                case "IFO", "BUP": menuHasIfo = menuHasIfo || nameExt == "IFO"
                default: break
                }
                continue
            }
            guard let parsed = Self.parseTitleFileName(name) else {
                // VTS_VO.* はオーサリングツールが置くことがある（title0 menu。v1 は対象外）。
                if baseName != "VTS_VO" {
                    ignored.append(name)
                }
                continue
            }
            grouped[parsed.vts, default: []].append(Entry(vts: parsed.vts, part: parsed.part,
                                                          ext: parsed.ext, url: url))
        }

        var chains: [VideoTsChain] = []
        var titleMenus: [VideoTsChain] = []
        for vts in grouped.keys.sorted() {
            // VTS_00_* は VMGM が書く実例が無い（0 は menu 側で使う数字）。列挙しない。
            if vts == 0 { continue }
            let items = grouped[vts]!
            // VTS_nn_0.VOB はタイトルメニュー（実盤の「本当のメニュー」: 静止画 + ボタンの字幕）。
            // タイトル本体の列には入れず、menu チェーンとして別に持つ。0 バイト（fixture・破損）は
            // 再生できないので持たない。ボタンの操作（IFO・NAV・字幕）は未実装 — 静止画を表示するだけ。
            if let menuVOB = items.first(where: { $0.ext == "VOB" && $0.part == 0 }),
               let size = try? menuVOB.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                let menuHasIfo = items.contains { $0.ext == "IFO" && $0.part == 0 }
                titleMenus.append(VideoTsChain(vtsNumber: vts, partURLs: [menuVOB.url],
                                               hasIfo: menuHasIfo, isMenu: true))
            }
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

        // VMGM menu chain（VIDEO_TS.VOB）は常に先頭（titleNumber 0 / ItemID(0) の約束。
        // 実盤の first-play 入口は menu — 再生開始の政策自体は PlayerViewModel が持つ）。
        // 並び: VMGM → タイトルメニュー（vts 昇順）→ タイトル本体（vts 昇順）。
        chains.insert(contentsOf: titleMenus, at: 0)
        if !menuVOBs.isEmpty {
            chains.insert(VideoTsChain(vtsNumber: 0, partURLs: menuVOBs.sorted { $0.path < $1.path },
                                       hasIfo: menuHasIfo, isMenu: true),
                          at: 0)
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
