# 08. 適応品質制御とメトリクス（Issue #9）

対象: 期限超過時の降格、計測、ベンチマーク出力、ユーザーへの表示。Phase 5。

## 1. 制御の対象と方針

- 制御するのは **強調化の強さ**（QualityTier、モデル variant、推論領域、滤镜の on/off）であり、再生・運送・音声の設定ではない。
- 音声と運送は常に権限を持つ（INV-1）。制御ループは再生スレッドを一度も待たせない（`diagnosticsQueue` で動き、engine へは action を投稿するだけ）。

## 2. 信号（入力）

| 信号 | 出所 | 用途 |
|---|---|---|
| 段ごとの実行時間 p50/p95 | `MetricStageSample`（01 §6、05 §8） | 予算超過の判定 |
| 期限超過（deadline miss） | 各 frame の target present time と実際の比較 | 降格の主信号 |
| present jitter | `addPresentedHandler` / `presentedTime`（05 §7） | 表示の不均等の監視 |
| queue 深度 | 00 §5 の各 queue | 供給不足と過剰蓄積の区別 |
| dropped / late / skipped frames | 04 §9 | 降格理由の判定 |
| ML の失敗率・breaker 状態 | 06 §6 | 障害と負荷の区別 |
| GPU / システムメモリ | `MTLDevice.currentAllocatedSize`、`DispatchSource.memoryPressure` | tier 上限の引き下げ |
| 温度状態 | `ProcessInfo.processInfo.thermalState` | 予防的降格 |
| display refresh 実測 | drawable 間隔 | 想定と違う場合の plan 再生成（05 §5.3） |

## 3. 観測の定義（曖昧さを作らない）

- **frame deadline**: `deadline = PTS に応じた提示予定 vsync + 1 vsync の余裕`。
- **miss**: 提示が deadline より遅れた、または frame を落とした。
- **window**: 2 秒（初期値）。p95・超過率・queue 平均はこの窓で計算する。
- **clean window**: 超過率 0 で、p95 が予算の 85% 以下。
- 数値はすべて 0.1 s 分解像で ring buffer に保持し、1 s 集計を UI とレポートに出す。

## 4. 制御則（hysteresis を持つ）

```
毎 window（2 s）ごとに評価:
  if 超過率 > 15%            → degrade(1)      # 一段下げる
  elif 超過率 > 8%           → hold            # 変更しない
  elif p95 > 予算の 92%      → hold + 予防的フラグ
  elif 2 consecutive clean windows → upgrade(1) # 一段戻す（条件は §5 の hysteresis）
```

予防的な手段（事象が起きる前に効く）:

| 条件 | 動作 |
|---|---|
| `thermalState >= .serious` | 1 段下げる（`.fullML → .lightML`） |
| `thermalState == .critical` | `.metalOnly` まで下げる |
| memory pressure warn | ML を unload し、`.metalOnly` |
| ML 失敗が 5 フレーム中 3 回 | breaker open（06 §6）。10 分間 `.metalOnly` |
| present jitter が 8 ms を超える窓が 2 個続いた | in-flight を 1 に減らす（待ちで悪化しないように） |

## 5. 適用できる action と順序

降格は**影響の小さい順**に適用する（Issue #9 の scope をそのまま順序にした）:

1. `bypassStage(sharpen | grainPreserve | 任意の滤镜)` — 低優先の滤镜を切る
2. `setTemporalBlend(off)` — 時間合成を止める（計算量より見た目の安定に効く）
3. `switchModel(variant = lighter)` — 同じ variantGroup の軽量版へ。負荷が下がれば戻す
4. `reduceInferenceScale(factor)` — 推論対象領域を絞る（上下の均一な部分だけ簡略化）またはタイル数を減らす
5. `skipEnhancementEvery(n)` — n フレームに 1 度だけ強調化し、結果を短期間再利用する（1 フレーム分のフリーズに見えるリスクがある。既定の末尾）
6. `setTier(lower)` — tier 自体を 1 段下げる（`.fullML → .lightML → .metalOnly → .off`）
7. `unloadModel()` — メモリ逼迫時のみ

昇格は、上記の逆順で**1 window に 1 action だけ**。一度に戻さない（戻した瞬間に再び落ちる、という振動を防ぐ）。

hysteresis: 昇格には 2 個の clean window（4 s、初期値）を要求し、降格から 10 s 間は昇格しない。ユーザーが明示的に選択した tier 上限は、制御が超えて**上げられない**（07 §1）。

## 6. ユーザーへの表示（#9 の「user-visible quality/performance indicator」）

```swift
public struct QualityPresentation: Sendable {
    public var requestedTier: QualityTier      // ユーザー設定
    public var activeTier: QualityTier         // 制御後の実際
    public var appliedStages: [StageID]        // 実際に plan に入った段
    public var activeModel: ModelID?
    public var degradeReasons: [DegradeReason] // .loadHigh / .thermal / .memory / .modelFailure / .displayMismatch
    public var frameStats: FrameStats          // 直近 p50/p95、dropped、jitter
}
```

UI は 2 段階で見せる:

- 通常: 小さな状態表示（「強調化: 標準 / 一時低下: 負荷」）。理由と実際の tier を 1 行で。
- 詳細（診断 panel）: §7 の 1 s 集計を表示。段ごとの内訳を出す。

## 7. メトリクスとベンチマークの出力形式

### 7.1 ランタイムメトリクス（JSON Lines、診断保存用）

```json
{"t":1763000000.123,"window":2.0,"tier":"lightML","stages":{
  "videoDecode":{"p50":2.1,"p95":4.0},"deinterlace":{"p50":0.9,"p95":1.4},
  "tensorInput":{"p50":0.4,"p95":0.6},"mlInference":{"p50":6.2,"p95":9.1},
  "tensorOutput":{"p50":0.5,"p95":0.8},"scale":{"p50":0.3,"p95":0.5},"present":{"p50":0.2,"p95":0.4}},
 "endToEnd":{"p50":11.9,"p95":17.2},
 "frames":{"total":60,"presented":59,"dropped":1,"late":1,"enhancementSkipped":3},
 "clock":{"driftP50MS":0.4,"driftMaxMS":6.1,"audioUnderruns":0},
 "resources":{"gpuMB":412,"appMB":690,"anePct":38,"gpuPct":44,"cpuPct":12,"thermal":"nominal"},
 "queues":{"decoded":2,"mlInFlight":1,"demuxPackets":28}}
```

### 7.2 ベンチマークレポート（`bench/reports/<date>-<rev>.json`）

Issue #9 の「reproducible across model and pipeline revisions」に応える形。環境・入力・結果を同一文書に固定する。

```json
{
  "schemaVersion": 2,
  "run": {"id":"2026-11-15T10:00:00Z","gitRev":"abc1234","appVersion":"0.1.0",
          "machine":{"model":"Mac17,14","chip":"M5 Max","memoryGB":64,"os":"27.2.1 (26B131)"},
          "display":{"refreshHzMeasured":59.94,"pixels":"3840x2160"}},
  "input":{"fixtureId":"ntsc480i-mixed-01","sha256":"…","resolution":"720x480","cadence":"interlaced22",
           "durationS":60,"frames":1798},
  "pipeline":{"tier":"fullML","planHash":"…","stages":["deinterlace","colorConvert","superResolution","denoise","present"],
              "model":{"id":"sr.realesrgan.x2plus","revision":"1","computeUnits":"anePreferred","tile":"192x108+16"}},
  "budgetMS":{"decode":6,"deinterlace":3,"inference":18,"post":2,"present":1.5,"headroom":3},
  "results":{"fpsTarget":29.97,"fpsMeasured":29.97,"endToEnd":{"p50":11.9,"p95":17.2,"max":24.8},
             "deadlineMissPct":0.2,"dropped":1,"jitterMS":0.8,"drift":{"p50":0.4,"max":6.1},
             "perStage":{ "...": "08 §7.1 と同じ形" }},
  "quality":{"psnr":null,"ssim":null,"vmaf":null,"flickerIndex":null,"notesRef":"bench/notes/…md"},
  "comparison": {"baselineRunId":"2026-11-01T…","diff":{"endToEndP95MS":-2.1,"dropped":0}}
}
```

- `planHash` は plan 構成の安定ハッシュ（stage + パラメータの正準表現）。これで「同じ plan を再現できる」ことを示す。
- 品質指標が `null` の箇所は、実行していない項目を**空欄にせず null で置く**（欠落と未実施を区別する）。
- 比較は `baselineRunId` を持つ。開発計画のゲート（G1/G2/G3）で必ず 1 本の baseline を固定し、以後の比較基準にする。

### 7.3 生成経路

`BenchTools/benchmark-runner`（CLI ターゲット）が、fixture を指定 tier で再生し、上の JSON を出す。UI からの実行は「診断を保存」で §7.1 の JSON Lines を書くだけ。CLI は CI の nightly で回す（09 §7）。
