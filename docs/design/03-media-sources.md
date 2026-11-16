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
    public let vtsNumber: Int
    public let partURLs: [URL]      // 連結順（VTS_nn_1, _2, ...）
    public let hasIfo: Bool
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
- 決定的順序: vtsNumber 昇順・part 番号昇順。`VideoTsPlaybackTests` が fixture 配置で
  タイトル 2 本の列挙と warning 発生を検査する。

### 9.2 多重 VOB 連結（実測で決まった実装形）

AVFoundation の MPEG-PS 処理には 2 つの実測事実がある（2026-11-16、scratch probe +
`ConcatPSDemuxerTests` が兼実測）:

1. **ファイル単位で 0 起点に正規化する**（生素材の先頭 PTS 2.535 s → track timeRange.start=0）。
   よって「素の PTS の縫合」では繋がらない。
2. **AVMutableComposition は PS の sample 時刻を書き換えない**（track timeRange は
   合成オフセットで伸びるが、AVAssetReader は part2 の sample をファイル単位の素の
   時戳のまま返す。境界直後に 0.53 s 台の sample が現れる実測で確定）。

一方、DVD 仕様は「タイトルの VOB 連結は 1 本の連続した MPEG プログラムストリーム」を
保証する（VOB 分割は容器のスライス）。合成 fixture で `cat VTS_01_1 VTS_01_2` が
母素材とバイト一致であることも実測。よって連結 demux は:

```swift
// RVDecode。単一 part はコピーを作らず AVFoundationDemuxer(url:) へ直行。
public actor ConcatPSDemuxer: Demuxer, PCMSampleSource {
    public init(partURLs: [URL])   // 1MB chunk の逐次写しで一時ファイルを作る
}
```

- **バイト連結 + 実証済み単一ファイル経路**を採る。sample 時刻の surgery
  （`CMSampleBufferCreateCopyWithNewTiming`）も、composition のタイムライン合成も不要。
- 契約は「連結後の列は母素材を単一ファイルとして読んだ列と一致」（テストで逐語一致）。
  engine 経由の実測でも demux 180 / 提示 180 が母素材と同じ値で完走（VideoTsPlaybackTests）。
- 代償: open 時にタイトル 1 本ぶんの一時コピー（実 DVD で 1〜8GB）。無連結の
  ブロック供給経路は §9.4 のハング実測を受けて OQ のまま（次項）。

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
  装置ゲート付き（attach 失敗環境では数値を主張しない。実機では合成 ISO で 180 完走実測）。

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
  タイトル 1 の 180 と明確に区別される。`VideoTsPlaybackTests.testTitleSwitchPlaysSecondTitle`
  が 120/120 で兼実測固定。

## 10. v1 増分以降も未実装のまま残す項目（#3 の続き）

- IFO 実パース（chapter 列挙・タイトル長の権威・menu/angle）・`preflight(item:)`。
- タイトル内の chapter マーカー表示と章単位 seek（切り替え UI は §9.6 で実装済み）。
- 光学ドライブ（`DADiskAppeared/Disappeared` 検出・mediaRemoved 実運用）。
- CSS/AACS（§7。OQ-03 のまま）。
- 実在 DVD/ISO の fixture registry（OQ-16/#15。ユーザー実 ISO での open・再生・タイトル
  切り替えの動作は 2026-11-17 に実機で確認済みだが、検査可能な素材として登録されていない）。
