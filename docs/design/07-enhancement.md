# 07. 強調化ステージ（Issue #7 超解像、#8 ノイズ除去）

対象: 学習ベースの超解像・ノイズ除去と、非 AI の Metal 代替。Phase 4。

## 1. ステージとしての形

すべての強調化は `VideoStage`（05 §1）または `ModelBackedStage` として表現し、**plan に現れる順序とパラメータで挙動を決める**。新しい滤镜を加えるとき、エンジン側にコードを追加しない。

```swift
public struct SuperResolutionParameters: StageParameters {
    public var model: ModelID
    public var targetHeight: Int32            // 480 → 960 等。表示解像度ではなくこの段の出力
    public var tile: TilePolicy               // 幅・overlap・blend
    public var temporalBlend: TemporalPolicy  // off / light / strong（07 §4）
}

public struct DenoiseParameters: StageParameters {
    public var strength: Double               // 0.0…1.0。既定 0.35
    public var targets: OptionSet<ArtifactKind>  // .blocking / .ringing / .mosquito / .chromaNoise / .grain
    public var protect: OptionSet<ProtectKind>   // .faces / .lineArt / .grain / .fineTexture / .subtitles
    public var implementation: DenoiseImplementation   // .metalGuided / .learned(ModelID) / .both
}

public struct EnhancementPolicy: Sendable, Codable {
    public var tier: QualityTier              // ユーザーの上限。08 の自動降格はこれを超えて上げることはできない
    public var allowAutomaticTierChange: Bool // 既定 true
    public var order: ProcessingOrder         // .deintThenSrThenDenoise / .denoiseThenSr / .srOnly / .denoiseOnly
    public var sr: SuperResolutionPolicy      // .off / .auto / .on(ModelID?)
    public var denoise: DenoisePolicy
    public var modelOverrides: [String: ModelID]  // 上級設定。空が既定
}
```

`EnhancementPolicy.tier` は**ユーザーの上限**であり、実際の tier は 08 の制御が決める（`PlayerStateSnapshot.quality` に両方出す）。

## 2. 超解像（#7）

- 目標: 480p → 約 960p/1080p。ディスプレイが 1080p より広い場合、残りは Metal の `MPSImageScale`（SDK で確認済み）で拡げる。**AI 段を 2 段直列にしない**（時間予算と品質の破綻が増えるため）。
- 寸法: SR の入力は「deint 後・色変換後・display aspect に正規化された元寸法」を使う。720×480 の 4:3 素材 → 表示寸法 720×540 → SR 出力 1440×1080 → final scale。この「SR 前の寸法決め」が品質に効くため、`RenderPlan.output` に明示し、ベンチレポートにも載せる（08 §7）。
- モデル選択の UI: `PlayerSettings.advanced.modelChoice` で list を出す（#7 の「expose model selection and AI on/off controls」）。list は manifest の `task == superResolution` で絞る。
- AI on/off は**その場で反映**する（INV-3: 次の frame の plan から変わる）。既存の in-flight frame は古い plan で完了する。

### 2.1 モデル比較の記録形式（#7 の受け入れ基準「documented model comparison exists」）

比較表はリポジトリに機械可読で置く（`bench/model-comparison/`）。各行が 1 candidate：

| 列 | 内容 |
|---|---|
| id / revision / license / outputRightsConfirmed | manifest 由来 |
| 静止品質 | PSNR、SSIM、VMAF（09 §5 の手順で算出）。加えて 12 枚の主観レビュー評価（詳細は humans による記載） |
| 時間安定性 | 連番クリップでのフレーム間差分の分散、フリッカ指数 |
| 症状 | ringing / texture hallucination / line thicken / color shift の有無とseverity |
| 実行 | p50/p95 推論時間、メモリ、compute unit、変換の成功可否 |
| 結論 | `selected` / `rejected(reason)` / `deferred(verification)` |

「selected」は G3 の判定後にだけ付与できる（開発計画 Phase 3）。

## 3. ノイズ除去（#8）

- アーティファクトの分離（Issue #8 の scope）に対応させるため、`targets` を OptionSet で持つ。実装は filters を束ねた 1 graph にし、**有効なものだけ plan に現れる**。
- 非 AI 経路（`implementation = .metalGuided`）:
  - `.blocking`: ブロック境界（8 px）の差分を抑える guided filter / エッジ保存平滑化
  - `.ringing`: 局所勾配が急峻な場所の overshoot を戻す（unsharp の逆）
  - `.mosquito`: 動きのある縁の周辺だけを狙う（motion map を 05 §5 の field match から貰う）
  - `.chromaNoise`: 色チャンネルの平滑化 + 色相保持
  - `.grain`: 粒子を残す設定（default: off。`protect.grain` が有効なら触らない）
- 学習系（`.learned(ModelID)`）は 06 の契約を通る小さなモデル（SR より入出力寸法が同じもの）を使い、`strength` は blend 係数で表現する（学習出力と元フレームの線形合成。これにより strength の効き方が predictable になる）。
- 既定値は**保守的**（Issue #8 の要求）: `strength = 0.35`、`targets = [.blocking, .chromaNoise]`、`protect = [.faces, .lineArt, .grain, .fineTexture, .subtitles]`。
- 強度変更は plan パラメータの変更で済み、再生を止めない（INV-3）。on/off も同様（#8 の受入基準）。

## 4. 順序と時間的な安定性

- `ProcessingOrder` で順序を設定できる（Issue #8 の要求）。既定は `deint → SR → denoise`。
  - `denoise → SR`: ノイズを先に消すと SR が平坦な面に強めの詳細を置きにいく。アニメ素材では有利な場合がある。
  - `SR → denoise`: SR 後の ringing / hallucination を抑える。実写・ノイズの多い素材向けの既定。
- 時間安定性への対処（R3 の対策）:
  - `temporalBlend = .light`（既定 off）は、前フレーム出力との軽い合成（blend 係数 0.15 初期値）。動きのある領域では motion map で重みを落とす。
  - 過度な合成は ghosting を生む。`.strong` は tier `.fullML` の時だけ選べる。
  - 字幕は SR の後に置く（04 §7、05 §4）。字幕を temporal blend に巻き込むと字幕の縁が滲む。

## 5. 品質プリセット（UI 向け）

`QualityTier` とユーザー設定の間にプリセットを置く（設定 screen の复杂さを抑えるため）。

| preset | tier | SR | denoise | 用途 |
|---|---|---|---|---|
| `.off` | .off | off | off | 診断・比較・省電力 |
| `.standard` | .metalOnly→.fullML | auto | strength 0.35 | 既定 |
| `.conservative` | .lightML | auto（軽量 variant） | strength 0.2 | 負荷の低い機械・長時間再生 |
| `.maximum` | .fullML | auto（最重量 variant） | strength 0.5 | 静的な素材・検証用 |
| `.custom` | ユーザー指定 | 詳細設定 | 詳細設定 | 上級者 |

プリセットは `EnhancementPolicy` の短縮形であり、**プリセット自体は plan に現れない**（plan は展開後のパラメータのみ持つ。診断で「ユーザーが選んだもの」と「実際に適用されたもの」を分けて表示するため、`QualityPresentation` に両方載せる）。

## 6. 非 AI の代替経路（INV-2）

| 目的 | 非 AI 実装 | tier |
|---|---|---|
| 拡大 | `MPSImageScale`（高品質フィルタ選択可） | .metalOnly |
| 輪郭強調 | unsharp mask（過度にかけない。強度上限あり） | .metalOnly |
| ノイズ除去 | §3 の guided filter 系 | .metalOnly |
| 色・レンジ | 05 §3 の変換 | .off |
| デインターレース | 05 §5 の motionAdaptive | .off |

`.off` tier でも `.metalOnly` でも**色・比・deint は同じ方針**で動く（品質設定が変わっても正しさは変わらない、という設計方針）。

## 7. before / after 比較（#8 の受入基準「before/after captures」）

- `A/B` 比較機能: 同一 frame を 2 とおりの plan で描き、**左右分割または交互表示**で UI に出す。実装は「frame ごとに交互の plan を使う」だけ（INV-3 に従い、交互の切替は frame 境界）。
- 静的キャプチャは `bench/captures/` に PNG + plan JSON + metrics JSON で保存する。再現性は「素材のハッシュ + git revision + model revision + plan JSON」で担保する（09 §5）。

## 8. #7 / #8 の受け入れ基準への対応

| 項目 | 担保 |
|---|---|
| documented model comparison | §2.1 の機械可読表 + G3 判定 |
| 選定モデルが明確に改善し、容認できない artifact が無い | §2.1 の症状列 + 主観レビュー（09 §5） |
| M5 Max での実時間を測って報告 | 06 §2 の `measuredOn` + 08 §7 のレポート |
| 非 AI fallback が常に使える | §6（INV-2） |
| denoise の on/off・強度 | §1・§3（INV-3 で frame 境界反映） |
| 深刻な temporal flicker・detail smearing が無い | §4 の temporal 制御 + 09 §5 の連番クリップ検査 |
| 遅延・メモリ増加の記録 | 08 §4 の per-stage 計測（baseline との差分で出す） |
