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
