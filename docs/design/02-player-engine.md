# 02. 再生エンジン API と UI との境界（Issue #2）

対象: SwiftUI アプリシェル、再生操作、UI とエンジンの分離。Phase 1 で実装。

## 1. 責務の切り分け

| 層 | 持つもの | 持たないもの |
|---|---|---|
| `RetroVisionApp` (UI) | 窓、コントロール、設定画面、表示中の品質インジケータ | 時刻・デコード・GPU の知識。実装モジュールの import（INV-8） |
| `PlayerViewModel`（UI 側） | 状態の表示整形、コントロールの無効化条件、ユーザー操作の翻訳 | 同期制御、tier 判定 |
| `RVPlaybackEngine.PlayerEngine` | 状態機械、source / decoder / pipeline の組立、`PlaybackSelection` の適用、plan 生成 | 像素単位の処理、推論、UI |
| 各実装モジュール | 実際のデコード・描画・推論 | 再生位置の意味の決定 |

## 2. PlayerEngine プロトコル（#2 の受け入れ基準「defined player-engine protocol」）

```swift
@MainActor
public protocol PlayerEngine: AnyObject {
    // 開く
    func load(_ source: any MediaSource, selection: PlaybackSelection) async throws -> LoadedItem
    func close() async

    // 運送
    func play() async
    func pause() async
    func seek(to time: MediaTime, tolerance: SeekTolerance) async
    func step(_ direction: StepDirection) async      // 1 フレーム送り（deint 検証用）
    func setRate(_ rate: Double) async               // 1.0 のみ対応。0.5 は Phase 5 以降で判断（OQ-09）
    func setVolume(_ gain: Double) async             // 0.0〜1.0 線形。#17 の音量スライダー（決定ログ #14 で追加。phase を変えない）

    // 選択
    func select(_ track: TrackID, for kind: TrackKind) async
    func select(item: ItemID) async                   // DVD title / chapter 相当（03 §5）
    func apply(_ settings: PlayerSettings) async      // 強調化 policy を含む（07 §6）

    // 状態
    var stateSnapshot: PlayerStateSnapshot { get }
    func events() -> AsyncStream<PlayerEvent>         // 1 契約者限定。複数必要な場合は fan-out を engine 側に置く
    var structure: MediaStructure? { get }
}
```

`PlayerEngine` を `@MainActor` に置く理由: UI から呼ぶ入口を 1 か所に固定し、状態機械のレースコンディションを Swift の actor 実行に委ねるため。内部の重い作業は [00 §5](00-architecture.md) の専用 queue に投げ、engine actor は待たない。

実装クラス:

```swift
public actor EngineCore: Sendable { /* 内部状態機械の実体。非公開 */ }
public final class DefaultPlayerEngine: PlayerEngine, @unchecked Sendable { 
    // @MainActor 公開 API → EngineCore へ非同期で転送
}
```

**実装状況（#2・2026-11-16）**: 上記の形のまま実装済み（`DefaultPlayerEngine` は @MainActor、
events の fan-out と snapshot ミラーをここに置く = §4 の「複数契約者が必要なら engine 側」の
実装点）。UI 側のテストスタブ `FakePlayerEngine` はアプリ target 側にある（#17 §6 対応）。
再入安全: close/load で **line generation** を進め、線の外側になった seek 復帰と旧 session の
イベントは黙る（#13 のセッション内ガードの engine 側対応。決定ログ #14）。

## 3. 状態機械

```swift
public enum EnginePhase: Sendable {
    case empty            // source なし
    case preparing        // open + probe + 初期化
    case ready            // 再生可能、未再生
    case playing
    case paused
    case seeking(target: MediaTime)
    case stalled(reason: StallReason)   // バッファ不足・メディア遅延。自動復帰を試みる
    case ended
    case failed(PlaybackError)
}

public enum StallReason: Sendable { case demuxStarved, decodeStarved, mediaSlow, resourceExhausted }
```

遷移（`empty → preparing → ready ⇄ playing ⇄ paused → ended`、`* → failed`、`playing/paused ⇄ seeking`）。

遷移で守る規則:

- `stalled` は `playing` の下位状態ではなく別 phase とする（UI の表示と自動復帰処理を分けるため）。復帰は demux / decode の供給再開で自動。
- `seeking` の間も音声は 0.2 s 以内にミュートする（04 §6）。音声の残留を止めるため、PCM スケジュールは seek 時に flush する。
- 失敗は phase を `failed` にせず、回復可能なものは `stalled` + `RecoveryAdvice` で止まる（INV-1 に従い、再生を止めない選択を先に試す）。
- 設定変更（`apply`）は phase を変えない（INV-3）。

## 4. PlayerEvent / 状態の公開

```swift
public struct PlayerStateSnapshot: Sendable {
    public var phase: EnginePhase
    public var position: MediaTime
    public var duration: MediaTime?
    public var selected: PlaybackSelection
    public var available: [TrackInfo]
    public var quality: QualityPresentation        // tier、適用中の stage、低下理由（08 §6）
    public var decodePath: DecodePathInfo          // hw / sw、codec、profile（#4 の受入基準）
    public var diagnosticsSummary: DiagnosticsSummary  // p50/p95、dropped、queue depth（08 §4）
}

public enum PlayerEvent: Sendable {
    case phaseChanged(EnginePhase)
    case positionUpdated(position: MediaTime, duration: MediaTime?, clockDriftMS: Double)
    case structureChanged(MediaStructure)
    case tracksChanged([TrackInfo])
    case selectionChanged(PlaybackSelection)
    case qualityChanged(QualityPresentation)          // 適応制御による変更をユーザーに伝える
    case enhancementDegraded(reason: DegradeReason, to: QualityTier)
    case warning(PlaybackError)                        // 再生は継続
    case failure(PlaybackError)
    case mediaRemoved                                   // 光学ドライブの取出し
    case statisticsFlushed(DiagnosticsSummary)
}
```

更新頻度の設計（UI を反応させないための約束）:

| イベント | 頻度上限 | 実装 |
|---|---|---|
| `positionUpdated` | 4 Hz（初期値） | engine 側で間引き。UI は補間してプログレスを描く |
| `qualityChanged` / `enhancementDegraded` | 変化時のみ、かつ 1 s 未満の間隔では出さない | 適応制御の hysteresis に従う（08 §5） |
| `statisticsFlushed` | 1 Hz | 診断パネル用。通常 UI は無視できる |
| `structureChanged` / `tracksChanged` | 開く時・item 変更時のみ | — |

**position の非逆行契約（#2 の CI で実測した逆行の修正。2026-11-16）**: `positionUpdated` は
engine が一度出した位置から**自発的に逆行しない**（逆行してよいのは seek の target イベントだけ。
UI のつまみ・時刻表示は逆行すると巻き戻りと区別できない）。engine 実行系は actor なので
session の提示報告（Task 経由）が await で後回しにされ、古い提示が新しい target より「後」に
届きうる（実測: seek(3.0 s) の target イベントの後に 1.6 s 台の位置が混入した）。対策は
engine の受け口での三重の濾過で、session 側の seek 世代（`PlaybackSession.Event.position` の
`seekGeneration`。#13 のガードと同じ値）を照合する: ①`.seeking` 中は全ての position を黙る
（UI は target を表示済み）②受理対象より古い seek 世代を捨てる ③受理位置以下を捨てる。
テスト: `AudioPlaybackTests.testSeekDuringPlaybackResumesWithAudioClockRunning` の
位置単調増加ループ（この契約の検査そのもの。CI で毎 push 走る）。

## 5. PlayerSettings（設定モデルの境界）

`PlayerSettings` は**ユーザー設定（永続）と実行中の policy（一時的）を分離**する。

```swift
public struct PlayerSettings: Sendable, Codable {
    public var enhancementPolicy: EnhancementPolicy   // 07 §6
    public var deinterlaceMode: DeinterlaceMode       // 05 §5
    public var aspectPolicy: AspectPolicy             // .followSource / .fitToDisplay / .manual(AspectRatio)
    public var audioOutputPolicy: AudioOutputPolicy
    public var subtitlePolicy: SubtitlePolicy
    public var advanced: AdvancedSettings             // queue 上限制限、診断記録レベル、モデルの手動選択
}

public enum QualityTier: Int, Sendable, Comparable { case off = 0, metalOnly = 1, lightML = 2, fullML = 3 }
```

永続化は `UserDefaults` + `Codable`（設定ファイルではない。初期値）。診断・ベンチ出力はファイルとして保存する（08 §7）。

## 6. UI 層の設計（#2 の受け入れ基準に対応）

- `PlayerViewModel: ObservableObject` は `PlayerEngine` プロトコルにのみ依存し、`FakePlayerEngine`（同期スタブ）で単体テストする。UI のスナップショットテストに実デコードは不要。
- 映像表示は `MetalVideoView`（`NSView` + `CAMetalLayer`）で、**engine が生成した drawable 予約に描画する**（05 §7）。UI はフレームを生成しない。
- 比率維持: 表示 geometry は engine が伝える `AspectResolution`（01 §2）を使い、`CAMetalLayer` の drawable size に合わせて letterbox / pillarbox を決める。stretch は `AspectPolicy` を明示した場合のみ。
- 窓・FullScreen: `WindowGroup` + `fullScreenCover` ではなく、`NSWindow.toggleFullScreen` を使う（macOS では全屏時に窓のプロパティが変わるため、SwiftUI の全屏 APIs より制御しやすい）。
- コントロールの無効化条件は `PlayerStateSnapshot` から導出し、UI 側に遷移テーブルを書かない。
- 設定 UI のプレースホルダ（#2 の「initially backed by placeholder state」）は、`EnhancementPolicy` の型だけ先に定義し、実装は `.off` 以外動かない状態で置く。UI の形を後から変えないための措置。

## 7. メモリ使用量の目安（設計値。Phase 1 で実測に置換）

| 項目 | 目安 |
|---|---|
| decode 側 CVPixelBuffer プール（480i NV12 × 6 + headroom） | 約 90 MB |
| TexturePool（1080p BGRA × 3） | 約 25 MB |
| 2x SR の中間（960×1080 RGBA16F × 2） | 約 16 MB |
| ML モデル + ワークスペース | 上限 8 GB までに抑える（超えたら tier 低下。08 §5） |
| Audio PCM（0.5 s × 2 ch 48k） | 約 0.4 MB |

上限超過時は `RenderErrorKind.memoryLimit` → tier を 1 段下げる。下げてなお無理なら `.off`。

## 8. #2 の受け入れ基準への対応

| 受け入れ基準 | 設計上の担保 |
|---|---|
| ネイティブ macOS アプリとして起動 | App/RetroVisionApp（SwiftUI、App Sandbox 有効） |
| 再生操作中も UI が反応する | engine actor + 専用 queue。UI 更新頻度の上限（§4） |
| 再生操作が定義済み protocol 経由 | `PlayerEngine`（§2）。Fake で検証可能 |
| 比率維持・全屏 | `AspectResolution` の提供と `AspectPolicy`、`toggleFullScreen` |
| 後から DVD 操作・字幕・強調化を載せても作り替えない | `MediaStructure` / `TrackInfo` / `PlayerSettings` を先に型として置く（01 §3、03、07） |
