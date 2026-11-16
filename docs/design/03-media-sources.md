# 03. メディアソース抽象と DVD（Issue #3）

対象: 光学ドライブ / VIDEO_TS フォルダ / DVD ISO の開く・列挙・選択。Phase 2。

## 1. 抽象の狙い

optical・folder・ISO の 3 種を**同じ再生インターフェース**に通す（Issue #3 の scope）。差異は「ブロックを読む方法」と「構造の作り方」に閉じ込め、上位（Demuxer・Engine）はDisc の意味を知らない。

```swift
public protocol MediaSource: Sendable {
    var descriptor: SourceDescriptor { get }
    /// 開いて構造を作る。重い処理は内部の demuxQueue で実行する（INV-4）
    func open() async throws -> OpenedSource
}

public struct SourceDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable { case opticalDisc, videoTsFolder, discImage, plainFile }
    public let id: SourceID
    public let kind: Kind
    public let displayName: String
    public let location: SourceLocation        // bookmark / device path / URL
    public var protectionHint: ProtectionHint  // .unknown / .unprotected / .protectedCss / .protectedAacs
}

public struct OpenedSource: Sendable {
    public let reader: any BlockReader
    public let structure: MediaStructure
    public let formatHint: FormatHint
}
```

## 2. BlockReader（IO の一本化）

VIDEO_TS のファイル群も、ISO の画像も、光学ドライブも「ブロック番号 → 2048 バイト」で読める。この 1 本に寄せることで、ISO をマウントせずに扱える（マウントは権限・待機・失敗パターンを増やすため避ける）。

```swift
public protocol BlockReader: Sendable {
    var blockCount: Int64 { get }
    var blockSize: Int32 { get }            // DVD は 2048 固定
    func read(block: Int64, count: Int32) throws -> Data       // 同期。demuxQueue からだけ呼ぶ
    func prefetch(block: Int64, count: Int32)
    func invalidate()                       // メディア取出し時
}
```

| 実装 | 読む対象 | 備考 |
|---|---|---|
| `FolderBlockReader` | VIDEO_TS.VOB / VTS_01_0.VOB … を連結した仮想空間 | セクタ変換表を内部に持つ（VTS 単位・ファイル跨ぎ） |
| `ISOBlockReader` | ISO 内の FILE 構造を自力で辿る（ISO9660/UDF の最小リーダー） | 領域跨ぎ (extent) 対応が必要。UDF 版は Phase 2 で検証（OQ-04） |
| `OpticalBlockReader` | `DADiskAccess` で得た raw device を `readAt` で読む | シーク位置の読取は光学 drive で遅い（数十 ms）。prefetch 戦略が効く |

- `prefetch` は 32〜64 ブロック単位（初期値）の先読み。光学ドライブでは seek を避けるため title 先で大きく読む。
- 読み取り失敗（メディア取出し・CRC エラー）は `SourceErrorKind.mediaRemoved` / `.unreadable` を投げ、上位は `PlayerEvent.mediaRemoved` か `warning` に翻訳する（02 §4）。

## 3. 構造モデル（MediaStructure）

```swift
public struct MediaStructure: Sendable {
    public let itemKind: ItemKind            // .dvdTitles, .playlist, .singleItem, .unknown
    public var items: [MediaItem]
    public var warnings: [StructureWarning]  // 「IFO と VOB の長さが食い違う」等を列挙
}

public struct MediaItem: Sendable, Identifiable {
    public let id: ItemID
    public var titleNumber: Int?             // DVD の title（1 始まり）
    public var partNumber: Int?              // VTS_PGCITI の cell part 情報
    public var playableFrom: PlayableFrom    // .whole / .cell(cells) / .chapterRange(...)
    public var duration: MediaTime?
    public var trackTable: [TrackInfo]
    public var videoFormat: VideoFormatDescription?
    public var chapters: [ChapterMark]
    public var angles: [AngleInfo]
    public var stillImage: Bool
    public var buttonTargets: [ButtonTarget] // 後継（menu 操作）で使う。Phase 2 では解析のみ
    public var aspectFlag: AspectFlag?       // IFO 側の 4:3/16:9 指示（01 §2 の優先順位テーブルに入る）
}
```

## 4. libdvdread / libdvdnav との境界

C API は `CRetrodvdShim` に閉じ、Swift 側は「ifo の読み」「title/chapter 情報」程度の構造体しか見えないようにする。

```swift
// CRetrodvdShim が公開する最小セット（設計例）
public struct DvdDiscInfo { public let titleCount: Int32; public let titles: [DvdTitleInfo] }
public struct DvdTitleInfo { public let tt: Int32; public let vts: Int32; public let pgc: Int32;
                             public let chapters: [DvdChapter]; public let playbackEntries: [DvdPlaybackEntry]
                             public let audioStreams: [DvdStreamInfo]; public let spuStreams: [DvdStreamInfo] }
```

統合方針:

- 構造解析は **libdvdread（ifo read）を主**にする。`dvdread_open_file_image` / `DVDFileIO` の block-reader 差し込み口を使い、`BlockReader` を渡す形を Phase 2 で先に確認する（OQ-01）。
- 再生順（PGC / cell / playback chain）は **libdvdnav のVM（virtual method）解釈に依存**する。ただし Phase 2 では、libdvdnav を使わず IFO の playback chain を自力で辿る経路も持っておく（menu・angle がある盤だけ libdvdnav を使う二段構え）。理由: libdvdnav の配布とライセンス確認が未了のため（OQ-03）。
- CSS 保護は `DVDCssBackend` プロトコルで差し替える（INV-7）。

```swift
public protocol DVDCssBackend: Sendable {
    func authenticate(_ reader: any BlockReader) async -> CssAuthResult
    func decrypt(block: Int64, into: UnsafeMutableRawPointer, count: Int32) -> Bool
    var licenseState: LicenseState { get }   // .unlicensed / .licensedVendor(id) / .notRequired
}
```

## 5. 選択と item

- `select(item:)` は `ItemID` を受け取り、`PlayableFrom` から demux の開始位置（ブロック番号・PTS の開始）を決める表を作る。chapter 間は同一 VTS 内なら seek で跨げ、VTS 跨ぎなら開き直しになる。
- 再生前に「その item が開けるか」を `preflight(item:)` で確認する（保護のため開けない、対応しない codec を含む）。UI は開く前に理由を表示できる。
- Chapter 間は `ChapterMark` をタイムラインに露出し、UI は chapter 単位で seek できる（Issue #3 の「titles and chapters are enumerated」）。

## 6. ソース検出とエラーの扱い

| 事象 | 検出 | 上位への伝え方 |
|---|---|---|
| 光学ドライブに Disc が入った | `DADiskDisappeared` / `DADiskAppeared` の notification | `SourceListChanged`（UI の候補更新）。自動再生しない |
| Disc があるが DVD でない（CD / BD / データ盤） | 最初の 16 ブロックに VIDEO_TS.IFO が無い | `SourceErrorKind.unsupportedStructure`。UI は「DVD を検出できません」+ 盤種の手がかり |
| VIDEO_TS があるが IFO が壊れている / VOB が欠けている | 構造解析の warning | `structure.warnings` に載せ、再生できる part だけで開く（完全失敗にしない） |
| ISO が壊れている / 領域跨ぎが解決できない | ISOBlockReader の解析失敗 | `.malformedStructure`。Phase 2 では「別のツールで変換してください」は出さない（自力で解決を試みる） |
| 権限が無い（sandbox / 外部 volume） | open 失敗 | `.permissionDenied` + `RecoveryAdvice.needsUserAction(.grantPermission)` |
| 再生中に Disc が抜けた | read 失敗 + media removal event | `PlayerEvent.mediaRemoved` → phase `.stalled(.mediaSlow)` → 再挿入で自動再開を試みる |

## 7. 保護ディスク（CSS / AACS）の扱い

- 回避・鍵の抽出は実装しない（Epic / Issue の明示）。`DVDCssBackend` の実装が「認証と復号」をすべて持つ。
- Phase 2 で対応するのは **非保護 / ユーザーオーサリング盤のみ**。CSS 盤は `LicenseState.unlicensed` で開いた時点で `.protectedNeedsLicense` を返し、UI は「この盤は保護されており、再生ライセンスの確認が完了していません」と表示する。
- 判断が必要な項目（libdvdcss の導入可否、商用 SDK の評価、BD の AACS）は [10-open-questions.md](10-open-questions.md) の OQ-03 に集約。Phase 3 以降に問い合わせを開始する（リードタイム）。

## 8. #3 の受け入れ基準への対応

| 受け入れ基準 | 設計上の担保 |
|---|---|
| UI でソースを選べる | `SourceDescriptor` + 検出（§6）。`MediaSource.open()` |
| title / chapter を列挙 | `MediaItem` / `ChapterMark`（§3、§5） |
| ソースエラーでクラッシュしない | エラー値 + `RecoveryAdvice`（01 §5、§6） |
| 依存のライセンスと配布義務の文書化 | `ThirdPartyNotices` に機械化された書式で記録（[09 §6](09-testing.md)）。OQ-01 / OQ-03 |

## 9. v1 増分として実装済みの経路（#3。2026-11-16 実測）

§4 の libdvdread/libdvdnav 統合は未実装のまま（OQ-01 のまま）。#3 の第一増分は
**依存ゼロの経路**で VIDEO_TS / ISO を再生可能にした。以下は実装され、テストで
固定された形（コード側の実測注記と同源）。

### 9.1 タイトル列挙（IFO 非パースの v1）

```swift
// RVMediaSources（純 Foundation。RVDecode を import しない境界は維持）
public struct VideoTsChain: Sendable, Hashable {
    public let vtsNumber: Int      // menu（VMGM）は 0（titleNumber 0 と同じ約束）
    public let partURLs: [URL]      // 連結順（VTS_nn_1, _2, ...）
    public let hasIfo: Bool
    public let isMenu: Bool        // VMGM（VIDEO_TS.VOB）。列の先頭に置く（§9.7）
    public var label: String       // warning 等の表示名（実体名。VTS_00 にしない）
}
public enum VideoTsNavigator {
    /// nil = DVD-Video 構造でない（呼び出し側は .unsupportedStructure を構成できる）。
    public static func chains(in root: URL) -> (chains: [VideoTsChain], warnings: [StructureWarning])?
}
```

- 列挙は VIDEO_TS のファイル名走査のみ。IFO の実パース（タイトル数の権威・chapter・
  トラック表）は増分として保留。IFO が無い・0 バイトのタイトルは `unreadableIFO` の
  warning を列挙する（#3 受入基準「IFO と VOB の長さが食い違う等を列挙する」の最初の項）。
- part 番号の飛びは `missingVOB` を残し、繋がった範囲だけを使う。先頭 part (_1) の
  無い VTS はタイトルにしない。`VTS_nn_0.VOB`（メニュー用）は列から除く（実 DVD 配置の実測）。
- 決定的順序: menu（VMGM。下記）が先頭、以下 vtsNumber 昇順・part 番号昇順。
  `VideoTsPlaybackTests` が fixture 配置での列挙と warning 発生を検査する。
- **menu（VMGM）列（2026-11-17 追加、§9.7）**: `VideoTsChain` に `isMenu` を持つ。
  `VIDEO_TS.VOB` が見つかれば `vtsNumber 0`・`isMenu true` のチェーンを列の**先頭**に置く
  （item は `ItemID(0)` / `titleNumber 0`。§9.7 の first-play 政策の材料）。`VIDEO_TS.IFO` の
  存在は menu chain の `hasIfo` として立てる。多重 part の VMGM は観測例の無い形なので単一
  VIDEO_TS.VOB のみ（他 VIDEO_T\* 名は「形式外 name」warning に残る）。VTS_nn_0.VOB の
  まま（VTS メニュー）は対象外を継続。

### 9.2 多重 VOB の segment demux + 時刻縫合（実測による設計差し替え。2026-11-17）

AVFoundation の MPEG-PS 処理には 2 つの実測事実がある（2026-11-16、scratch probe。
concat 期の検査は退場し、以下は `SegmentPSDemuxerTests` と issue #3 が兼実測で確定）:

1. **ファイル単位で 0 起点に正規化する**（生素材の先頭 PTS 2.535 s → track timeRange.start=0）。
   よって「素の PTS の縫合」では繋がらない。
2. **AVMutableComposition は PS の sample 時刻を書き換えない**（track timeRange は合成
   オフセットで伸びるが、AVAssetReader は part2 の sample をファイル単位の素の時戳のまま
   返す。境界直後に 0.53 s 台の sample が現れる実測で確定。composition 案も退場）。

当初実装の ConcatPSDemuxer（バイト連結 → 単一 AVURLAsset）は合成 fixture では成立した
（demux 180 = 母素材と一致）が、**実写の長いマルチパート VTS で壊れる**ことが実測で確定した
（issue #3、PICHI 実 ISO）:

- **崩壊形の実測**: 4 パート連結の duration が 76.064 s に崩壊。part 4 単体でも
  92,865 s と誤読され reader が 3.2 s / 92 sample で停止した。
- **根本原因は part 4 内部のプログラム再開始**（連結という器ではない）: parts 1〜4 の
  PES PTS は raw で 0.189→2935.455 s と連続だが、バイト 338,876,430 で 0.189→75.965 s へ
  戻る（≈ −2,935 s 逆行）。**この点を跨いでも pack SCR は連続**（実測: 338.6〜339.0 MB 窓に
  負の SCR ジャンプ無し）= 単一 VOB に続けて記録された別プログラム。
- **PES 5-byte タイムスタンプフィールドだけを正しく寄せる修復で全文字通り読む**:
  正しい layout の PES のみ修復写し（break 338,876,430・patches 2,501 個。temp の
  repaired4b.mpg で兼実測）→ duration 357.184 s、reader 完走 10,699 sample
  （0.221→357.163）。対照: 未修復 part 4 単体は 92 sample。SCR は読まない・触らない
  （FFmpeg の PS demuxer も pack header を完全に読み飛ばす — libavformat/mpeg.c 実測。
  走査の pack 前進式は GStreamer と同じ 14 + stuff。PICHI 実測で一致）。

本増分は **無連結・part 単位 demux + demux 内侧の時刻縫合**へ差し替える:

```swift
// RVDecode。全チェーン（単一 part 含む）がこの経路 — 単一 part は素のファイル経路と
// 逐語一致（SegmentPSDemuxerTests §5 実測）。単一 part 内部の程序再開始も修復できる。
public actor SegmentPSDemuxer: Demuxer, PCMSampleSource {
    public init(partURLs: [URL])   // part 単位の AVFoundationDemuxer。修復写しは deinit で掃除
}
// RVDecode。PS start code 走査 + PTS 再開始の修復計画/適用（RV_DEBUG_PSREPAIR=1 で opt-in 診断）。
public enum ProgramStreamRepair {
    public static func repairedCopyIfNeeded(of url: URL) async -> (repairedURL: URL, finding: Finding)?
    static func scanFields(in buf: UnsafeRawBufferPointer, visitor: (_ at: Int, _ hasDTS: Bool) -> Void)
    static func plan(in buf: UnsafeRawBufferPointer) -> (patches: [Patch], breaks: [Int64])
}
```

- **時間基盤**: 各 part の duration 累積をオフセットにする（上記実測事実 1 に依存）。
  part 2 以降の sample には `CMSampleBufferCreateCopyWithNewTiming` で時戳を寄せて運ぶ
  （03 旧 §9.2 で「避ける」とした sample 時戳 surgery — 連結が壊れる以上 surgery を避ける
  経路が存在しない。demux の内側に閉じ込め、engine・session は従来どおり単一 sample 列を
  見る（04 §2 の契約不変）。
- **修復の発火はスキャン検出のみ**（PES PTS 逆行 ≥ 2.0 s = `programBreakSeconds`）。
  ファイル名・サイズ等の heuristics は無い。clean な part は写しを作らない（PICHI
  parts 1〜3 で plan ゼロ・写し無し実測。fixture clean 連鎖でも検査で固定）。検出時は
  warning code `.ptsRestartRepaired`（逆行バイト位置・寄せたフィールド数）を structure に載せる。
- **PES ヘッダは 2 形を実観測（両方読む。FFmpeg `mpegps_read_pes_header` と同じ判別
  `(c & 0xE0) == 0x20`）**:
  * '10xx' marker 形（PES-2。PICHI 実写: video PES flags 0x81/0xC1。PTS/DTS flags）
  * length 直後の '001x' 形（PES-1 旧形。ffmpeg 生成 fixture: '0011' PTS、lead '0001'
    継続で DTS。ffprobe pts=48003 / dts=45000 と実バイト一致で確定）
- **5-byte タイムスタンプの canonical layout（実バイトの round-trip で証明）**:
  `lead(4) P[32:30](3) '1' P[29:15](15) '1' P[14:0](15) '1'`（P[29:15] は bit31..17、
  marker bit16）。PICHI VTS_01_1 の実フィールド 0x31000184eb = 0.18903 s を delta 0 で
  再符号化すると恒等（SegmentPSDemuxerTests §7）。*以前使った 2 実装（Python 実証と
  Swift 初期版）は bit16/15 を取り違えていた。当時の実測値（319.266 s 等）は誤り二つが
  打ち消しあった値で、本 layout の round-trip 検証に差し替え置き換えられた。
- **既知のトレードオフ（受容。cell 時刻縫合は別増分）**:
  * オフセット = duration 総和の規則は、境界で両 part が自分の窓に含む frame のぶん
    母素材の単一ファイルタイムラインより大きい（fixture 実測 +0.123 s = 6.107 vs 5.984。
    実写 PICHI の part 間は 0.5 s 級 gap があり overcount は有界）。
  * 境界の frame 喪失: この合成 mpeg2 fixture は open GOP で、I 境界で切っても part1 末尾の
    forward reference frame が part 単体では復号できない（実測 86+90=176/180 = 4 帧喪失。
    gen-dvd-fixture.sh は ffprobe 実測の keyframe PES 位置で分割する — 中央の任意 pack
    境界スライスだと part2 先頭 15 帧が落ちる実測）。実 DVD authoring は closed-GOP の
    cell で切るためこの喪失は 0（PICHI 実盤で part 全体が通る実測）。
  * 再開始の結合点は設計上 0 间隔（lastSeen アンカー。以降は同一 delta の平行移動で
    順序・間隔は保存される）。IFO PGCI による章境界の切り分けは別増分。
- **契約（`SegmentPSDemuxerTests` が兼実測）**: (a) part1 相当領域は単一ファイル読みと
  逐語一致、(b) frame 集合の喪失 ≤ 4（この fixture の forward reference 上限）で幽霊
  frame 無し、(c) 縫合後の位置 drift < 0.25 s・提示順に並べて単調・プログラム単位
  （≥ 2 s）の逆行無し・音声 PCM は単調 PTS で 2 本ぶん届く。単一 part は素の経路と
  逐語一致。再開始の無い連鎖は写しを作らない。修復算術は合成バイト列で厳密
  （1.5 s の小刻み逆行は触らず ≥ 2.0 s のみ lastSeen 直後へ続ける。実ファイル実バイトの
  canonical round-trip）。実写に観測例の無い「SCR・PES とも再開始する 2 連結」形は
  reader が continuation の明示時刻しか通さない（境界は IFO cell で扱うまで完全な
  通读を期待しない — 限界メモとして検査で固定）。
- engine 経由の実測（VideoTsPlaybackTests、2026-11-17）: VTS_01（keyframe 整合 2 分割）の
  demux/提示 = 176（母素材 180 − 境界 4 帧。§上の喪失説明と一致）。合成 ISO 経由も同じ。
  旧 concat 期の 180 完走記録は §9.6 の fixture 変更メモ（2026-11-17）まで有効だった。

### 9.3 ISO（ディスクイメージ）= マウント経路

```swift
// RVPlaybackEngine。diskutil を process 起動（hdiutil は deprecated 警告のため使わない）。
public actor DiscImageMediaSource: MediaSource, DemuxerProviding {
    public init(isoURL: URL)
    public func close() async   // demuxer を降ろしてから eject（実測で順序が要る）
}
```

- `diskutil image --plist attach` → `system-entities[].mount-point` / `dev-entry` を読む
  （テキスト整形に依存しない。キー名は実測: `dev-entry` の値はノード名のみ）。
- 解除は `diskutil eject <node or mount>`（`diskutil image` に eject/detach は無い）。
  AVFoundation がボリューム上の file を開いたままだと素の eject は
  "at least one volume could not be unmounted" で失敗 → **demuxer cache を降ろしてから
  eject、失敗時は force**（force は常に出る。UI の eject 同意は optical 実装まで棚上げ）。
- 開いた後は内部の `VideoTsMediaSource`（マウント点の VIDEO_TS）へ委派。e2e は
  装置ゲート付き（attach 失敗環境では数値を主張しない。実機では合成 ISO で完走実測 — 現行の完走実数は §9.2 末尾、旧 concat 期は 180）。

### 9.4 無マウント（ブロック供給 → AVFoundation）の実測結果

`BlockReader`（memory/ファイル供給）から AVFoundation へ渡す無名経路は、合成 ISO の
供給で `loadTracks` が解決されず 30 s 超ハング（2026-11-16 実測、issue #3 に記録）。
libdvdread の `DVDFileIO`（C のブロック読み口）に相当する差し込み口は AVFoundation に
対応物がない。よって §4 の block-reader 統合は libdvdread 実装の設計として残し、
無名供給で AVFoundation を読ませる道は separate gate の実験（OQ-01 の証拠として記録）。

### 9.5 一つの入口（URL → source 型）

```swift
public enum MediaSourceRouting {
    public static func makeSource(for url: URL) -> any MediaSource
    public static func isDiskImageURL(_ url: URL) -> Bool
}
```

- ディレクトリ → `VideoTsMediaSource`（ボリュームルート/VIDEO_TS 直下の両対応）、
  ディスクイメージ UTI → `DiscImageMediaSource`、その他 → `FileMediaSource`。
- `FileMediaSource` の disk-image 事前ゲート（AVError -11828 実測）は安全網として維持。
- Engine の配線口は `DemuxerProviding`（item 引数つき）に一般化。FileMediaSource は
  itemId を無視する退化ケース（`makeDemuxer(itemId:)` = 同一实例の約束は継続）。

### 9.6 タイトル切り替え（2026-11-17 実装済み。#3 追加分）

実運用で「ISO を開くとおそらく最初のチャプター（実際は VTS_01 タイトル）しか再生されない」
と報告された。v1 の境界（全タイトルを列挙するが engine は ItemID(1) を選ぶだけ）への
応答として、`select(item:)` を実際の切り替えとして実装した。

- **切り替え意味論（決定）**: `EngineCore.select(item:)` = 「同じ source の再 load」。
  lineGeneration を進めて旧線を黙らせ、旧 session を stop、新しい item へ配線し直して
  warmup → `.preparing → .ready`。position は 0 に戻る（`positionUpdated(.zero)` が
  単一の初期化経路）。再生の継続ではなく停止 → 押し直し（v1。 autoplay の継続は増分）。
- **items.first 固定の修正（実測で顕在化）**: snapshot の duration / available、seek の
  duration イベント、rebuildPlan、tracksChanged は selected item に従う（`selectedItem()`
  経由）。2 本目に切り替えても UI の長さが 1 本目のまま、という実測が修正の根拠。
- **source 側の冪等 open**: VideoTsMediaSource は構造と demuxer を、DiscImageMediaSource は
  マウントを cache（再 load で再 probe・再連結・再 attach をしない。実測: attached の ISO を
  再度 attach すると「〜 1」付きの別マウントが増える。多重 VOB の再連結コピーは GB 級）。
  demuxer の同一实例契約は open をまたいても保つ（検査で固定）。
- **load での session 停止**: 以前は 2 回目の load で旧 session が止められていなかった
  （ファイルの 2 回目 open でも同じ。本増分で load 冒頭に停止を追加）。
- **UI**: メニューバーの「映像タイトル」（transport バーの film アイコン）。multi-item
  構造のときだけ表示。選択は engine へ `select(item:)` を投げ、表示更新は
  selectionChanged / tracksChanged / positionUpdated(.zero) からのみ反映（#17 の単一経路）。
- **fixture 変更（判别可能化）**: VTS_02_1.VOB を truncated-01.mpg（4.04 s の別素材）の
  複製に変更。単一 MPEG の機械スライスだとタイトル 1 に近く、e2e が数値で区別できなかった。
  実測: タイトル 2 の raw probe = total 122 / valid 120 / lastPTS 3.971 s、
  engine 経由 = demux 120 / 提示 120（0 長 marker 2 件は demux 縁の間引き。OQ-23 の意味論と一致）。
  タイトル 1（当時は concat 経由 180。2026-11-17 の segment 差し替えで 176 — §9.2）と
  明確に区別される。`VideoTsPlaybackTests.testTitleSwitchPlaysSecondTitle`
  が 120/120 で兼実測固定（title 2 は単一 part のため影響なし）。

### 9.7 menu（VMGM）と first-play（2026-11-17 実装済み。ユーザー実測要望）

実盤（PICHI）を開いたとき「最初のメニュー画面（11 s 級の VMGM video）が出て、それが
終わると本編へ進む」のが DVD プレーヤ実機の挙動。v1 は ITEM 列に VMGM を載せず、
PlayerViewModel が `PlaybackSelection(item: ItemID(1))` をハードコードしていたため
 menu 画面が一切出なかった。

- **列の約束**: `VideoTsNavigator` が `VIDEO_TS.VOB` を menu chain（`vtsNumber 0`・
  `isMenu true`）として検出し、chains の**先頭**に置く（§9.1）。`VideoTsMediaSource` は
  同じループで `MediaItem(id: ItemID(0), titleNumber: 0)` を作る（model 変更なし —
  titleNumber は Option で、0 は「menu」の予約値として UI 側で「メニュー」表示にする）。
  menu は単なる VOB チェーンとして SegmentPSDemuxer を通る（実測: PICHI VIDEO_TS.VOB は
  単体 probe 11.0 s で問題無し。VTS_01_0.VOB は duration が nan で読めない — 除外のまま。
  menu 素材が開けない盘は structure warning を残して menu 無しで開く）。
- **選択の構造駆動化（API 変更）**: `PlayerEngine.load(_:selection:)` の selection が
  `PlaybackSelection?` へ変わる。nil = 「open 後、構造の先頭 item で解決する」
  （EngineCore は open 後 `structure.items.first` で解決し selectionChanged を同じ
  単一経路で流す。tracksChanged より先に解決 — tracksChanged が selectedItem() を読む
  ため）。VIDEO_TS では menu が先頭 = menu 優先、menu の無い盘は従来どおり先頭タイトル。
  明示指定の呼び出し（タイトル切り替え・テスト）は無変更で通る。
- **first-play 政策（PlayerViewModel。UI 側政策として engine に意味を渡さない）**:
  構造に `titleNumber == 0` の item が在るときだけ自动再生する（盤挿入=再生開始の実機
  挙動）。menu の無い素材（ファイル・menu 無し盘）は #17 の user gate のまま。
  menu の再生が `.ended` になったら最初の本体タイトル（titleNumber 最小）を
  `engine.select(item:)` + `play()` で自動進行する（単一経路原則のため政策の発火は
  phaseChanged(.ended) からのみ。`menuAdvancePending` ガードで同一 .ended の多重発火を
  防ぎ、selectionChanged の観測で解除。本体タイトル側では再発火しない）。
- **検査**: `VideoTsNavigatorTests`（menu 先頭列・menu 無しで項を作らない・VTS_nn_0 は
  対象外のまま）、`VideoTsPlaybackTests`（structure items [0,1,2] と menu duration、
  menu の engine 完走 120/ended）、`PlayerViewModelTests`（menu 構造の open で
  ItemID(0) 既定選択 + 自动再生、.ended → select+play 自動進行 1 回だけ、menu 無し盘は
  自动再生しない — user gate 不変）。
- **限界（次の増分）**: VMGM のInteractive menu（PU/PGC 命令・ボタン）は未実装 —
  メニューは「video として线性に再生」するだけ（IFO VMGM PGCI パースとセットの増分）。
  複数 part の VMGM（VIDEO_T0.VOB 等）は観測例が無いため未対応（形式外 name warning に残る）。

## 10. v1 増分以降も未実装のまま残す項目（#3 の続き）

- IFO 実パース（chapter 列挙・タイトル長の権威・menu/angle）・`preflight(item:)`。
- タイトル内の chapter マーカー表示と章単位 seek（切り替え UI は §9.6 で実装済み）。
- 光学ドライブ（`DADiskAppeared/Disappeared` 検出・mediaRemoved 実運用）。
- CSS/AACS（§7。OQ-03 のまま）。
- 実在 DVD/ISO の fixture registry（OQ-16/#15。ユーザー実 ISO での open・再生・タイトル
  切り替えの動作は 2026-11-17 に実機で確認済みだが、検査可能な素材として登録されていない）。
