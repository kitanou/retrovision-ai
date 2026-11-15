# 01. 共通の値型（RVMediaCore）

対象: #2〜#9 全体。他の設計書で使う型をここで固定する。このモジュールは Foundation / CoreMedia 以外に依存しない（[00 §2](00-architecture.md)）。

## 1. 時刻

**方針**: メディア側の時刻は CoreMedia の `CMTime` をそのまま通貨として使う（VideoToolbox / FFmpeg / AVFoundation との往復コストを避ける）。ホスト側時刻は自前の `HostTime`。

```swift
public typealias MediaTime = CMTime          // 不変条件: .valid が true。negative 1 を sentinel にしない
public typealias MediaRange = CMTimeRange

/// 再生クロックの基準。audio master clock を正とする（04 §5）。
public struct PlaybackClock: Sendable, Hashable {
    public var media: MediaTime      // 現在の再生位置
    public var host: HostTime        // その位置に対応するホスト時刻
    public var rate: Double          // 1.0 = 等速
    public var driftMS: Double       // host 予想と audio 実再生の差（+ = 映像が遅れている）
}

public struct HostTime: Sendable, Hashable, Comparable {
    public var machTime: UInt64      // mach_absolute_time 基準。変換係数は MediaClock の初期化時に固定
    public static func now() -> HostTime
    public func seconds(since other: HostTime) -> Double
}

/// 計測可能な時間源。テストでは DeterministicClock を注入する（09 §3）。
public protocol TimeSource: Sendable { func now() -> HostTime }
```

不変条件:

- `MediaTime` の timescale は**ストリーム単位で固定**（MPEG-PS/TS は 90000、MP4/MOV はトラック timescale）。変換は `CMTimeConvertScale` を通し、丸めは `.roundHalfEven` を使う。
- seek の tolerance は `SeekTolerance.exact` を既定にしない（デコードコストが跳ね上がるため）。既定は `previousKeyframe + 2 s`（04 §6）。
- 時刻比較は `CMTime` の除算を避け、`CMTimeCompare` 相当の整数比較で書く。

## 2. 映像の論理記述

```swift
public struct VideoFormatDescription: Sendable, Hashable {
    public var codedSize: CMVideoDimensions          // エンコード時の像素（例 720x480）
    public var cleanAperture: CMRectCoordinate        // 表示すべき領域（crop）
    public var pixelAspect: AspectRatio               // サンプルアスペクト比（NTSC ITU-R BT.601 では 10:11 等）
    public var frameRate: FrameRate                   // 29970/1001、25/1 など有理数で保持
    public var interlace: InterlaceInfo
    public var color: ColorInfo
}

public struct FrameRate: Sendable, Hashable { public var numerator: Int32; public var denominator: Int32 }  // 30000/1001 など。double は使わない

public struct InterlaceInfo: Sendable, Hashable {
    public var fieldCount: Int16          // 0 = progressive, 2 = interlaced
    public var fieldOrder: FieldOrder     // .topFirst / .bottomFirst / .progressive / .unknown
    public var cadence: Cadence           // .progressive / .interlaced22 / .telecine32 / .mixed / .unknown
}

public enum Cadence: Sendable { case progressive, interlaced22, telecine32, mixed, unknown }
public enum FieldOrder: Sendable { case topFirst, bottomFirst, progressive, unknown }

public struct AspectRatio: Sendable, Hashable { public var w: Int32; public var h: Int32 }  // 既約化して保持

public struct ColorInfo: Sendable, Hashable {
    public var primaries: ColorPrimaries           // .bt601 / .bt709 / .smpte240 / .unspecified
    public var transfer: TransferFunction          // .bt709 / .gamma22 / .linear / .unspecified
    public var matrix: MatrixCoefficients          // .bt601 / .bt709 / .fcc / .unspecified
    public var range: YCbCrRange                   // .videoRange / .fullRange
    public var isFrequentlyUsedFlag: Bool          // 「メタデータが信用できるか」のフラグ（05 §6 で扱う）
}
```

設計判断:

- **DAR を型として保持しない**（`displayAspect` フィールドは作らない）。ソースが持つ断片（IFO の aspect flag、MPEG-2 display extension、sample aspect、clean aperture）だけを `VideoFormatDescription` に載せ、**`AspectResolver` が 1 か所で解決**して `AspectResolution` を作る。食い違うメタデータの扱いは優先順位テーブルで決める（[05 §6](05-metal-pipeline.md) にテーブルと 720/704 の注意を書いた）。
- 計算結果を UI と pipeline に同じ値で渡すため、`AspectResolution` は plan に焼き込む（INV-3）。

```swift
/// 比の解決結果。UI も pipeline もこれだけを見る（05 §6）
public struct AspectResolution: Sendable, Hashable {
    public var targetDAR: AspectRatio              // 表示すべき比率
    public var cleanAperture: CMRectCoordinate     // codedSize から実際に表示する範囲
    public var source: AspectSource                // .ifoFlag / .mpegDisplayExtension / .sampleAspect / .userOverride / .unresolved
}
```
- `frameRate` は有理数で持つ。29.97 を 29.97 の double で持つと、2 万分で ±0.03 ms の誤差が積み上がり、キャデンス判定と present 計画で誤差が表面化する。

## 3. トラックと選択

```swift
public struct TrackID: Sendable, Hashable { public var rawValue: UInt32 }   // 0 は予約（none）

public struct TrackInfo: Sendable, Hashable, Identifiable {
    public var id: TrackID
    public var kind: TrackKind        // .video / .audio / .subtitle / .data
    public var language: String?      // BCP-47 に正規化（DVD の 3 文字 code から変換）
    public var name: String?
    public var format: FormatDescription
    public var isDefault: Bool
    public var isForced: Bool
    public var associatedSubtitleTrack: TrackID?   // DVD の associated-sub-picture 制御
}

public enum TrackKind: UInt8, Sendable { case video, audio, subtitle, data }

public struct PlaybackSelection: Sendable, Hashable {
    public var item: ItemID                  // title / playlist 相当
    public var audio: TrackID?
    public var subtitle: SubtitleChoice?      // .off / .auto / .specific(TrackID)
    public var enhancement: EnhancementPolicy // [07 §6](07-enhancement.md)
}
```

## 4. フレームと資源の寿命

```swift
/// 復号後のフレーム。不変契約: 生成後に pixel buffer へ書き込まない。
public final class DecodedVideoFrame: @unchecked Sendable {
    public let id: FrameID
    public let pixelBuffer: CVPixelBuffer
    public let format: VideoFormatDescription
    public let pts: MediaTime
    public let duration: MediaTime
    public let isKey: Bool
    let lease: FrameLease            // INV-5。参照カウント。0 になるまでプールへ戻さない
}

public final class FrameHandle: @unchecked Sendable {   // 強調化・レンダリング中の中間フレーム
    public let texture: MTLTexture
    public let layout: FrameLayout   // .bgra8Unorm / .rgba16Float / .yCbCrPlanar ...
    public let size: CMVideoDimensions
    public let color: ColorInfo
    public let derivedFrom: FrameID  // 診断の因果鎖
    public let planID: PlanID        // INV-3。どの plan で作られたか
}

public struct PlanID: Sendable, Hashable { public var value: UInt64 }
public struct FrameID: Sendable, Hashable { public var value: UInt64 }
```

- `CVPixelBuffer` は **Metal 互換属性付きのプール**から取得する（`kCVPixelBufferMetalCompatibilityKey = true`、`kCVPixelBufferIOSurfacePropertiesKey = [:]`）。プール外の新規確保はフレーム毎に起きるため、フレーム予算の中で明示的に計上する。
- 中間フレーム（`FrameHandle`）は `TexturePool` が寸法・レイアウト単位で再利用する。in-flight 数が上限（3）を超えない限り再確保は発生しない設計とする。
- 寿命違反（まだ lease が残っている buffer に新しい decode が来ました）は上書きせず、診断 `FrameLeaseViolation` を出して**新しい buffer を確保する**。クラッシュや破棄待ちの待機はしない。

## 5. エラー体系

方針: メディア由来の失敗は例外でなく値で扱い、**回復方針を必ず添える**。UI は recovery を表示に使える。

```swift
public struct PlaybackError: Error, Sendable, LocalizedError {
    public let kind: Kind
    public let cause: Error?
    public let recovery: RecoveryAdvice
    public let userMessage: String        // 日本語 / 英語でそのまま出せる文字列
    public let diagnostics: DiagnosticRef // メトリクスレコードを指す（08 §4）
}

public enum RecoveryAdvice: Sendable {
    case retryWith(AlternativeStrategy)     // .softwareDecode / .lowerTier / .disableStage(StageID) / .lighterModel(ModelID)
    case needsUserAction(UserActionHint)    // .insertDisc / .selectDifferentItem / .grantPermission / .updateMedia
    case giveUp(reason: String)
}

public enum SourceErrorKind: Sendable { case notFound, unreadable, malformedStructure, unsupportedStructure, protectedNeedsLicense, mediaRemoved, permissionDenied, noDisc }
public enum DecodeErrorKind: Sendable { case unsupportedCodec, unsupportedProfile, hwDecodeUnavailable, corruptStream, bufferExhausted, formatRejected }
public enum RenderErrorKind: Sendable { case deviceUnavailable, pipelineCompileFailed, drawableLost, memoryLimit }
public enum ModelErrorKind: Sendable { case notCompiled, shapeMismatch, conversionUnsupported, deadlineExceeded, timeout, runtimeFailure, disabledByBreaker }
```

## 6. 診断 ID（INV-6）

```swift
public enum StageID: String, Sendable, CaseIterable {
    case demux, videoDecode, audioDecode
    case fieldMatch, deinterlace, inverseTelecine
    case colorConvert, scale, superResolution, denoise, sharpen
    case tensorInput, tensorOutput, mlInference
    case present
}

public struct MetricStageSample: Sendable {
    public let stage: StageID
    public let frameID: FrameID
    public let start: HostTime
    public let end: HostTime
    public let gpuDurationMS: Double?   // GPU 側は nil のことがある（CPU 計測のみの段）
    public let detail: [String: String]  // 限定された補足（compute unit、model id など）
}
```

`StageID` は `CaseIterable` とし、[08](08-adaptive-control.md) の集計と [05 §8](05-metal-pipeline.md) の GPU タイムスタンプはこの enum を例外なく処理する。新しい段を足すとき、集計側を触らなければビルドが落ちるようにする。
