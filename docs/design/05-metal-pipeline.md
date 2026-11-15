# 05. Metal レンダーパイプライン（Issue #5）

対象: CVPixelBuffer 取り込み、デインターレース、色・比、合成、提示、GPU 計測。Phase 2 の中心。

## 1. 設計の中心概念

- **RenderPlan**: 1 フレーム分の処理手順を表す不変のデータ。生成後は変更しない（INV-3）。設定変更や tier 変化は新しい plan を生む。
- **RenderGraph**: plan を Metal の command buffer に落とす実行器。段の追加・削除は plan の書き換えだけで、コードの変更を要しない。
- **FrameHandle**: 中間フレーム（01 §4）。`TexturePool` が寸法・レイアウト単位で再利用する。

```swift
public struct RenderPlan {
    public let id: PlanID
    public let tier: QualityTier
    public let stages: [StageRequest]        // 実行順に並ぶ
    public let output: OutputContract        // 表示解像度・色・比・字幕合成の要否
    public let budget: FrameBudget           // 00 §6 の配分（plan ごとに検証）
}

public struct StageRequest {
    public let stage: StageID
    public let parameters: StageParameters   // enum。段ごとの設定値
    public let inputs: [FrameRole]           // .current / .previousOutput / .fields(a,b)
}

public protocol VideoStage {
    static var id: StageID { get }
    func encode(_ req: StageRequest, io: StageIO, into encoder: MTLRenderCommandEncoder, context: RenderContext)
}
```

`VideoStage` は同期（encoder に描画コマンドを発行するだけ）。推論を伴う段（07 §4）は例外で、**推論は別キューで先に済ませ、その結果を texture として plan に差し込む**形にする。command buffer の途中で CPU に戻りたくなる処理を作らない。

## 2. 取り込み（zero-copy）

```swift
// CVMetalTextureCacheCreate（SDK で確認済み）で CVPixelBuffer → MTLTexture plane を作る
MTLTextureDescriptor(pixelFormat: .r8Unorm / .rg8Unorm)  // NV12 の luminance / chroma
```

- NV12 の Y plane（`.r8Unorm`）と UV interleaved plane（`.rg8Unorm`）をそのままバインドする。IOSurface 共有なのでコピーは発生しない。
- P010 / BGRA なども同じ口を通す。対応しない layout（例: planar YUV 非連続 stride）は `CVMetalTextureCache` が作れないため、`FormatRejected` として SW 経路に倒す。
- 取り込みの失敗（pool 枯渇）を `RenderErrorKind.memoryLimit` として拾い、tier を 1 段下げる。

## 3. 色・レンジ・マトリクス

- YCbCr→RGB は fragment shader の関数テーブルから選択する。`MTLSamplerDescriptor` の yCbCr conversion は、4:2:0 のオフセットが DVD の co-sited / co-sited-ish な配置と食い違う可能性があるため使わず、**自力で sample 位置を決める**（Phase 2 で visual 比較して確認する）。
- `ColorInfo` の matrix / primaries / transfer / range から変換行列を生成し、`constant` buffer に載せる（PSO の張り替えを避ける）。
- 転送関数が `.unspecified` の SD 素材は、既定で BT.601 / video range とみなすが、**その assumption を plan に焼き付けて表示・診断に出す**（05 §6）。
- 中間フレームは RGBA16F を基本にする（SR 段が浮動小数を要求するため）。色域の変換は行わず、数値は 0..1 の linear-ize された状態で行うか、元の gamma のままかを一 plan 内で統一する。既定は「BT.601 変換後、linearize せず 0..1 のまま SR を通す」で、モデルの学習前処理に合わせる（モデル契約に前処理を含める。06 §4）。

## 4. 合成段の順序（固定ポリシー）

```
[fields] → deinterlace / inverse telecine → color convert → [scale to source display size]
        → [AI: super-resolution] → [denoise / restoration] → [subtitle composite]
        → [final scale to drawable] → present
```

- AI 段の**後に**字幕を合成する（04 §7）。最終スケールで 4K 等のディスプレイに合わせる。
- ノイズ除去を SR の前か後かに置く設定は 07 §5 で扱うが、既定は上（SR → denoise）とする。SR の前に置くと、モデルがノイズをディテールとして増幅する。
- 字幕を合成しない frames（字幕なし区間）は plan から抜く（empty stage を埋めない）。

## 5. デインターレースとキャデンス

**判断は 2 段階**に分ける。まず source の性質を決め（detector）、次に方式を選ぶ（mode）。

### 5.1 detector（`FieldMatch` / `CadenceAnalyzer`）

- 入力: 2 field の texture（または interlaced frame）。MPS または自前 kernel で 8×8 block の field 間 SAD を作る。
- 出力: `CadenceDecision { isInterlaced: Bool, movingBlocks: Float, telecinePattern: TelecinePattern? , confidence: Double }`。
- 3:2 telecine は、連続 10 フレームの field 差分パターンから検出し、一致が続く間だけ **inverse telecine（24p 化）**へ進む。一致が崩れたら即座に interlaced 扱いに戻す（hysteresis 2 フレーム）。誤検出による 24p 化は表示が引っかかるため、確信度が低い場合は inverse telecine を使わない。
- decisions には必ず「根拠」を残す（`confidence` と block map のハッシュ）。後から画像比較で検証できるようにするため（09 §5）。

### 5.2 mode（`DeinterlaceMode`、ユーザー設定と tier で決まる）

| mode | 内容 | 使う条件 |
|---|---|---|
| `.passthrough` | field をそのまま提示（weave） | progressive 判定時。静止画像 |
| `.bob` | 各 field を full height に拡大 | 低速経路・診断用。tier `.off` の safe 側 |
| `.edgeDirected` | 空間方向の補間（エッジ追従）。単一フレームのみ | 動き検出が使えない時の中間解 |
| `.motionAdaptive` | field 差分で weave / deinterlace を block 単位で選択（yadif 相当） | 既定（tier `.metalOnly` 以上） |
| `.inverseTelecine` | 24p 復元 + 2:3 で再提示 | telecine 検出時のみ |
| `.auto` | detector の結果から上記を選択 | **UI の既定値は auto**。実挙動は plan に記録 |

実装配置: field 抽出と block decision map は compute kernel、weave / deinterlace の選択適用は 1 pass の fragment/compute で行う。motion adaptive の追加入力として「直前の出力」を使う場合は `inputs: [.previousOutput]` で明示する（寿命管理は INV-5 に従う）。

### 5.3 表示側のキャデンス（`PresentScheduler`）

`frameRate` は有理数で持つ（01 §2）。present 計画は vsync に合わせてパターンの整数比で組む:

| source | 60.00 Hz 表示 | 59.94 Hz 表示 | 120 Hz 表示 |
|---|---|---|---|
| 29.97p / 29.97i | 2,2,2,2,2,2,3 パターンで丸め誤差を吸収 | 2,2 を維持（59.94 が実効） | 4 本ずつ |
| 25.00p / 25.00i | 2,2,3,2,2,3…（5 フレームで 12 vsync） | 同期しないため periodic 補正 | 5 本ずつ |
| 24p（inverse telecine 後） | 2:3 pulldown | 2:3 + 周期補正 | 5:5 |

丸め誤差の吸収は「同じフレームを 1 本長く出す」場所を分散させる（毎秒同じ位置で引っかからないようにする）。実測される display refresh は `CAMetalLayer` の drawable 間隔から推定し、想定と食い違う場合は plan を作り直す（08 §3）。

## 6. 比・切り出し

優先順位テーブル（上位から採用）:

1. source の明示的な **目標 DAR 指示**（DVD: IFO の aspect flag + MPEG-2 display extension の `aspect_ratio_information`。これは 4:3 / 16:9 / 2.21:1 を直接示す）
2. clean aperture（pan-scan / film aperture の切り出し情報。IFO の line21 / pan-scan vector は Phase 2 では解析のみ）
3. codec の sample aspect からの導出（ITU-R BT.601: NTSC 720×480 → 10:11、PAL 720×576 → 12:11）
4. `AspectPolicy.userOverride`

**720 幅のまま比率計算をしない**。BT.601 の sample aspect はアクティブ映像（NTSC では 704 / 711 サンプル相当）に対する定義で、DVD が保持する 720 サンプルにはブランキング部分が含まれる。720×480 に 10:11 をそのまま掛けると 1.364 になり、4:3（1.333）から約 2.3% 横に広がって見える。

したがって計算順序は:

```
targetDAR（§6 の 1 で得る） と codedSize → 必要な cleanAperture（幅の切り出し） を求める
                                     ↘ 切り出せない場合は letterbox で解決し、引き伸ばさない
```

- `AspectResolution`（`targetDAR` と `cleanAperture`）は 1 か所で計算し、UI と pipeline の両方に同じ値を渡す（表示側と処理側で比率計算を分けると、letterbox が 1 像素ずれる）。
- 1 が得られない素材（生成物・自己編集素材でメタデータが無い）では、**既定を 4:3 にしない**。`AspectPolicy.followSource` が解決できない場合は UI で選択を求め、選択内容は plan に記録する（09 §5 の比較再現性のため）。

- buffer の寸法を変えない。**スケールは geometry と final scale で行う**（deint 前に倍率を変えると field の意味が変わるため）。
- 4:3 素材を 16:9 画面に出す場合、両側 letterbox を既定とする。引き伸ばしは `AspectPolicy.fitToDisplay` を明示した時だけ。

## 7. 提示（present）

```swift
// CAMetalLayer.displaySyncEnabled = true（SDK で確認済み）
let drawable = layer.nextDrawable()
let presentTime = predictedPresentTime(for: framePTS)     // PresentScheduler が決めた vsync index
drawable.present(at: presentTime)                        // 未来 vsync を指す
drawable.addPresentedHandler { drew in
    let actual = drew.presentedTime                       // 実際の提示時刻（SDK で確認済み）
    metrics.recordPresent(frameID: id, scheduled: presentTime, actual: actual)
}
```

- 未来の vsync に present 予約することで、**1 フレーム分の前倒し確保**（decode → present）を確保する。これは AI 段の猶予にもなる。
- 予約できない场合（drawable が見つからない、display mode が変わった）は `RenderErrorKind.drawableLost` → 即座に plan を作り直し、その frame は捨てて次を出す。
- `presentsWithTransaction = false`（UI との同期を待たない）。
- in-flight は最大 3（00 §5）。`MTLDrawable` の保留数が上限に達している場合、新規エンコードを待たずに**その frame を drop** して present 側を進める（INV-1 の一環: 音声は待たない）。

## 8. GPU 計測（#5 の受入基準「GPU timings and end-to-end frame latency are instrumented」）

| 手段 | 用途 | 備考 |
|---|---|---|
| `MTLCounterSampleBuffer`（`MTLCounters.h`、SDK で確認済み） | 段ごとの GPU 実行時間 | counter set は device の `supportedCounterSets` から選択。使えない family では wall time のみにフォールバック |
| CPU 側の `TimeSource` | 段の投入・完了时刻 | `MetricStageSample`（01 §6） |
| `addPresentedHandler` / `presentedTime` | 予約と実提示の差（jitter） | 08 §3 の入力 |
| `MTLDevice.currentAllocatedSize` | GPU メモリ使用量 | tier 判定に使う（08 §5） |
| `MTLCompileOptions` + `MTLLibrary` の error output | shader コンパイル失敗の診断 | plan 生成時に検出する |

end-to-end latency の定義（ベンチの公式定義）: **「frame の PTS が media clock に現れてから、その frame の `presentedTime` まで」**。decode 前の待ち時間も含める。これにより、後段を加えたときの増分を正当に比較できる（09 §4）。

## 9. PSO・シェーダの構成

- `RenderContext` が PSO と `MTLLibrary` を所有し、`StageID + パラメータハッシュ` を key に cache する。plan 生成時にコンパイルが必要なら**非同期でコンパイルし、終わるまでその段を bypass** する（最初の 1〜2 フレームが品質低下で現れるが、stop はしない）。
- shader 名は `<stage>_<variant>` の規約（例: `deint_motionAdaptive_v1`）。variant は plan に記録する（再生成したときの比較可能性、09 §5）。
- function constants で mode を切り、PSO 数を抑える。

## 10. #5 の受け入れ基準への対応

| 受け入れ基準 | 設計上の担保 |
|---|---|
| AI 無効で安定再生 | `.off` / `.metalOnly` の plan が常に生成できる（INV-2） |
| 比率が正しく、意図しない引き伸ばしが無い | 優先順位テーブルと `AspectResolution` の単一供給源（§6） |
| インターレース素材で combs が見えない | `.motionAdaptive` を既定、detector と根拠の記録（§5） |
| GPU timing と end-to-end latency の計測 | §8。end-to-end の定義を固定 |
