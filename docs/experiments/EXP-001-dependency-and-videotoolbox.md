# EXP-001 — 依存ライブラナシの再生パス（AVFoundation + VideoToolbox）の可行性と実測

- 実施日: 2026-11-15
- 対応ゲート: **G1**（素の再生パスの可行性と予算確定）の前半。「MPEG-2 / H.264 の SD 素材が
  FFmpeg なしで demux + 復号できるか」「format 信号（frame rate / PAR / field / 色）がどこまで
  正直に取れるか」
- 判断入力: **OQ-01**（FFmpeg 導入の要否）、**OQ-02**（復号は VideoToolbox 直行で足りるか）、
  **OQ-08**（field / cadence 信号の取得源）
- 結論（要約）:
  1. **AVFoundation + VideoToolbox 直行経路で全素材が demux + 復号できた**（FFmpeg shim 不要）。
     OQ-01 / OQ-02 の暫定既定「AVFoundation 経路を先に持つ」が実測で支持された。
  2. MPEG-PS の container は field 数と PAR は渡すが、**field 順序は渡さない**。順序は
     bitstream の picture_coding_extension のみが知る信号（H.264 ではそれも失われる → OQ-08 の
     detector 必要性が裏付けられた）。
  3. **デコーダが付帯させる色情報は推測**（`ColorInfoGuessedBy` 付き bt709）。plan 段では信用しない。
  4. 復号スループットは 172〜1,555 fps、1 帧あたり p50 0.4〜1.7 ms。**33.37 ms 予算に対し復号単体は余裕**。
     初帧スパイク（44〜70 ms）はセッション初期化で、warmup の必要性を示す。

## 1. 計測環境（すべて実測値）

| 項目 | 値 |
| --- | --- |
| macOS | 27.2.1（Build 26B131）、arm64 |
| ハード | Apple M5 Max / 64 GB |
| Xcode / Swift | Xcode 27.2（27B52）、Apple Swift 6.4.2（swiftlang-6.4.2.1.9） |
| deployment target | arm64-apple-macos15.0（standalone 検証時）/ swift-tools-version 6.0 |
| ffmpeg（fixture 生成と対照） | ffmpeg 9.0.2（Homebrew） |
| libdvdnav / libdvdread / libdvdcss | 7.0.0 / 7.1.1 / 1.6.0（Homebrew、**この実験では未使用**） |

## 2. 方法

再現手順（リポジトリルートで）:

```sh
sh Scripts/gen-fixtures.sh            # fixture 生成（既存ファイルは skip、ffprobe 実測値も出力）
swift build --build-tests             # Packages/RetroVisionKit
swift test
swift build -c debug --product rvprobe
cd Packages/RetroVisionKit
for f in ../../fixtures/generated/*; do
  ./.build/debug/rvprobe --json "$f" 2>"/tmp/probe_$(basename "$f").json" >/dev/null
done
python3 ../../Scripts/show-probe.py /tmp/probe_*.json
```

対照として `ffprobe`（同じ Homebrew 9.0.2）で stream / frame 単位のプロパティ
（`field_order`, `interlaced_frame`, `top_field_first`, `repeat_pict`, `r_frame_rate`,
`profile`, `level`, `pix_fmt`）を取り、自前パーサのバイト列照合と突き合わせた。
VideoToolbox 単体の動作確認（0 長 sample の挙動など）は
`xcrun swiftc -target arm64-apple-macos15.0` の standalone プログラムで切り分けた。

rvprobe が測るもの: open 成否と所要時間、track 数、demux が渡す format description の
extension keys と値（PAR・field 数）、sample の ES 先頭バイト、PTS 列からの frame rate 推定、
MPEG-2 bitstream（sequence header / sequence_extension / sequence_display_extension /
picture_coding_extension）の実値、VideoToolbox 復号の成功帧数・per-frame 時間分布・
復号出力の attachment keys・pixel format・寸法。

## 3. 素材（Scripts/gen-fixtures.sh 生成物、sha256）

| 素材 | 内容 | sha256（先頭 16 桁） |
| --- | --- | --- |
| film24p-01.mpg | MPEG-2 PS 24/1 progressive（3:2 pull-down 検出用素材の下地） | 4d3d2246a996a7d0 |
| telecine-32-01.mpg | MPEG-2 PS 29.97 field 符号化 + telecine cadence | eddfc1fed7cf7d19 |
| ntsc480i-22-01.mpg | MPEG-2 PS 720x480 29.97 bb（DVD 想定） | 5fa64cddcbfdc4f6 |
| ntsc480i-22-01-in-mp4.mp4 | 同上の MPEG-2 を MP4 に mux（container 差異の実験） | b3fa2a561a12620f |
| pal576i-22-01.mpg | MPEG-2 PS 720x576 25/1 bb | e0ffd88a87e43de2 |
| ntsc480i-h264-01.mp4 | H.264 720x480 29.97 tff（yuv420p、field/cadence 保持の確認用） | f9ef57fbc002bcbf |
| progressive-sd-mp4-01.mp4 | H.264 progressive SD | 3b084484c40cd9d0 |
| ntsc480i-ac3-01.mpg | MPEG-2 + AC3 音声（音声 clock 実験用。映像のみ計測） | 80bd81ee36c4f4d5 |
| truncated-01.mpg | 120 sample に切り落とし | dc70918e34b98aa6 |
| truncated-01-cut.mpg | 400 KB で強制切断（破損系） | 8e8fd4ad0fe1cdd7 |

生成 recipe の変更履歴（実測驱动的）: `ntsc480i-h264-01.mp4` は当初 yuv422p（High 4:2:2）で
生成していたが、**VideoToolbox が handler で -8969 を返して復号できなかった**（§6 F8）。
yuv420p（High 4:2:0）に再生成し、sha が変わった。4:2:2 素材の扱いは未検証のまま別課題。

## 4. 結果 1: demux + 復号（VideoToolbox 直行、全 10 素材）

全素材 `openStatus: ok`、受け取った sample 数と復号帧数が一致（零長 sample は demux 段で間引く。§6 F2）。

| 素材 | open ms | samples | decoded | fps（total 基準） | 1 帧 ms（mean / p50 / p95 / max） | 出力 |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| film24p-01.mpg | 23.3 | 144 | 144 | 780 | 1.12 / 0.59 / 1.01 / 62.5 | 420v 720x480 |
| ntsc480i-22-01-in-mp4.mp4 | 5.6 | 180 | 180 | 1,119 | 0.88 / 0.55 / 0.67 / 57.9 | 420v 720x480 |
| ntsc480i-22-01.mpg | 26.3 | 180 | 180 | 982 | 0.93 / 0.54 / 0.96 / 59.9 | 420v 720x480 |
| ntsc480i-ac3-01.mpg | 28.5 | 180 | 180 | 1,025 | 0.94 / 0.54 / 0.98 / 61.0 | 420v 720x480 |
| ntsc480i-h264-01.mp4 | 1.4 | 180 | 180 | 524 | 1.91 / 1.75 / 2.14 / 45.0 | 420v 720x480 |
| pal576i-22-01.mpg | 27.8 | 150 | 150 | 852 | 1.11 / 0.63 / 1.03 / 61.1 | 420v 720x576 |
| progressive-sd-mp4-01.mp4 | 1.4 | 180 | 180 | 1,555 | 0.65 / 0.40 / 0.46 / 43.6 | 420v 720x480 |
| telecine-32-01.mpg | 22.1 | 181 | 181 | 990 | 0.98 / 0.55 / 0.96 / 60.6 | 420v 720x480 |
| truncated-01-cut.mpg | 4.4 | 12 | 12 | 176 | 5.61 / 0.86 / 59.0 / 59.0 | 420v 720x480 |
| truncated-01.mpg | 17.6 | 120 | 120 | 810 | 1.11 / 0.53 / 1.00 / 59.9 | 420v 720x480 |

読み方:

- **MPEG-2 の p50 は 0.5〜0.6 ms**。33.37 ms 予算に対して復号単体の占有率は 2% 未満。
  G1 の「復号予算」は VideoToolbox 経路では実質ただちに通る。
- max が 44〜70 ms に跳ねるのは**初帧（セッション初期化・デコーダ warmup）**。truncated-01-cut
  （12 帧のみ）は mean 5.6 ms がそれを反映する。実運用では warmup を再生開始前に行う設計判断の根拠。
- H.264（progressive）は p50 0.4 ms とさらに軽い。H.264 tff（F8 の再生成後）も 1.75 ms で問題ない。
- MP4 mux の MPEG-2（in-mp4）は PS より open が速い（5.6 ms vs 26.3 ms）。
  MPEG-PS の open は 17〜28 ms かかり、**シーク後の再 open コストの見積もりに使える**。

## 5. 結果 2: format 信号の解決（どこまで正直に取れるか）

| 素材 | container PAR | container field 数 | PTS 推定 | bitstream（sample ES） | 最終解決 frameRate | 最終 field 順序 |
| --- | --- | --- | --- | --- | --- | --- |
| ntsc480i-22-01.mpg | 10:11 | 2 | 30000/1001 ✓ | rate=30000/1001 progSeq=0 PCE: tff=0 | 30000/1001 | bottom-first（PCE 由来） |
| ntsc480i-22-01-in-mp4.mp4 | 8:9 | 2 | 30000/1001 ✓ | 同上（video_format=NTSC） | 30000/1001 | bottom-first |
| pal576i-22-01.mpg | 59:54 | 2 | 25/1 ✓ | rate=25/1 progSeq=0 video_format=PAL | 25/1 | bottom-first |
| film24p-01.mpg | 10:11 | 0 | 24/1 ✓ | rate=24/1 **progSeq=1 PCE: progressive_frame=1** | 24/1 | progressive（矛盾なし） |
| telecine-32-01.mpg | 10:11 | 2 | 30000/1001 ✓ | rate=30000/1001 progSeq=0 | 30000/1001 | bottom-first |
| ntsc480i-h264-01.mp4 | **なし** | **0**（tff 素材なのに） | 30000/1001 ✓ | （MPEG-2 でないため無し） | 30000/1001 | progressive（**信号喪失**） |
| progressive-sd-mp4-01.mp4 | なし | 0 | 30000/1001 ✓ | — | 30000/1001 | progressive（正しい） |
| truncated-01-cut.mpg | 10:11 | 2 | unresolved | 30000/1001 ✓ | 30000/1001（container hint） | bottom-first |

- 解像度（720x480 / 720x576）と subtype（mp2v / avc1）は全素材で container から取れた。
- **frame rate は 3 経路とも機能**：container hint（`nominalFrameRate` float が既知標準に一致）→
  bitstream（後述）→ PTS 列推定。truncated-01-cut では PTS 推定が sample 不足で unresolved のまま
  container hint で解決した（フォールバック連鎖の設計が実データで成立）。
- 生成素材の bitstream は `sequence_extension` から profile=Main / level=8 / chroma=4:2:0 /
  progressive_sequence が ffprobe と一致、`sequence_display_extension` は色 code=2（unspecified）
  で表示寸法=coded 寸法だった（§6 F9）。

## 6. 実測で確定した事実（F1〜F13。設計とコードのコメントがこの番号を参照する）

**F1 — MPEG-2 program stream は AVFoundation でそのまま開ける。** `AVURLAsset` +
`AVAssetReaderTrackOutput(outputSettings: nil)` で ES samples が passthrough で取れる。
PES ヘッダは剥がされ、**最初の sample の先頭に sequence_header がそのまま残る**
（firstBytesHex が `000001b32d01e0…`）。FFmpeg shim なしで demux + bitstream 参照が成立する。

**F2 — AVFoundation は先頭に 0 長の buffer を渡すことがある。** numSamples=0 の
`CMSampleBuffer` を渡すと `VTDecompressionSessionDecodeFrame` が **-12902
（kVTParameterErr）** を返す。standalone 検証で再現を固定し、demux 段に
`CompressedSample.hasSampleData` ゲートを置いて間引いた（間引いた sample は数えない。
dropped 計上が二重計上にならない）。

**F3 — MPEG-PS の format description が持つ extension keys は `CVFieldCount` /
`CVPixelAspectRatio` / `Depth` の 3 つだけ。** `VerbatimSampleDescription` は**付かない**
（`ntsc480i-22-01.mpg`: verbatimSampleDescriptionBytes=0）。MP4 mux 版（in-mp4）では
`CVFieldDetail` / `FormatName` / `VerbatimISOSampleEntry` などが増える。
**PS 素材の verbatim ヘッダ参照は sample の ES を読む経路が必須**（F1）。

**F4 — PAR は container を通過するが、値は標準の有理数と一致するとは限らない。**
NTSC PS は 10:11（期待どおり）だが、PAL PS は **59:54**（期待は 12:11）、MP4 mux 版は
**8:9**（期待は 10:11）だった。数値の系統が素材ごとに違う。**受領値をそのまま
`sampleAspectFromStandard` として保出し、AspectResolver に渡す**（設計 05 §6 の方針）。
H.264 素材は PAR 自体が付かず（`CVPixelAspectRatio` key なし）、その場合は bitstream・
DAR 情報も無いため 05 §6 の fallback 経路が実際に通る。

**F5 — field 情報は container 側では「数」しか渡らない（PS）。** `CVFieldCount`=2 は立つが
**順序を語る key は MPEG-PS に存在しない**。MP4 mux では `CVFieldDetail` が現れる
（値の解読は今回未完了 → 要続き §7）。
**追記（2026-11-17・OQ-17 / #14）**: `ntsc480i-22-01-in-mp4.mp4` の container format description の
`CVFieldDetail` は **`SpatialFirstLineLate`**（temporal ではなく空間順。最初の行が後の field =
bottom field が先）。同素材の PCE は `top_field_first=0`（bottom-first）で方向は整合する。
復号出力の attachment にもキーは付くが、現行の写像（temporal の 2 値のみ）では `.unknown` になる。
順序の源は引き続き PCE（detail は読むだけ）。`DecodePathTests` で container 値を固定。

**F6 — field 順序の唯一の信頼できる源は picture_coding_extension。**
`000001B5` + identifier `1000` に `picture_structure` / `top_field_first` /
`repeat_first_field` / `progressive_frame` が並び、**ffprobe の帧単位
`interlaced_frame` / `top_field_first` と 1 帧単位で一致**した
（生成素材は bb = top_field_first=0、film24p は progressive_frame=1）。
`sequence_extension` には top_field_first は**存在しない**（順序は picture 层の信号）。
plan 段（05 §4）が sample ごとに読む必要がある。

**F7 — PTS 列は decode 順（presentation 順ではない）。** B 帧のある素材で
`copyNextSampleBuffer` の PTS は昇順にならない。frame rate 推定は
**PTS の重複除去 + 整列後、総フレーム数 ÷ 総スパン**で測る
（`frameRate(fromPTSs:)` の実装はこれ。GOP 内で間隔が不均一でも平均はレートに収束する）。

**F8 — VideoToolbox は H.264 High 4:2:2（yuv422p）をこの環境で弾いた。**
`AVC1`+`yuv422p` の生成直後に全 trial で handler status **-8969**（buffer なし）。
High 4:2:0（yuv420p）へ変更して解決。4:2:2 の扱いは未検証（素材側を 4:2:0 に統一）。

**F9 — 生成素材（ffmpeg 9.0.2 mpeg2video）の bitstream 構文は规格と部分的に違う。**
パーサの実測契約として確定した要点（詳細は `MPEG2Bitstream.swift` のコメントに同期）:
- `bit_rate` の後ろの marker_bit、`vbv_buffer_size` の後ろの marker_bit は必須。
- `constrained_parameters_flag == 0` でも** MPEG-2 追加 header フィールド
  （ISO 6.2.2.2 の video_format 等）を書かない符号化器がある**（ffmpeg は byte 境界 padding 後
  直接 extension）。→ 核心部（63 bit）より後ろは bit で辿らず、byte 位置の start code
  から extension を読む実装にした（规格準拠 stream でも同じコードで読める）。
- **sequence / picture 层の全 extension は `000001B5` + identifier 4 bit**
  （0001=sequence_extension, 0010=sequence_display_extension, 1000=picture_coding_extension）。
  `000001B8` は **GOP header** であり extension ではない（誤読すると PCE を取り違える）。
- `sequence_display_extension` の色 code は **8 bit**（MPEG-2 の表）。生成素材は 2,2,2
  （unspecified）。display 寸法は coded 寸法と同値だった。
- picture_coding_extension の f_code 最初の 4 bit は identifier と**同じ byte** にある
  （payload を byte 境界から読み直すと 4 bit ずれて picture_structure が壊れる。実測で確認）。
- `frame_rate_code` の表は 2=24/1, 3=25/1, 4=30000/1001, 5=30, 6=50, 7=60
  （生成素材の code は 2/3/4 で一致）。

**F10 — デコーダは色を「推測して」付ける。** SD MPEG-2 の復号出力には
`CVImageBufferColorPrimaries=bt709` 等が **`ColorInfoGuessedBy` タグ付き**で付帯した。
付帯の可否ではなく **guess フラグの有無で信用度を判定**する（05 §3「plan 段は宣言された
信号だけを使う」の実装要件）。

**F11 — field 符号化の H.264 はデコード時点で progressive として扱われた。**
tff 生成素材（x264 tff=1）に対し、復号出力の `CVFieldCount` は 0/progressive で
**field 信号が復号器を通過しない**。MPEG-2（fieldCount=2 は残る）と挙動が違う。
→ OQ-08 の「detector による推定」は H.264 素材で初めて意味を持つ。

**F12 — 出力 pixel format は `420v`（video-range 4:2:0 planar）に統一して取れた。**
寸法は coded 寸法のまま（letterbox / clean aperture の適用は後段。05 §6）。

**F13 — 同期 decode の出力は decode 順で届く。presentation 順は実装側の責任。**
統合テスト（`DecodePathTests`）が B 帧素材で検出した: 挿入並べ替えだけでは、
GOP 末尾の P 帧（pts 9009）が B 帧（pts 3003・6006）より先に取り出されていた。
修正後の契約: **「次に供給される sample が現れるまで（= reordering buffer に 2 件以上
あるときだけ）先頭を取り出す」**。GOP の深さに依らず presentation 順が成立することを
テストで固定した（残余は flush が昇順で出す）。

## 7. この実験で答えなかったこと（次の計測に渡す）

1. **実 DVD-Video（VIDEO_TS/VOB・IFO の PAR・4:3 flag）での再実行**。合成素材の
   F4/PAR 系統の違いは実盤で結論が変わる可能性がある（fixtures registry の課題と同居）。
2. ~~`CVFieldDetail` の値の解読~~ → **解読済み（2026-11-17）**: `SpatialFirstLineLate`、PCE と整合（F5 追記）。残: temporal 値を持つ素材での検証と fixture ground truth の確定（生成器 tff 意図 vs 実測 bottom-first）。
3. **シーク / format change（解像度・profile 切替）時の再設定コスト**。open 実測は
   「先頭から順読み」のみ。
4. **音声（AC3）デコードと audio master clock**（素材 ntsc480i-ac3-01.mpg は用意済み）。
5. H.264 4:2:2（-8969 の扱い: ソフト復号 fallback の要否）。
6. 長時間再生でのドリフト（G1 の後半。clock 設計側の課題）。

## 8. 設計・実装への反映（この実験が変えたもの）

| 対象 | 変更 |
| --- | --- |
| `CompressedSample`（RVDecode/Contracts） | `hasSampleData` ゲート追加（F2）。`videoFormatDescription` は sample 由来をそのまま返す |
| `AVFoundationDemuxer` | 零長 sample の間引（F2）、`seedFormatDescription`（F3 の container 参照）、`firstSampleBytes` による bitstream 参照（F1/F9）、field 順序の PCE 解決（F5/F6）、frame rate フォールバック連鎖（§5） |
| `MPEG2Bitstream` | 実測契約に基づく全面的書き直し（F9）。`MPEG2PictureCodingExtension` 追加（F6）。frame_rate_code 表の訂正 |
| `VideoToolboxDecoder` | presentation 順の遅延出力契約（F13）。統合テストで回帰固定 |
| `RVMediaCore.Time.frameRate(fromPTSs:)` | decode 順対応（F7：重複除去 + 整列 + 総数/総スパン） |
| plan 段（05 §3 予定） | 復号出力の guessed color を信用しない判定（F10）、H.264 field 喪失への detector 経路（F11、OQ-08） |
| fixtures | H.264 を yuv420p に再生成（F8）、生成 script は再実行可能（既存 skip） |

なお、**FFmpeg / libdvdnav 系の Homebrew インストールはこの実験を使っていない**（OQ-01 の
範囲では shim 不要）。DVD 再生（IFO/VOB の menu・cell 制御）は libdvdnav の領域のまま残る。
