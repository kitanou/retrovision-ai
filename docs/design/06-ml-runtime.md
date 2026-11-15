# 06. Core ML 実行層（Issue #6）

対象: 差し替え可能な推論実行層、モデル契約、テンソルとフレームの橋渡し、障害分離。Phase 3。

## 1. 目的と、対象に含めないもの

- 目的: 「フレームを入れれば、決まった形の出力が出る」実行層を 1 つ作り、**モデルの差し替えと tier 変更が再生に波及しない**こと。
- 対象に含めないもの: モデルの選択・学習・変換パイプラインそのもの（07 で扱い、変換環境は [00 §7](00-architecture.md) の venv）。

## 2. モデル契約（Model Manifest）

モデルはバンドル内のディレクトリとして置き、メタデータを JSON で持つ。Issue #6 の「record model version, license, input dimensions, precision and runtime configuration」をこの 1 ファイルに集約する。

```json
// models/realesrgan-x2plus-v1/model.json  (RVModelManifest v1)
{
  "schemaVersion": 1,
  "id": "sr.realesrgan.x2plus",
  "revision": "1",
  "displayName": "Real-ESRGAN x2plus",
  "task": "superResolution",
  "scaleFactor": 2,
  "license": { "spdx": "BSD-3-Clause", "weightsLicense": "要確認", "outputRightsConfirmed": false, "noticeTextPath": "LICENSE.txt" },
  "compiledModel": "model.mlmodelc",
  "checksum": "sha256:…",
  "input":  { "name": "image", "kind": "image", "width": 256, "height": 144, "pixelFormat": "BGRA8", "dataType": "float16",
              "normalization": { "mean": [0,0,0], "scale": 1.0 }, "alphaMode": "none" },
  "output": { "name": "image", "kind": "image", "width": 512, "height": 288, "pixelFormat": "BGRA8", "dataType": "float16" },
  "constraints": { "multipleOf": 16, "maxPixels": 4194304 },
  "computeUnitsPreference": "anePreferredWithGpuFallback",
  "variantGroup": "sr-family",
  "memoryEstimateMB": 850,
  "expectedLatencyMS": { "p50": 6.0, "p95": 9.5 },
  "measuredOn": { "device": "M5 Max 64GB", "os": "27.2.1", "date": "2026-11-XX", "report": "bench/…json" }
}
```

```swift
public struct ModelManifest: Codable, Sendable { /* 上の JSON に対応。unknown field は復元側で allow */ }
public struct ModelID: RawRepresentable, Sendable, Hashable { public var rawValue: String }  // "sr.realesrgan.x2plus@1"
```

設計上の要点:

- **`measuredOn` が無いモデルは実行しない**（G3 の運用ルール）。`expectedLatencyMS` が欠けるモデルは load できるが、tier `.fullML` には入れられない。
- `outputRightsConfirmed: false` のモデルは、開発ビルドでは動く。リリースビルドでは UI に「出力の利用権を確認中」と表示する（[開発計画 §7 R6](../DEVELOPMENT_PLAN.md) に対応）。
- `variantGroup` は軽量版・重厚版を束ねる。08 の tier 制御は group 単位でモデルを切り替える（`MLModelCollection` を使うなら variant はこれで表現する。SDK に `MLModelCollection` は存在することを確認済み）。

## 3. 実行層の API

```swift
public actor EnhancementModelRuntime {
    public func discover() -> [ModelManifest]
    public func load(_ id: ModelID, preference: ComputeUnitsPreference) async throws -> LoadedModel
    public func unload(_ id: ModelID) async                       // 08 の tier 低下時に呼ぶ
    public func predict(_ request: InferenceRequest) async throws -> InferenceResult
    public func health(of id: ModelID) -> ModelHealth             // p50/p95、失敗率、breaker 状態
}

public struct InferenceRequest {
    public let model: ModelID
    public let input: FrameHandle                 // 段の出力（05 §1）
    public let output: FrameHandle                // 呼び出し側が確保（pool 由来）
    public let deadline: HostTime                 // 超えたら結果は捨てられる
    public let frameID: FrameID
}

public enum ComputeUnitsPreference: Sendable { case automatic, anePreferred, gpuOnly, cpuOnly }
```

- `MLModel.loadModel(contentsOf:config:)`（async、SDK で確認済み）で load する。load は **plan 生成の同期経路では呼ばない**。`load` は tier 変更時に非同期で走り、間に合わない frame は `.metalOnly` 相当で描く（INV-2）。
- unload は「in-flight が 0 になった時点で実行」。ワークセットの強制解放（`MLModel` の破棄）で memory を戻す。
- deadline 超過は `ModelErrorKind.deadlineExceeded` を返す。結果は捨て、`InferenceResult` を参照した段は前フレームの continue ではなく、**その frame は非強調のまま提示**する（古い画像を保持するとフリーズに見えるため）。

## 4. フレーム ↔ テンソルの橋渡し（変換コストを分離計測する）

`StageID.tensorInput` / `StageID.tensorOutput` を独立して測る（Issue #6 の「measure conversion overhead separately」）。

```swift
struct TensorBridge {
    // 入力: FrameHandle(Metal texture, BGRA8/RGBA16F) → MLFeatureValue
    //   方針 A: CVPixelBuffer feature（Metal 互換 pool から作った buffer を渡す）→ Core ML 内部で変換
    //   方針 B: MLFeatureValue(buffer:dataType:shape:) で MTLBuffer を直接渡す（自前で pack）
    // 出力: MLPredictionOptions(outputBackings: [MTLBuffer.self])（SDK で確認済み）
    //       → kernel `tensor_to_texture` で texture に戻す（layout: NCHW float → RGBA）
}
```

| 方針 | メリット | 懸念 | 状態 |
|---|---|---|---|
| A. CVPixelBuffer 入力 | 実装が短い。model 側の image preprocessing に寄せられる | model の要求 pixelFormat と一致しない場合に変換が入る。色域・前処理の control が失われる | Phase 3 の最初の実験として使う |
| B. MTLBuffer 入力 | 変換を自前で制御。ゼロコピーに近い | pack kernel を自前実装。dynamic shape だと layout が変わる | A を測ったうえで切替える |
| Metal feature provider（`MTLTextureFeatureProvider` 等） | 本命になりうる | **この SDK の CoreML ヘッダに見つからなかった** | 採用しない。OQ-07 |

`tensor_to_texture` kernel は、NCHW/NHWC と dataType（float16/float32）を受け取る汎用 1 本を持つ。変換後の texture は `FrameHandle` になり、以降は通常の段として扱える。

## 5. 計算単位と形状

- `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine` / `.cpuAndGPU` / `.all` を選択可能にする（SDK で確認済み）。既定は `.all`（automatic）で始め、**実測で決める**。ANE は固定寸法で威力が出る傾向があるため、寸法が複数出る運用（SD 素材の寸法差、4:3/16:9）では GPU の方が安定する可能性がある。この仮説は Phase 3 の G3 で検証する。
- 寸法戦略: テイル（タイル）分割で固定サイズ推論を繰り返すか、dynamic shape を使わせるか。既定は**タイル分割 + 16 px のオーバーラップ**（境界の継ぎ目を消す）。overlapped blend は `blend` kernel で行う。dynamic shape を許すモデルは manifest の `constraints` に記述し、`maxPixels` で守る。
- タイル数は 08 の tier で制御する（`reduceInferenceScale` は「推論する領域を絞る」ではなく「より小さいモデル variant を選ぶ」方が品質の落ち方が穏やかなため、両方を action として持つ）。

## 6. 障害分離（INV-1、#6 の受入基準）

| 事象 | 検出 | 挙動 |
|---|---|---|
| load 失敗・未コンパイル | `ModelErrorKind.notCompiled` / `.conversionUnsupported` | そのモデルを除外。tier を 1 段下げる。UI に理由 |
| shape 不一致 | `shapeMismatch` | plan を作り直す（tile 設定を修正）。直 frame は非強調 |
| deadline 超過 | `deadlineExceeded` | 結果を破棄。非強調提示。超過率が 2 窓続いて 30% を超えたら tier 低下（08 §5） |
| 推論の例外・NaN | NaN 検査（`validate` kernel、低頻度でサンプル検査） | 出力を破棄。breaker 加算 |
| 連続失敗 | failure breaker: 5 フレーム中 3 回失敗 → open | 10 分間 open を保ち、half-open で 1 本だけ試す。breaker 中の AI は無効（`ModelErrorKind.disabledByBreaker`） |
| メモリ逼迫 | `DispatchSource.memoryPressure` warn + `MTLDevice.currentAllocatedSize` | unload → tier 低下 |

いずれの場合も**音声・運送には影響しない**（INV-1）。`PlayerEvent.enhancementDegraded` で UI に伝える（02 §4）。

## 7. 実行レイアウトと実行時間管理

```
mlQueue（serial）
  ├─ inference job: predict (async)         ← in-flight ≤ 2（00 §5）
  ├─ validate job（サンプルのみ）
  └─ unload job
```

- job 投入時点で `deadline = targetPresentTime - postBudget(2 ms) - safety(1 ms)` を計算する。間に合わない job は**投入しない**（先読みで捨てる）。
- 完了した結果は `frameID` ごとに保持し、present 予定時に未完了ならその frame は非強調で提示する（待つことを選ばない）。
- `in-flight` 上限を 1 に下げる action は 08 の degradation に含まれる（待ちが深くなると jitter が増えるため）。

## 8. テストハーネス（#6 の「test harness using representative SD frames and synthetic inputs」）

- 合成入力: グラデーション、市松、1 像素の線、字幕風の白抜き、ノイズ合成（固定シード）。これらの出力から「値が範囲外、NaN、全部一色、期待寸法と違う」を機械検査する（09 §5）。
- 代表 SD フレーム: 09 §2 の fixture から取得した PNG を CVPixelBuffer にして入れる。黄金値（golden）は取らず、**統計的な健全性検査**（ヒストグラムが大きく崩れない、SNR が閾未満にならない）に留める。黄金値は 07 の品質評価に置く。
- tiny model（故意に作る 32×32 入力・数十 KB）を使い、契約検査（load → predict → 出力 layout → unload）だけを CI の毎回で回す。重いモデルの検査は nightly（09 §7）。
