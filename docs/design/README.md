# RetroVision AI 詳細設計

[開発計画](../DEVELOPMENT_PLAN.md) の Phase / Issue に対応する実装レベルの設計です。Phase 0 の足場と Phase 1 の demux/decode が動き始めており、**実測で確定した事実は [EXP-001](../experiments/EXP-001-dependency-and-videotoolbox.md) と決定ログ（[10-open-questions](10-open-questions.md)）に反映**しています。

## 前提として実測したツールチェーン（2026-11-15 実測）

| 項目 | 値 |
|---|---|
| 開発機 | Mac Studio (Mac17,14) / Apple M5 Max / 64 GB |
| macOS | 27.2.1 (Build 26B131) |
| Xcode | 27.2 (Build 27B52) |
| Swift | 6.4.2（target arm64-apple-macosx27.2.0） |
| ffmpeg | Homebrew 9.0.2（**fixture 生成と probe 用途のみ**。製品にはリンクしない。GPL-3.0 系であることも実測） |
| libdvdnav / libdvdread / libdvdcss | Homebrew 7.0.0 / 7.1.1 / 1.6.0（**未リンク**。license 実測値として inventory に記録） |
| coremltools | 未導入。システム Python は 3.9.6 のため、モデル変換には version 管理された venv が必要 |

SDK ヘッダで**存在を確認済み**の API（設計の依存先にしてよい）:
`MTLDrawable.addPresentedHandler` / `presentedTime`、`MTLCounterSampleBuffer`（`MTLCounters.h`）、`CAMetalLayer.displaySyncEnabled`、`MLModel.loadModel`（async）、`MLModelConfiguration.computeUnits`、`MLPredictionOptions.outputBackings`、`MLModelCollection`、`MPSImageScale`（`MPSImageResampling.h`）、`CVMetalTextureCacheCreate`、`VTDecompressionSessionCreate`、`AVAudioPlayerNode`。

**見つからなかった** API（設計では依存しない。使う場合は Phase 0 で検証、[#10 open-questions](10-open-questions.md) の OQ-07）:
`MTLTextureFeatureProvider` / `MTLBufferFeatureProvider`（Core ML の Metal feature provider）、`MTLModelCommandEncoder`。

### Swift から使ったときに実測した API の事実（04 の実装中に確認。繰り返し調べるコストを下げるための記録）

- CoreVideo / CoreMedia の CFString キー定数は `String(k… as NSString)` として読む。
- `CMVideoFormatDescriptionGetNominalFrameRate` は**存在しない**。フレームレートは container hint（`AVAssetTrack.nominalFrameRate`、Float）と bitstream・PTS span から解決する（04 §2）。
- `AVAssetReader.canAdd(_:)` は add しない。追加は `reader.add(output)`。
- `track.formatDescriptions` / `track.nominalFrameRate` は非同期 form（`track.load(.formatDescriptions)`）で読む。
- トラックの language・表示名は `AVMediaSelectionOption` 側にしかない。
- output-handler 版の VT 呼び出しは `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)` として import される。
- `kVTDecodeInfo_FrameDropped` は import されない（`flags.rawValue & (1 << 1)` で見る）。
- async context で NSLock は使えない（serial DispatchQueue で直列化する）。
- エラー値の実測意味: `-12902` = kVTParameterErr（0 長 sample 投入）、`-8969` = H.264 4:2:2 の bad data（この機械）。
- 新規ビルドの **unsigned SPM debug binary は SIGKILL（exit 137）で殺される**ことがある → `codesign --force --sign -`（OQ-24）。再ビルド每次に再署名。

## 文書と読み順

| 文書 | 内容 | 対応 Issue |
|---|---|---|
| [00-architecture.md](00-architecture.md) | モジュール分割、依存ルール、スレッドモデル、データフロー、グローバル不変条件 | Phase 0 |
| [01-core-types.md](01-core-types.md) | 共通の値型（時間・フレーム記述・比・エラー体系）と診断 ID | #2〜#9 共通 |
| [02-player-engine.md](02-player-engine.md) | 再生エンジン API、状態機械、UI との境界 | #2 |
| [03-media-sources.md](03-media-sources.md) | DVD ソース抽象、光学ドライブ / VIDEO_TS / ISO、libdvdnav 統合 | #3 |
| [04-decode-av-sync.md](04-decode-av-sync.md) | AVFoundation demux + VideoToolbox デコード、音声出力、同期制御 | #4 |
| [05-metal-pipeline.md](05-metal-pipeline.md) | Metal レンダーグラフ、デインターレース、比・色、提示と計測 | #5 |
| [06-ml-runtime.md](06-ml-runtime.md) | Core ML 実行層、モデル契約、ゼロコピー、障害分離 | #6 |
| [07-enhancement.md](07-enhancement.md) | 超解像・ノイズ除去のステージ設計と順序設定 | #7、#8 |
| [08-adaptive-control.md](08-adaptive-control.md) | 適応品質制御、メトリクス、ベンチマーク出力形式 | #9 |
| [09-testing.md](09-testing.md) | テスト戦略、フィクスチャ、CI、性能ゲート | Phase 0〜5 |
| [10-open-questions.md](10-open-questions.md) | 未決事項の意思決定ログ（実験・判断ゲート・既定値） | 全体 |

## 設計の追跡マトリクス

| Issue | 主設計書 | 関連する不変条件 | ゲート |
|---|---|---|---|
| #2 | 02 | INV-8 | G1 |
| #3 | 03 | INV-7 | G2 |
| #4 | 04 | INV-1、INV-4、INV-6 | G1 |
| #5 | 05 | INV-2、INV-3、INV-5、INV-6 | G2 |
| #6 | 06 | INV-1、INV-2、INV-6 | G3 |
| #7 | 07（SR）＋ 06 | INV-1、INV-2 | G3 |
| #8 | 07（denoise）＋ 05 | INV-2、INV-3 | — |
| #9 | 08 | INV-1、INV-6 | — |

## 現在の実装状況（Phase 0 完了 + Phase 1 の demux/decode、2026-11-16）

| 場所 | 状態 |
|---|---|
| `Packages/RetroVisionKit` | SPM パッケージ（`RVMediaCore` / `RVDiagnostics` / `RVMediaSources` / `RVDecode` / `RVDecodeProbe` / `RVVideoPipeline` / `RVMLRuntime` / `RVEnhancement` / `RVPlaybackEngine`） |
| 時刻・フレームレート（01 §1） | 実装済み（有理数の `FrameRate`、half-even 整数演算、`MediaMath`、PTS span 推定） |
| 比の解決（01 §2、05 §6） | 実装済み（目標 DAR 優先 + clean aperture 逆算。704/720 の注意をテストで固定） |
| **MPEG-2 bitstream 解析（04 §2）** | 実装済み（sequence / picture / **picture-coding 拡張（PCE）**。ffprobe と byte-for-byte で突合。`BitstreamTests` に fixture 実バイトの回帰固定） |
| **demux + VideoToolbox 復号（04 §2・§3）** | 実装済み（AVFoundation ES パススルー、zero-sample ゲート、hint 供給、PCE field 順序、提示順の遅延組み替え）。統合テスト 6 本で回帰固定 |
| **フォーマット probe（04 §2・09）** | 実装済み（`make probe` → `probe-*.json`、`make probe-play` → EngineCore 経由の実時間再生測定 `play-*.json`。nightly CI が収集） |
| 表示スケジュール（05 §5.3） | 実装済み（vsync 整数本の計画、59.94/60/50/24fps のパターンをテストで固定） |
| 計測とレポート（08 §7） | 実装済み（窓集計の `MetricBus`、JSONL、`BenchmarkReport` の null 保持） |
| 適応制御（08 §4、§5） | 実装済み（`AdaptivePolicyEngine` の降格順序・hysteresis） |
| **再生線（EngineCore ↔ demux/decode、#11 前半）** | 実装済み（`PlaybackSession` + `FileMediaSource`。映像のみ: play/pause/resume・PTS 順の提示・位置イベント・`PlaybackOutcome` 計測）。実測: 180 素材で 180/180 提示、realTimeFactor 0.9998、late 0、提示間隔 p50 33.25 ms（目標 33.37）。統合テスト 4 本で回帰固定 |
| `EngineCore`（02） | 状態機械・設定適用・plan 生成＋上記の再生線接続まで実装（seek は場当たり的な再構築のみ＝#13、音声線は #10） |
| 未実装（03、05、06、07、音声実装） | 契約と plan のみ（音声は復号経路の実験まで完了＝EXP-002。AudioDecoder/AudioSink/clock 実装は #10、SW 復号は OQ-20 のゲート待ち） |
| 素材 | `fixtures/manifest.json` 18 登録（**11 を generated として Git 同梱**、実素材 7 は `pending`＝OQ-16）。`make gen-fixtures` で再生成 |
| ライセンス | `licenses/inventory.json`（Homebrew 版の実測 license・未リンクを区別。`make check-licenses` で検査） |
| CI | `.github/workflows/ci.yml`（build / unit / integration / licenses / fixtures + nightly の probe 収集） |

確認手順:

```sh
make check          # build + test + license 検査 + fixture 検査
make gen-fixtures   # 合成 fixture 生成（既存ファイルはスキップ）
make probe          # 全素材の open→全復号を計測し bench/captures/probe-*.json に記録
make probe-play     # 全素材を EngineCore 経由で実時間再生し bench/captures/play-*.json に記録
```

注: `Package.swift` のプラットフォーム下限は macOS 15（CI 互換のための暫定値）。製品の下限は OQ-12 で未決のまま。

## 文書規約

- Swift コードブロックは**設計例**であり、そのままコンパイルを保証するものではない。ただし公開 API の名前は実装時にそのまま使う前提で固定する。
- 「TBD」は書かない。未決はすべて [10-open-questions.md](10-open-questions.md) に OQ-番号で書き、本文では**当面の既定値**を書く。
- 数値（フレーム予算、キュー長、閾値）はすべて Phase 0〜3 の実測で置き換える前提の初期値であり、出典は該当節に「初期値」と明記する。
