# 04. デコードと音声同期（Issue #4）

対象: FFmpeg demux、VideoToolbox デコード、音声出力、同期クロック、seek。Phase 1 の中心。

## 1. モジュールの内側

```
RVDecode/
  Demuxer.swift              # FFmpeg 経由のパケット化。トラック表の生成
  VideoDecoding/
    VideoDecoder.swift       # プロトコル
    VideoToolboxDecoder.swift # HW path
    SoftwareDecoder.swift     # SW path（libavcodec）
    FramePool.swift          # CVPixelBuffer プール
  AudioDecoding/
    AudioDecoder.swift       # PCM 化（AC-3 / DTS / LPCM / AAC）
    AudioSink.swift          # AVAudioEngine 実装
    AudioClock.swift         # audio master clock
  Sync/
    SyncController.swift     # drift 判定と補正方針
    SeekController.swift     # seek の組立
  Probe.swift                # 開いた瞬間のフォーマット推定
```

C API は `CRetroffmpegShim` に閉じる（[00 §2](00-architecture.md)）。Swift 側は `AVFrame` のポインタを見ない。

## 2. Demuxer

```swift
public protocol Demuxer: Sendable {
    func probe() async throws -> ProbedStream            // トラック表・フォーマット決定
    func packets(for track: TrackID) -> AsyncThrowingStream<Packet, any Error>
    func seek(to target: MediaTime, tolerance: SeekTolerance) async throws -> SeekEffect
    var streamInfo: ProbedStream { get }
}

public struct Packet: Sendable {
    public let track: TrackID
    public let bytes: Data            // 所有権は Swift 側。FFmpeg の buffer 参照は shim 内でコピーまたは参照管理
    public let pts: MediaTime?
    public let dts: MediaTime?
    public let duration: MediaTime?
    public let flags: PacketFlags     // .key / .beginningOfFrame / …
}
```

- `Data` に載せるかどうか: FFmpeg の `AVPacket` は参照カウントを持つ。Phase 1 は**コピーして Swift 側で所有**し、寿命事故を先に潰す。コピー原価（DVD MPEG-2 では 1 パケット数百バイト）は demux 段の予算に含めて測る（04 §9）。ゼロコピーへ切り替える判断は、計測後に取る（OQ-06）。
- DVD の MPEG-PS には `dts` が無いことが多い。`pts` だけで順序を扱うため、**decode 順序は demux 順に一致しない**前提でキューを持つ。
- probe では「再生できるか」だけを返し、codec 名や profile は診断用に表示する（`DecodePathInfo`、02 §4）。

## 3. VideoToolbox デコード

方針: FFmpeg の demux + **VideoToolbox の復号**を使い、出力は `CVPixelBuffer` を直接受け取る。FFmpeg の videotoolbox hwdevice を経由する経路と、`VTDecompressionSessionCreate` を自力で扱う経路の 2 案がある。

| 案 | 長所 | 短所 | 採用 |
|---|---|---|---|
| A. FFmpeg hwdevice（`AV_HWDEVICE_TYPE_VIDEOTOOLBOX`）経由 | 実装量が少ない。interlaced MPEG-2 の処理も FFmpeg 側が面倒を見る | hwaccel の挙動がビルド設定に依存。フィールド情報が失われることがある | **Phase 1 の既定** |
| B. `VTDecompressionSession` を直接（FFmpeg は bitstream 供給のみ） | フィールド／キャデンス制御と output pool を握れる。deint の品質に直結 | 実装量が多い。MPEG-2 の field-based coding の扱い | Phase 2 で A と比較して勝敗を決める（OQ-08） |

どちらの案でも、復号出力の契約は同じにする:

```swift
public protocol VideoDecoder: Sendable {
    var path: DecodePath { get }               // .videoToolbox / .software
    var outputDescription: VideoFormatDescription { get }
    func configure(_ format: FormatDescription, policy: DecodePolicy) async throws
    func decode(_ packet: Packet) async throws -> DecodedVideoFrame?
    func flush() async -> [DecodedVideoFrame]
    func reset(at pts: MediaTime) async
}
```

- 出力 pool は `CVPixelBufferPool`（Metal 互換属性付き、01 §4）。`kCVPixelBufferIOSurfacePropertiesKey` を付け、IOSurface 経由で Metal・Core ML に**コピー 1 回で**（理想的にはゼロコピーで）渡る形を目標にする。
- HW が使えない・拒否された場合は `SoftwareDecoder` に切替え、`DecodePathInfo` にその理由を残す（#4 の「hardware decode is selected when available and software fallback works」）。切替は**再生を止めずに**行う（frame boundary で差し替え、PTS の連続性は seek なしで保つ）。
- interlaced MPEG-2 の復号で、フィールド情報が失われる場合は 05 §5 の field-match 側で復元する。復元できない場合は `.unknown` として扱い、既定の bob 相当に倒さない（誤った weave より安全な表示を選ぶ）。

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
