# RetroVision AI 詳細設計

[開発計画](../DEVELOPMENT_PLAN.md) の Phase / Issue に対応する実装レベルの設計です。コードはまだ存在せず、本書が最初の設計成果物になります。

## 前提として実測したツールチェーン（2026-11-15 実測）

| 項目 | 値 |
|---|---|
| 開発機 | Mac Studio (Mac17,14) / Apple M5 Max / 64 GB |
| macOS | 27.2.1 (Build 26B131) |
| Xcode | 27.2 (Build 27B52) |
| Swift | 6.4.2（target arm64-apple-macosx27.2.0） |
| ffmpeg / libdvdnav / libdvdread | 未導入（pkg-config に見つからない） |
| coremltools | 未導入。システム Python は 3.9.6 のため、モデル変換には version 管理された venv が必要 |

SDK ヘッダで**存在を確認済み**の API（設計の依存先にしてよい）:
`MTLDrawable.addPresentedHandler` / `presentedTime`、`MTLCounterSampleBuffer`（`MTLCounters.h`）、`CAMetalLayer.displaySyncEnabled`、`MLModel.loadModel`（async）、`MLModelConfiguration.computeUnits`、`MLPredictionOptions.outputBackings`、`MLModelCollection`、`MPSImageScale`（`MPSImageResampling.h`）、`CVMetalTextureCacheCreate`、`VTDecompressionSessionCreate`、`AVAudioPlayerNode`。

**見つからなかった** API（設計では依存しない。使う場合は Phase 0 で検証、[#10 open-questions](10-open-questions.md) の OQ-07）:
`MTLTextureFeatureProvider` / `MTLBufferFeatureProvider`（Core ML の Metal feature provider）、`MTLModelCommandEncoder`。

## 文書と読み順

| 文書 | 内容 | 対応 Issue |
|---|---|---|
| [00-architecture.md](00-architecture.md) | モジュール分割、依存ルール、スレッドモデル、データフロー、グローバル不変条件 | Phase 0 |
| [01-core-types.md](01-core-types.md) | 共通の値型（時間・フレーム記述・比・エラー体系）と診断 ID | #2〜#9 共通 |
| [02-player-engine.md](02-player-engine.md) | 再生エンジン API、状態機械、UI との境界 | #2 |
| [03-media-sources.md](03-media-sources.md) | DVD ソース抽象、光学ドライブ / VIDEO_TS / ISO、libdvdnav 統合 | #3 |
| [04-decode-av-sync.md](04-decode-av-sync.md) | FFmpeg / VideoToolbox デコード、音声出力、同期制御 | #4 |
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

## 現在の実装状況（Phase 0 の足場）

コードが動き始めました。設計どおりの境界で進むため、まず純粋ロジックから実装しています。

| 場所 | 状態 |
|---|---|
| `Packages/RetroVisionKit` | SPM パッケージ（`RVMediaCore` / `RVDiagnostics` / `RVMediaSources` / `RVDecode` / `RVVideoPipeline` / `RVMLRuntime` / `RVEnhancement` / `RVPlaybackEngine`） |
| 時刻・フレームレート（01 §1） | 実装済み（有理数の `FrameRate`、half-even 整数演算、`MediaMath`） |
| 比の解決（01 §2、05 §6） | 実装済み（目標 DAR 優先 + clean aperture 逆算。704/720 の注意をテストで固定） |
| 表示スケジュール（05 §5.3） | 実装済み（vsync 整数本の計画、59.94/60/50/24fps のパターンをテストで固定） |
| 計測とレポート（08 §7） | 実装済み（窓集計の `MetricBus`、JSONL、`BenchmarkReport` の null 保持） |
| 適応制御（08 §4、§5） | 実装済み（`AdaptivePolicyEngine` の降格順序・hysteresis） |
| `EngineCore`（02） | 状態機械・設定適用・plan 生成まで実装（デコード・描画は未接続） |
| 契約のみ（03、04、06、07） | プロトコルと値型の実装（FFmpeg / libdvdnav / Core ML の実装は Phase 1 以降） |
| CI | `.github/workflows/ci.yml`（build / unit / licenses / fixtures） |
| 素材・ライセンス | `fixtures/manifest.json`、`licenses/inventory.json` と検査スクリプト（取得元と SHA は未決） |

確認手順:

```sh
make check     # build + test + license 検査 + fixture 検査
make test      # swift test
```

注: `Package.swift` のプラットフォーム下限は macOS 15（CI 互換のための暫定値）。製品の下限は OQ-12 で未決のまま。

## 文書規約

- Swift コードブロックは**設計例**であり、そのままコンパイルを保証するものではない。ただし公開 API の名前は実装時にそのまま使う前提で固定する。
- 「TBD」は書かない。未決はすべて [10-open-questions.md](10-open-questions.md) に OQ-番号で書き、本文では**当面の既定値**を書く。
- 数値（フレーム予算、キュー長、閾値）はすべて Phase 0〜3 の実測で置き換える前提の初期値であり、出典は該当節に「初期値」と明記する。
