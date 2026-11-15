# 04. デコードと音声同期（Issue #4）

対象: demux（**ファイル source は AVFoundation ベース。EXP-001 で FFmpeg 不要を確認済み**）、VideoToolbox デコード、音声出力、同期クロック、seek。Phase 1 の中心。映像復号は MPEG-2 / H.264 は VideoToolbox。サンプル中の WMV1 は未検証（AVFoundation で開けるか未測定。開かない場合は Phase 4 の FFmpeg shim ゲートで扱う）。

## 1. モジュールの内側

```
RVDecode/
  Probe.swift                  # 開いた瞬間のフォーマット推定（測定値を JSON に落とす。make probe）
  AVFoundationDemuxer.swift    # ファイル source の demux（AVAssetReader パススルー ES）
  VideoToolboxDecoder.swift    # HW path（VTDecompressionSession）
  AudioDecoding/
    AudioDecoder.swift         # PCM 化（AC-3 / DTS / LPCM / AAC）
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

AVAudioEngine + AVAudioPlayerNode を使う（SDK に存在確認済み）。

```swift
public final class AudioSink: Sendable {
    // AVAudioEngine, AVAudioPlayerNode, AVAudioMixerNode
    func start() throws
    func schedule(buffer: AVAudioPCMBuffer, when: AVAudioTime?)   // 0.02〜0.1 s 単位で先に積む
    func flush(preserveLatency: Bool)
    var renderedFrames: AVAudioFramePosition { get }               // クロックの原料
    var outputLatency: TimeInterval { get }                        // ハードウェア出力遅延の補正に使う
}
```

- PCM quantum は 480 サンプル（10 ms @48 kHz）で生成し、10〜12 本（0.10〜0.12 s 初期値）を先に積む。render thread では allocation をしない。
- AC-3 / DTS のデコードは `AudioDecoder` 経由（FFmpeg libavcodec の SW）。DVD の LPCM は passthrough でよい。
- 出力デバイスの遅延は `outputLatency` を引いて video 側に補正する（初期値 0.01〜0.03 s を実測で置く）。
- device 変更（`AVCaptureDevice`/HAL 変更 notification）は再構成が必要。その間は `stalled` にせず、PCM を 0.2 s まで保持して繋ぐ。

## 5. 同期（audio master clock）

**音声側を権威にする**（Epic・Issue #9 の要求と一致）。

```swift
public actor AudioClock: TimeSource {
    /// renderedFrames と schedule 済 buffer の先頭 PTS から現在位置を補間する
    public func mediaTime(at host: HostTime) -> MediaTime
    public func hostTime(for media: MediaTime) -> HostTime
    public var drift: Double { get }        // 目標に対する映像の遅れ (ms)
}
```

補間の作り方: `AVAudioPlayerNode.lastRenderTime` → `playerTime(forNodeTime:)` で「再生された frame 位置」を取り、対応する PTS と結び付ける。frame 位置と PTS の対応は、schedule 時に `(bufferStartPTS, framePosition)` の table を engine 側で保持して解決する（FFmpeg 由来の PTS と PCM サンプル数の対応は decoder が保証する）。

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

**確立済みの計測ツール（Phase 1）**: `make probe`（`rvprobe --json`）が fixture ごとに開く→全サンプル復号し、`probe-*.json` を残す（decode 時間分布、PTS ゲイン p50/p90/p99/max、フレームレート解決の根拠、decode 順と提示順、bitstream / PCE の声明値、PAR）。EXP-001 の再現手順がそのまま手順化されている。留意点として **初回フレームのスパイク（44〜70 ms）**が毎セッション観測されるため、常時再生の数値を取るには warmup が必要（OQ 追記参照・未着手）。音声側（`StageID.audioDecode`・underrun・drift）は未実測。
