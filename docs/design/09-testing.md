# 09. テスト戦略・フィクスチャ・CI

対象: Phase 0 で足場を作り、各 Phase で増やす。設計の受け入れ基準を機械的に確かめるための文書。

## 1. テストの層

| 層 | 対象 | 実行頻度 | GPU 要否 |
|---|---|---|---|
| 純粋ロジック | 同期制御、キャデンス計画、seek、plan 生成、適応制御、ISO 解析 | 毎回（PR） | 不要 |
| 契約テスト | `PlayerEngine` / `MediaSource` / `VideoDecoder` / `VideoStage` / モデル契約 | 毎回 | 一部（tiny model） |
| GPU 出力検証 | shader・deint・色・比の出力 | 毎回（短い fixture） | 必要 |
| 再生統合 | 実ソース端到端の 5〜30 s 再生 + A/V drift | マージ時 | 必要 |
| 品質評価 | 画質指標、連番クリップの時間安定性、before/after | nightly | 必要 |
| 性能ベンチ | 08 §7.2 のレポート | nightly + ゲート手動実行 | 必要 |

## 2. フィクスチャ（テスト素材）の管理

`fixtures/` は Git に入れない（LFS も使わない）。代わりに `fixtures/manifest.json` を入れる。

```json
{
  "schemaVersion": 1,
  "root": "s3-or-file-server://retrovision-fixtures/v3/",
  "fixtures": [
    { "id": "ntsc480i-mixed-01", "kind": "videoTsFolder", "sha256": "…", "seconds": 60,
      "properties": ["interlaced22","4x3","mpeg2","ac3","spu-subtitle","blockNoise"],
      "license": "self-recorded / CC-BY-4.0", "notes": "…",
      "expectations": { "cadence": "interlaced22", "displayAspect": "4:3", "tracks": {"audio":2,"subtitle":1} } }
  ]
}
```

- 取得と検証は `Scripts/fetch-fixtures.swift`（または make target）。sha256 不一致は失敗させる。
- 最低セット（PR で使う小分けの 5〜10 s クリップ）:
  1. NTSC 480i 実写（動き・字幕・ノイズ）
  2. PAL 576i 実写
  3. 3:2 telecine 素材（film-based DVD 相当）
  4. アニメ 480i（線画・平坦な面）
  5. プログレッシブ SD MP4
  6. 壊れた VIDEO_TS（IFO 欠落・VOB 欠落）、不正な ISO、権限のない場所
- 素材の性質（`properties`）は `expectations` とつき合わせ、**ソース側の期待値テスト**に使う（03 §3 の構造モデルの検証）。

## 3. 決定論的にするための注入点

| 注入 | 方法 |
|---|---|
| 時刻 | `TimeSource`（01 §1）を `DeterministicClock` に置換。フレーム間隔を fake で駆動 |
| 音声クロック | `AudioClock` を protocol 化し、drift を値で注入（`FakeAudioClock`） |
| 音声出力 | `AudioSink` の fake（PCM を消費して frame position を返すのみ） |
| GPU | 検証は offscreen 描画 + `MTLTexture.getBytes` で CPU に戻す。表示経路は fake `PresentTarget` に差し替える |
| 推論 | tiny model（06 §8）または `StubModelRuntime`（決まった変換を行う） |
| ソース | `MemoryBlockReader`（合成ブロック列）と fixture reader |

制約: GPU 検証の offscreen 化は、`RenderPlan` に「present しない」の OutputContract を持たせて実現する（pipeline の分岐を増やさない）。

## 4. 性能テストの約束（PR で壊していないことを示す）

- 各 Phase の完了条件で測った baseline run（08 §7.2）を `bench/baselines/` に保存する。
- PR での実行は短い 2 分クリップ 1 本 + 2 tier（`.metalOnly`, `.fullML`）に限定し、**end-to-end p95 と dropped 数の悪化が 10% を超えたら失敗**にする（初期値。G1 後に数値を見直す）。
- GPU 実行環境が CI runner で違う場合、比較は「同一 runner 種別間でのみ」行う。絶対値を PR に書かない。
- 品質指標（PSNR 等）は PR では Gate にしない（夜間の progress として記録）。

## 5. 画質評価の手順（#7 #8 の受け入れ基準に紐づく）

1. 同一の 1 フレームを `.off` / `.metalOnly` / 比較中のモデル設定で描画し、PNG + plan JSON + metrics JSON を `bench/captures/` に保存。
2. 機械指標: PSNR / SSIM は**参照画像が無い DVD 素材では計算できない**ため、(a) 人工素材（合成ノイズ・パターン）で reference との比較、(b) 実写素材では VMAF（負荷なしモード）と「時間方向の差分統計」を使う。
3. 時間安定性（R3 の検査）: 連番 30 フレームでの平均フレーム間差分と、その分散。`flickerIndex = std(diff)/mean(diff)` を記録。
4. 主観レビューは 12 枚の contact sheet を作り、rubric（ringing / hallucination / line thicken / color shift / over-smooth）で 0〜3。結果は 07 §2.1 の比較表に human-readable で追記し、**数値だけ来判断しない**。
5. 結果は必ず「どの revision・どのモデル・どの plan」かで特定できるようにする（`planHash` + fixture sha256 + model revision）。

## 6. ライセンス・配布の実務（#3 #6 #9 の受け入れ基準）

- `THIRD-PARTY-NOTICES.md` を手で読む用に、`licenses/inventory.json` を機械で生成する（依存名、version、ライセンス、配布形態、ソース入手先、改変の有無）。
- モデルのライセンスは `models/*/model.json` の `license` を集約して `licenses/models.json` を作る。`outputRightsConfirmed: false` のモデルはビルドで警告になる（06 §2）。
- CI に「inventory に無い依存がリンクされていないか」の確認を入れる（`Scripts/check-licenses.swift`）。FFmpeg の configure オプション由来の差（GPL/LGPL の線引き）は、**ビルド設定を `third_party/ffmpeg/build-flags.txt` に固定**し、CI で再 build された flag と突き合わせる（OQ-02）。

## 7. CI の形

| ジョブ | 内容 | トリガー |
|---|---|---|
| `build` | SPM パッケージ + アプリのビルド、swift 静的解析 | PR |
| `unit` | §1 の純粋ロジック + 契約テスト（GPU なし） | PR |
| `gpu` | 短い fixture で offscreen 検証（macOS runner） | PR |
| `bench-quick` | §4 の限定的ベンチ | PR |
| `bench-full` | 08 §7.2 の全 tier 実行 | nightly / manual |
| `quality` | §5 の capture と指標算出 | nightly |
| `licenses` | §6 の inventory 検査 | PR |
| `model-convert` | coremltools による変換と契約検査（venv は `uv` で固定） | manual / nightly |

`gpu` ジョブで使う実行機の GPU が開発機と違う場合、閾値は runner ごとに別管理にする（閾値を 1 つにしない）。

## 8. Phase ごとの追加テスト（開発計画と対応）

| Phase | 追加するテスト |
|---|---|
| 0 | fixture 取得、計測出力の round-trip（JSON schema 検証）、CI の骨格 |
| 1 | SyncController / SeekController / Cadence の単体、`FakePlayerEngine` の契約、HW/SW 切替の統合 |
| 2 | deint・比・色の offscreen 検証、ISO / VIDEO_TS 解析、障害系（壊れた ISO など） |
| 3 | tiny model 契約、compute unit 比較の実験スクリプト、breaker の挙動 |
| 4 | 品質評価パイプライン、順序設定の描画比較、A/B 機能 |
| 5 | 適応制御の state machine 検査（fake 信号で昇格・降格）、bench-full、再現性（同一 planHash の一致） |
