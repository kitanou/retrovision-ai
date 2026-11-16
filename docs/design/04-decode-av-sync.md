# 04. デコードと音声同期（Issue #4）

対象: demux（**ファイル source は AVFoundation ベース。EXP-001 で FFmpeg 不要を確認済み**）、VideoToolbox デコード、音声出力、同期クロック、seek。Phase 1 の中心。映像復号は MPEG-2 / H.264 は VideoToolbox。サンプル中の WMV1 は未検証（AVFoundation で開けるか未測定。開かない場合は Phase 4 の FFmpeg shim ゲートで扱う）。

## 1. モジュールの内側

```
RVDecode/
  Probe.swift                  # 開いた瞬間のフォーマット推定（測定値を JSON に落とす。make probe）
  AVFoundationDemuxer.swift    # ファイル source の demux（AVAssetReader パススルー ES）
  VideoToolboxDecoder.swift    # HW path（VTDecompressionSession）
  AudioDecoding/
    AudioDecoder.swift         # PCM 化（AC-3 は AVFoundation の PCM 変換出力。LPCM passthrough。DTS は Phase 4 shim ゲートまで非対応＝EXP-002 A6）
    AudioSink.swift            # AVAudioEngine 実装
    AudioClock.swift           # audio master clock
  Sync/
    SyncController.swift       # drift 判定と補正方針
    SeekController.swift       # seek の組立
RVMediaCore/
  CoreMediaBridging.swift      # CMSampleBuffer / CMFormatDescription / CVPixelBuffer の橋渡し＋CoreMedia 固有の初期化規則
  MPEG2Bitstream.swift         # sequence / picture / picture-coding 拡張の解析（C API 不使用）
```

C API を呼ぶ箇所は上記の橋渡しモジュールに閉じる（[00 §2](00-architecture.md)。`RVMediaCore` の纯値型は不変）。当初計画した `CRetroffmpegShim` は Phase 1 では未作成（OQ-01 の決定ログ参照）。`AVFrame` のポインタはどのモジュールも見ない。

## 2. Demuxer

```swift
public protocol Demuxer: Sendable {
    func probe() async throws -> ProbedStream
    func samples(for track: TrackID) -> AsyncThrowingStream<CompressedSample, any Error>
    func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect
    var streamInfo: ProbedStream { get }
}

public struct CompressedSample: @unchecked Sendable {
    public let track: TrackID
    public let sampleBuffer: CMSampleBuffer   // ES サンプルのパススルー。生存中は base buffer が ES を保持する
    public var pts: MediaTime? { get }
    public var duration: MediaTime? { get }
    public var isKeySample: Bool { get }
    public var hasSampleData: Bool { get }   // 空サンプルの判別（下記）
}
```

- **所有権（OQ-06）**: `CMSampleBuffer` の参照をそのまま渡す。ES コピーは demux 段で発生しない。パケットを `Data` にコピーする設計は不要であることが**実測で確認できた**（[EXP-001](../experiments/EXP-001-dependency-and-videotoolbox.md) F2。デコードへ渡す直前まで参照を遅延させる）。
- **空サンプルの扱い**: AVFoundation はトラック先頭にサンプルデータゼロのバグッファを出す。VideoToolbox はこれを `-12902`（kVTParameterErr）で弾く（F5）。`hasSampleData == false` のサンプルはスキップし、**PTS 補完にも使わない**（ダミー PTS が復号順序を狂わせる）。
- MPEG-PS の ES サンプルは `dts` を運ばない（F2）。**decode 順序は PTS 順に一致しない**ため、PTS 全集の推定は「ソート済みユニーク PTS ÷ 総フレーム数」で行う（F6。demux 順＝decode 順で平均间隔を取ると GOP 並べ替えで約 4 倍ずれる）。
- probe は `ProbedStream` を返す。フォーマット決定は [01 §2](01-core-types.md) の resolver と同じ規則（フレームレート解決鎖: container hint → MPEG-2 bitstream → PTS span。既知標準に一致しない hint は使わない。**NTSC既定に倒さない**）。bitstream と PCE、PTS ゲイン（p50/p90/p99/max）を `probe-report` に記録する。

## 3. VideoToolbox デコード

方針: **`VTDecompressionSession` を直接使う**（下表の案 B）。案 A（FFmpeg hwdevice 経由）は比較対象ですらなくなった — demux 自体が AVFoundation になったため、FFmpeg を経由する理由が消えた（[EXP-001](../experiments/EXP-001-dependency-and-videotoolbox.md) F1、OQ-01/OQ-08 の決定ログ）。

| 案 | 長所 | 短所 | 結果 |
|---|---|---|---|
| A. FFmpeg hwdevice（`AV_HWDEVICE_TYPE_VIDEOTOOLBOX`）経由 | 実装量が少ない。interlaced MPEG-2 の処理も FFmpeg 側が面倒を見る | hwaccel の挙動がビルド設定に依存。フィールド情報が失われることがある | **不採用**（FFmpeg 非依存で全 fixture が通った） |
| B. `VTDecompressionSession` を直接（ES サンプルをそのまま供給） | フィールド／キャデンス制御と出力プールを握れる。コピーなしで IOSurface を取得できる | 実装量が多い | **採用**（Phase 1 実装済み。スループット 176〜1555 fps、p50 0.4〜1.7 ms を実測） |

復号器の契約（実装済み。`RVDecode/Contracts.swift`）:

```swift
public protocol VideoDecoder: Sendable {
    var path: DecodePath { get async }
    var pathInfo: DecodePathInfo { get async }            // 選択理由の診断（02 §4）
    var sourceFormat: VideoFormatDescription? { get async }
    var decodedFormat: VideoFormatDescription? { get async }
    func configure(_ format: VideoFormatDescription, policy: DecodePolicy,
                   formatDescriptionHint: CMVideoFormatDescription?) async throws
    func decode(_ sample: CompressedSample) async throws -> DecodedVideoFrame?
    func flush() async -> [DecodedVideoFrame]
    func reset(at pts: MediaTime) async
}
```

- **format description hint**: AVFoundation は sample 自身に description を添えないことがある（MPEG-PS で実測）。probe 段の track description を hint として復号器に渡す（`FormatDescriptionHolder` の実測注記）。
- **出力順序（F13・実測で確定）**: 同期的な `VTDecompressionSession` の出力ハンドラは**入力順（＝decode 順）でフレームを返す**。提示順は PTS 順であるため、`decode` は内部で受理済みフレームが 2 件以上になるまで 1 件を保持し（1 サンプル分遅延させて PTS 順に組み替え）、提示可能な次の 1 件だけを返す。`flush` で残りを PTS 順に返す。順序保証を decoder の責務として固定したので、上層は「受理順＝提示順」を前提にできる。統合テストで回帰固定済み（`DecodePathTests.framePresentationOrderIsPresentationOrderByPTS`）。
- **field 順序の供給元（F10）**: MPEG-PS の container は `CVFieldCount`（本数）しか運ばず、順序は **PCE の `top_field_first`** から取る（全 fixture で tff=0 = bottom-first を実測）。H.264 の interlaced fixture は復号段階で field 信号が**全て消える**（F11。MP4 mux の MPEG-2 では `CVFieldDetail` が残るが未読了）。順序の最終確定は 05 §5 の detector 経路に依存する。復元できない場合は `.unknown` として扱い、既定の bob 相当に倒さない（誤った weave より安全な表示を選ぶ）。
- 復号 pix_fmt は `420v`（映像 range・ITU-R BT.601）でメタデータと一致し、キャリアは container の声明値を保持する（F9）。ただし `Guesses` フラグの立つ component range があるため、色キャリアの優先読みは component range 側。

- 出力 pool は `CVPixelBufferPool`（Metal 互換属性付き、01 §4）。`kCVPixelBufferIOSurfacePropertiesKey` を付け、IOSurface 経由で Metal・Core ML に**コピー 1 回で**（理想的にはゼロコピーで）渡る形を目標にする。
- HW が使えない・拒否された場合は `SoftwareDecoder` に切替え、`DecodePathInfo` にその理由を残す（#4 の「hardware decode is selected when available and software fallback works」。SW 復号器本体は Phase 1 の後続作業）。切替は**再生を止めずに**行う（frame boundary で差し替え、PTS の連続性は seek なしで保つ）。

## 4. 音声出力

AVAudioEngine + AVAudioPlayerNode を使う（SDK に存在確認済み）。**実装済み（#10）**。
契約は `Contracts.swift` のとおり（実測で確定した形に同期している）:

```swift
public protocol AudioDecoderProtocol: Sendable {
    var pathInfo: DecodePathInfo { get async }
    var outputFormat: AudioFormatDescription? { get async }   // 最初の chunk から実仕様を確定
    func configure(_ format: AudioFormatDescription, policy: DecodePolicy) async throws
    func pcm(for track: TrackID) async -> AsyncThrowingStream<AudioPCM, any Error>  // 480 帧 quantum
}
public protocol AudioSink: Sendable {   // actor ではなく class+lock（同期要件のため）
    func start() throws; func stop(); func pause(); func resume(); func flush()
    func schedule(_ pcm: AudioPCM) throws        // 内部に (framePosition, PTS) 対応表を持つ
    func scheduledAheadMS() -> Double            // underrun 検出と prefill 制御の材料
    func renderedFramePosition() -> Int64
    func renderedPTS() -> MediaTime?             // 対応表 + 出力遅延補正で解決
    var outputLatencyMS: Double { get }
    var outputFormat: AudioFormatDescription? { get }
}
```

- PCM quantum は 480 サンプル（10 ms @48 kHz）で生成し、10〜12 本（0.10〜0.12 s 初期値）を先に積む。render thread では allocation をしない。**AVFoundation の変換出力は 8192 帧（≈171 ms）に結合されて返る（EXP-002 A2）ので、この quantum への分割は AudioDecoder 実装側の責任**。実装: `AVFoundationAudioDecoder.quanta(of:)`（480 帧へ切り、各 quantum を自有 memory へのコピーとして独立 block にする。テスト `AudioPathTests` で「全 quantum ≤480 帧・max=480・帧数と PTS 進みの一致」を固定）。
- **AC-3 復号は AVFoundation の linear PCM 出力で行う（OQ-19 決定・EXP-002 A1。依存ゼロ）**。 AudioDecoder は passthrough の ES サンプルではなく、PCM 変換 outputSettings を使った track output を読む形になる（`PCMSampleSource.pcmSamples(for:target:)` — 目標仕様は Sendable 値型 `PCMTargetSettings`。dict は actor 境界の内側で組む）。DVD の LPCM は passthrough でよい。**passthrough 経路を使う場合、ES は ~1.5 s 単位で結合され末尾サンプルの PTS が invalid（A3）**。クロックは PCM 経路の valid PTS + 帧数から進め、passthrough の PTS だけを信用しない。**DTS はトラックとして存在しなくなる（EXP-002 A6 実測: AVFoundation は MPEG-PS 内の DTS を列挙しない、警告も出ない。AudioPathTests で回帰固定）**。DVD-Video 仕様で音声必須は LPCM/AC-3 で DTS は拡張。当面の既定は **Phase 4 の FFmpeg shim ゲートまで DTS 非対応**（受け入れ検査には `ntsc480i-dts-01.mpg` を使う。DTS 素材は音声なしで完走する）。
- 出力デバイス側の遅延: `AVAudioNode.outputPresentationLatency`（秒。node から装置到達までの pipeline。**本 SDK に `outputLatency` は無い**）を読み、`renderedFramePosition()` から引いた位置を「いま装置から出ている音」として `renderedPTS()` が解決する。値の当否は §9 の drift 実測で検証（04 §5）。
- 出力装置が存在しない環境（CI の一部）では `engine.start()` が throw する。**sink start 失敗は「音声なしの暫定 pacing へ縮退」**（PlaybackSession が `audioStatus="failed:…"` にして映像再生は継続。INV-2 と同じ縮退の原則）。
- 出力デバイス・sample rate の実行時変更は Phase 2 の再生再構成（reconfigure）で扱う。PCM 保持 0.2 s は reconfigure 実装時の仕様として 02 §6 に残す。

## 5. 同期（audio master clock）

**音声側を権威にする**（Epic・Issue #9 の要求と一致）。**実装済み（#10。`AudioClock`）**。

```swift
// actor ではなく class+NSLock（TimeSource.now() が nonisolated 同期要件のため。
// DeterministicTimeSource と同じ理由）。
public final class AudioClock: MediaClock {
    @discardableResult public func sample() -> Bool   // sink の rendered PTS をクロックに採る
    public func mediaTime(at host: HostTime) -> MediaTime
    public func hostTime(for media: MediaTime) -> HostTime   // 映像の提示締切（逆引き）
    public var currentDriftMS: Double { get async }
}
```

補間の作り方: `AVAudioPlayerNode.lastRenderTime` → `playerTime(forNodeTime:)` で「再生された frame 位置」を取り、対応する PTS と結び付ける。frame 位置と PTS の対応は、schedule 時に `(bufferStartPTS, framePosition)` の table を **AudioSink 内部**で保持して解決する（実装: `AVFoundationAudioSink.table`。frame↔PCM 帧数の対応は decoder が保証する — `AudioPathTests` で「帧数と PTS 進みが一致」を固定）。権威サンプルの間は壁時計から等倍で補間し、次の sample（数 ms 間隔で再生駆動と同じ tick）で更新するため、rate のずれは補間窓（数 ms）に閉じ込められる。

**再生線での使い方（#10 実装）**: `PlaybackSession` は音声 prefill（既定 120 ms）後に sink を start し、毎呼吸で clock を sample する。映像の提示締切は `clock.hostTime(for: frame.pts)`（clock が立っていない間は #11 の暫定基点）。drift（+ = 映像が遅い）は提示時に 100 ms 間隔で採り `PlaybackOutcome.clockDriftMS` に残す。underrun（積み残枯渇）は `audioUnderrunEpisodes / TotalMS`。**drift・underrun の実測は §9**。
注: 提示時刻の補正段階（下表の 8 ms 超の行動 = SyncController）は Phase 2 の #5/#6。Phase 1 は「測って残す」までで、映像は締切どおりにだけ提示する。drift が 8〜40 ms に乗っても補正しないぶん、そのまま `late`（既定 2 ms 閾値）に現れる点は §9 の注記参照。

`SyncController` の判定と方針（初期値。Phase 1 で実測により更新）:

| 条件 | 行動 |
|---|---|
| \|drift\| ≤ 8 ms | 補正しない（デッドバンド） |
| 8 ms < \|drift\| ≤ 40 ms | 映像側のみ補正（present 時刻を早める／遅らせる。フレーム間隔を変えない） |
| 40 ms < \|drift\| ≤ 80 ms | 映像 1 フレームの drop または repeat、および present 時刻の前倒し |
| \|drift\| > 80 ms | 映像を audio 位置へ合わせにいく（drop 連続）+ audio の time pitch で ±0.2% まで寄せる |
| \|drift\| > 250 ms | 音声の flush + seek（`stalled(.demuxStarved)` の扱いで供給を待つ） |

- 映像補正でフレーム間隔をいじらない理由: 間隔を変えるとキャデンスが崩れ、deint の判定と表示の均等性に影響する（05 §5）。
- 音声の pitch 補正は、あえて聞こえるように効かせる選択。基本は映像側で吸収し、音声は 0.2% を超えない。
- 映像が間に合わない場合、AI の完了を**待たずに**未強調のまま出す（INV-1、08 §2）。

## 6. seek の設計

```swift
public enum SeekTolerance: Sendable { case exact, previousKeyframe, near(MediaTime) }
```

手順（`SeekController`）:

1. audio clock を一時停止（rendered frames の追補をやめる）
2. demuxer に `seek(target, tolerance: .previousKeyframe)` — 音声は target より 0.2 s 前から、映像は target 直前の keyframe から（#4 の受け入れ基準「A/V sync stable during seeking」のため、映像はデコードして捨てながら進む）
3. 音声 PCM 0.2 s 分をデコードし、無音ではなく実音で開始する（先頭 10 ms に fade-in を付け、click を避ける）
4. 映像は keyframe から target までの frame をデコードして**表示しない**（discard。decode 負荷は計上する）
5. 初回の present が完了した時点で clock を再開し、phase を playing に戻す

`seek` 中の UI は `phase = .seeking` で transport を無効化し、プログレスは目標位置を表示する（実際には 0.2〜1.5 s 掛かるため、完了まで待つと書く）。

`step(_:)`（1 フレーム送り）は seek を使わず、デコードを 1 フレーム進めて present する専用経路にする。seek を使うと音声の扱いが不定になるため、paused 時のみ許可し音声はミュートしたまま。

## 7. 字幕

Phase 2〜3 では **ビットマップ字幕（DVD SPU）**と**テキスト字幕（SubRip / WebVTT / ASS）**を別の通路にする。

| 種別 | 処理 | 表示 |
|---|---|---|
| DVD SPU（8 色 + transparency） | 自力で RLE 復号（FFmpeg `dvd_subtitle` decoder も可） | Metal で別 texture として composite。**AI 段の後**に合成する（字幕を超解像にかけない。07 §4） |
| SSA/ASS | 自力レンダリングはしない。Phase 3 以降で評価 | 同上 |
| SRT / VTT | 文字列を保持し、UI レイヤーではなく pipeline に載せる | 字幕の縁・位置を保持する |

設計上の要点: 字幕は 05 §4 の `RenderGraph` の最後の合成段として扱う。字幕を強調化の前に置くと、字幕の輪郭が AI に歪められる。字幕を最後に置くことで、字幕の可読性は AI の挙動から独立する。

## 8. 防御的な制限（クラッシュを生まないための境界）

| 項目 | 上限（初期値） | 超過時 |
|---|---|---|
| 映像の最大寸法 | 4096×2160 | `.formatRejected`。UI は「解像度が大きすぎます」 |
| 単一パケットの最大長 | 8 MB | `corruptStream` |
| デコード待ちキュー | 64 packet | demux 停止（00 §5） |
| track 数 | video 16 / audio 16 / subtitle 32 | 上位のものから採用し、`structure.warnings` に記録 |
| probe に掛ける時間 | 2 s | `.malformedStructure` 相当。開かない |

## 9. 計測点（#4 の受入基準「latency, dropped frames, decoder selection are measurable」）

| 測るもの | 方法 | 記録 |
|---|---|---|
| decode 時間 | packet 投入から `DecodedVideoFrame` 生成までの wall time | `StageID.videoDecode` |
| demux 時間・パケット生成速率 | `StageID.demux` | 08 §4 |
| HW/SW の選択と選択理由 | `DecodePathInfo` を engine が保持 | 02 §4 `PlayerStateSnapshot` |
| dropped frames | present されなかった frame を理由付きで計上（late / skippedByPolicy / leaseViolation） | 08 §3 |
| A/V drift | 0.1 s 間隔で drift を記録、p50/p95/max を集計 | 08 §4 |
| 音声の underrun | schedule 済み buffer の残数 | 08 §3 |

**確立済みの計測ツール（Phase 1）**:
1. `make probe`（`rvprobe --json`）: fixture ごとに open→全サンプル復号。`probe-*.json`（decode 時間分布、PTS ゲイン、フレームレート解決の根拠、decode 順と提示順、bitstream / PCE 声明、PAR、音声実験）。
2. `make probe-play`（`rvprobe --json --play`）: **EngineCore を通した実時間再生**。`play-*.json` に提示間隔・late・起動遅延・realTimeFactor・decode stage 分布を残す（#11 の G1 前半資料。nightly CI が両方収集）。

**in-loop 実測（2026-11-16、映像のみ・11 素材）**:

| 素材 | 提示 | late | realTimeFactor | 提示間隔 p50 | 備考 |
|---|---|---|---|---|---|
| ntsc480i-22-01.mpg | 180/180 | 0 | 0.9998 | 33.36 ms | 目標 33.37 ms に一致。初帧 61 ms（OQ-18） |
| pal576i-22-01.mpg | 150/150 | 0 | 0.9998 | 40.00 ms | 25 fps 一致 |
| film24p-01.mpg | 144/144 | 0 | 0.9997 | 41.66 ms | 24 fps 一致 |
| ntsc480i-h264-01.mp4 | 180/180 | **22** | 0.9998 | 33.36 ms | **H.264 interlaced の復号 p50 5.7 ms が同期復号の待ち時間で閾値 2 ms を超える**（後述） |
| progressive-sd-mp4-01.mp4 | 180/180 | **29** | 0.9998 | 33.34 ms | 同上の構造（復号自体は p50 1.6〜1.9 ms。間隔の 67 ms はスタールの巻き取り残跡。両素材の pts に穴は無いことを ffprobe で確認済み） |
| 他 6 素材 | 全提示 | 0 | ≥0.997 | 目標一致 | truncated 系は切り詰め境界に実際の PTS 穴（100 ms 級）があり、そのまま提示間隔に出る（素材側の事実。決定的テストでは「間隔=pts 間隔±2 ms」で検査） |

- **late の含义**: 当経路は「遅れても提示し late に数える」設計（02 §1・04 §3）。realTimeFactor ≈1 なので**スループット不足ではない**。H.264 の late は、`topUpDecode` が同一呼吸内で同期復号（1 件 2〜7 ms）を済らせてから `presentDue` を呼ぶ構造の取り分（復号が提示パスを阻塞する）。**修复は Phase 2 の #5（Metal 提示と PresentSchedule で復号と提示時刻を分離）**。数値だけ見ると誤誘導なので、表ごと残す。
- **復号原価の素材差（映像段の実測）**：MPEG-2 p50 2.6 ms / H.264 progressive p50 1.6〜1.9 ms / **H.264 interlaced p50 5.7〜5.8 ms（field-pair 復号で progressive の約 3 倍）**。フレーム予算（04 §1 の videoDecode 3 ms）は MPEG-2 で満たすが H.264 interlaced を DVD 相当で扱う場合は超過。→ 設計反映は 05 §1 と Phase 2 で（regen 素材に interlaced H.264 の比率を持たせない判断もありうる）。
- 比率の宣言が無い素材（H.264 mp4 等）は `load` が `needsUserAction(.chooseAspect)` を返す（01 §2 の resolver は設計どおり、推測で 4:3 に倒さない）。`probe-play` は headless のため明示 4:3 を適用した事実を `aspectPolicyApplied` に記録する。
**in-loop 音声実測（2026-11-16、#10。`make probe-play` の `audioStatus/clockDriftMS/audioUnderrunEpisodes`）**

| 素材 | 音声 | 提示 | late | realTimeFactor | 提示間隔 p50 | drift p50 / p95 | underrun |
|---|---|---|---|---|---|---|---|
| ntsc480i-ac3-01.mpg | running（48k/2ch/lpcm16） | 180/180 | **144** | 1.0025 | 32.90 ms | **+6.9 / +10.6 ms** | 0 回 |
| 他 10 素材 | none（音声トラックなし / DTS＝列挙されず） | 全提示 | 0〜29 | ≥0.997 | 目標一致 | — | 0 回 |

- **drift は audio master clock の実測として目標帯域内**（04 §5 のデッドバンド 8 ms に対し p50 +6.9 ms、補正段階 8〜40 ms の下限帯に p95 +10.6 ms で収まる）。補正行動（present 時刻の寄せ）は Phase 2 の SyncController で、ここで作った `clockDriftMS` を原料に使う。
- **underrun 0**（prefill 120 ms + 稼働中 150 ms 維持の供給。AC-3→PCM 変換の realtimeFactor ≈1100 が効いている）。
- **late=144 の含义**（数値だけ見ると誤誘導なので表ごと残す）: 音声 clock が立つと提示締切は `clock.hostTime(for: pts)` になる。当経路は (a) 同一呼吸内で同期復号（MPEG-2 p50 2.6 ms）を済らせてから提示判定する、(b) 締切を 2 ms 超えて遅れたら late に数える、(c) 補正しない——ので、**drift がデッドバンド（8 ms）内に収まっていても late に大量計上される**。H.264 の 22/29 と同じ「復号が提示パスを阻塞する」構造に、clock の锚（rendered 位置は I/O quantum 単位で進む）の量子化が重なる。**修复は Phase 2 の #5/#6（PresentSchedule で復号と提示時刻を分離し、8 ms 超の drift だけを補正する）**。音声 clock 下での `late` は「閾値 2 ms に対する超過」の測定であって知覚の破綻ではない（drift 側が破綻していない）。
- 単体契約（`AudioPathTests`）: AC-3→PCM の全 quantum ≤480 帧（max=480 で分割の証拠）/ 帧数と PTS 進みの一致 / 実仕様の初 chunk 確定。AudioClock の frame↔PTS↔host 対応と補間の非累積。DTS がトラックとして現れないこと（A6 の回帰）。e2e（`AudioPlaybackTests`）: 構造的検査（完走・全 180 帧提示・drift 采样の存在・underrun < 5）は常に実行。**drift の数値検査（p95 < 40 ms）は実時間ペーシングを持つ装置のときだけ**実行する（次の項のゲート）。device 無し環境は `audioStatus=failed:…` への縮退を検査（映像線は壊れない）。
- **CI ランナーの音声装置は「実時間ペーシングを持たない仮想装置」で走ることがある（2026-11-16 の CI 実測で判明・同一コードで drift p95 40.25→91.67 ms と揺れた）**: エンジンは start するが rendered frame 位置が実時間より約 1.09〜1.5 倍速で無料実行する。audio master clock の前提「音声の時間軸 ≈ 実時間」は装置の実時間ペーシング依存なので、CI の drift・提示間隔は設計分布ではなく装置の産物になる（CI: drift p95 +91.7 ms・提示間隔 p50 30.4 ms——clock に忠実に追随した結果。実機の +10.6 ms とは別物）。**判定の作り方（環境の自己申告にしない）**: e2e は独立の AVAudioEngine で 1 s 窓×3 の rendered 進みを測り、**定常窓の実時間比 0.98〜1.03 の装置だけ**数値検査を走る（実機の実測: 起動直後の窓は 0.252 = 装置の起動ユルミ、定常窓 1.00〜1.013。CI 仮想装置は ≥1.09 で除外。ゲートの事実は print して残す）。CI の `play-*.json` 音声欄は「線が動く・破綻しない」の回帰資料として読む。
- 留意: sink の start 失敗・drain 不発に対する安全弁（`audioDrainTimeoutMS` 既定 2 s で打ち切り、errors に記録）。
- 留意点として **初回フレームのスパイク（44〜70 ms）**が毎セッション観測される（warmup 設計は OQ-18 / issue #12）。
