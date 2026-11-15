# EXP-002 音声経路: AVFoundation だけで AC-3 → PCM ができるか

対応 issue: [#10]、OQ-19。日付: 2026-11-16。目的: 音声復号の依存方針（FFmpeg shim を入れるべきか）を測りで決める。映像側の EXP-001（[EXP-001](EXP-001-dependency-and-videotoolbox.md)）と同じ問いの音声版。

## 1. 計測環境（EXP-001 と同一。再掲）

| 項目 | 値 |
|---|---|
| 開発機 / macOS | Mac Studio (Mac17,14) / M5 Max 64GB / 27.2.1 (26B131) |
| Swift / Xcode | 6.4.2 / 27.2 (27B52)。target arm64-apple-macos15.0 |
| 再生経路の依存 | なし（AVFoundation / CoreMedia のみ）。ffmpeg 9.0.2 は素材生成用で本実験には不使用 |

## 2. 方法

`rvprobe` に音声実験を追加した（`RVDecodeProbe/main.swift` の `audioExperiment` / `audioStep`）。AC-3 トラックを持つ素材 `fixtures/generated/ntsc480i-ac3-01.mpg`（192 kbps、48 kHz、正弦波=実質 mono、音声長 ≈6 s）に対して 2 経路を順に読む:

1. **passthrough**: `AVAssetReaderTrackOutput(outputSettings: nil)`。ES サンプルの数・大きさ・PTS・ASBD
2. **linearPCM 要求**: `outputSettings = [lpcm, 48000, 2ch, 16bit, packed, LE, non-float]`。実際に得られた出力 ASBD、バッファ数、wall time、PTS span から実時間率を算出

再現: `make probe && python3 Scripts/show-probe.py bench/captures/probe-ntsc480i-ac3-01.mpg.json`

## 3. 結果

| 経路 | 結果 | サンプルバッファ | wall | 実時間率 | PTS |
|---|---|---|---|---|---|
| passthrough | ok | **4 個**（約 1.5 s/個、36 KB、numSamples=63） | 24.1 ms（初バッチ込み） | 測れず | 先頭 valid・**末尾 invalid** |
| linearPCM | ok | 36 個（**8192 帧/個 ≈ 171 ms**） | 5.4 ms | **≈1100×**（span 5.97 s） | 全 valid |

出力 ASBD（linearPCM 要求に対して実際に返ったもの）: `lpcm 48000 Hz / 2ch / 16bit packed（bytesPerFrame=4）/ framesPerPacket=1 / layout tag 0x650002`。要求仕様どおり。ソースの AC-3 ASBD は `ac-3 / 48000 / 1ch / layout tag 0x640001` — **この fixture は実質 mono**（sine 源）。5.1ch の配置経路は未検証（実盤＝OQ-16 で再測定）。

## 3b. 追加実験: DTS（同一 probe 経路、2026-11-16）

`ntsc480i-dts-01.mpg`（MPEG-PS + DCA/DTS 48 kHz/2ch、ffmpeg `-strict -2 -c:a dca` で生成。dca コーダは experimental 扱いで `-strict -2` が要る）を生成して同じ rvprobe を通した:

- **open は ok、video トラックだけ列挙される。audio トラックは 0 本**（AVFoundation が MPEG-PS 内の DTS を受けず、警告も出ない）
- つまり DTS は passthrough も PCM 変換も成立しない。**DTS は「FFmpeg shim が要る口」の確定した例**（OQ-02 の音声側の口）
- DVD-Video 仕様では DTS は必須ではなく LPCM/AC-3 が必須。当面の既定は **Phase 4 shim ゲートまで DTS 非対応**（トラック表に現れないので選択仕様としても扱えない）

## 4. 実測で確定した事実（A1〜A6。コードと 04 §4 のコメントがこの番号を参照する）

**A1 — AC-3 → PCM の変換は AVFoundation だけで成立する。** 追加依存（FFmpeg shim / AudioToolbox 自前管理）は不要。`AVAssetReaderTrackOutput` の outputSettings に線形 PCM を要求するだけで、システムが AC-3 を復号・リサンプレして渡す。

**A2 — 出力バッファの粒度は 8192 帧（≈171 ms @48 kHz）に結合される。** 04 §4 の 480 帧（10 ms）quantum は**こちらの AudioDecoder 側で切る**必要がある。结合の制御口（AVAssetReader の settings に frame 数のキー）は見つからない。

**A3 — passthrough では AC-3 ES が ~1.5 s 単位で結合され、末尾サンプルの PTS が invalid になる。** ES を直接読む経路（将来の自作復号や passthrough 出力）を使う場合、クロックはサンプル PTS だけで進めず、末尾の invalid に対する打ち切り規則が要る。PCM 経路では PTS は全て valid。

**A4 — PCM 復号のスループットは実時間の約 1100 倍（バースト）。** 6 s 音声が 5 ms で PCM 化される。フレーム予算（33.4 ms）に対して音声復号は**常時 0.01 ms/帧 未満**。ただしこれは paced でない単発計測で、G1 の in-line 値は #11 の再生線で測る。

**A5 — 初期化コストは passthrough で 24 ms（初バッファ取得に含まれる）。** 音声セッション開始時の warmup は映像の初帧スパイク（EXP-001 F13 系・OQ-18）とまとめて扱うべき。

**A6 — DTS はトラックとして存在しなくなる。** MPEG-PS 内の DTS を AVFoundation は列挙しない（open ok・audio トラック 0 本・警告なし、§3b）。映像は通常どおり再生できる。UI のトラック選択にも出ないため「選べない音声」ですらない。

## 5. この実験で答えなかったこと（次に渡す）

- 5.1ch AC-3 の配置変換（layout tag 変換の挙動）— 実盤素材で（OQ-16）
- AudioSink（AVAudioEngine）に流したときの実出力遅延・rendered frame 読取り・drift p95 — #10 の実装側
- AC-3 以外の音声: **DTS は §3b で答えが出た（トラックとして存在しなくなる＝A6）**。LPCM passthrough・AAC の挙動は実装・実盤（OQ-16）時に同一経路で確認
- 映像との clock 統合（audio master）— 04 §5 の設計は変わらないが、原料（valid PTS + frame count）は A3 が PCM 経路側にある

## 6. 結論と反映

- **OQ-19 の復号経路部分は決定**: AC-3 は AVFoundation の PCM 変換で復号する（依存ゼロ方針を維持）。FFmpeg shim の導入判断には音声を持ち出さない。
- 04 §4 に A2/A3 の制約を反映（quantum 分割は AudioDecoder 実装側、passthrough を使う場合は末尾 invalid PTS の規則）。
- **DTS（A6）**: AVFoundation は MPEG-PS 内の DTS をトラックとして列挙しない。DVD-Video 仕様で DTS は必須項目ではない（LPCM/AC-3 が必須）。**当面の既定: Phase 4 の FFmpeg shim ゲート（OQ-02）まで DTS 非対応**。dca fixture（`ntsc480i-dts-01.mpg`）を生成・登録済みで、shim 実装時の受け入れ検査にそのまま使える。
- 残りは実装（AudioSink / AudioClock / 再生線接続 = #10・#11）と、G1 の in-line 計測。
- 決定ログ: [10-open-questions.md](../design/10-open-questions.md) OQ-19。
