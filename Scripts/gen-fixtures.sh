#!/bin/sh
# 合成 fixture の生成（docs/design/09-testing.md §2）。
#
# 実写・実盤の素材（ライセンス確認が必要なもの）は fixtures/real-registry.json に登録し、
# 生成で済む合成素材のレシピはここに持つ。生成結果のバイナリは fixtures/generated/ に置く。
#
# 使用するツール: ffmpeg（開発機・CI では Homebrew の bottle。アプリのバンドルには含めない）。
#   バージョンと configure 構成は fixtures/real-registry.json の tooling 節に記録する。
#
# 使い方: sh Scripts/gen-fixtures.sh [--force]

set -eu
cd "$(dirname "$0")/.."
OUT=fixtures/generated
[ "${1:-}" = "--force" ] && FORCE=1 || FORCE=""
mkdir -p "$OUT"

# gen <file> <ffmpeg 引数...>  : 既存ファイルは --force が無い限りスキップ
gen() {
  out=$1; shift
  if [ -z "$FORCE" ] && [ -f "$OUT/$out" ]; then
    echo "skip (exists): $out"
    return
  fi
  echo "gen: $out"
  ffmpeg -v error -y "$@" "$OUT/$out"
}

# 共通: testsrc2 は平坦領域・細い線・移動する図形・疑似テクスチャを含む。
# noise はノイズを加える（#8 の入力特性として）。seed を固定して再現可能にする。
NOISE='noise=alls=10:allf=u+p:all_seed=20261115'
SRC_NTSC='testsrc2=size=720x480:rate=30000/1001:duration=6'
SRC_PAL='testsrc2=size=720x576:rate=25:duration=6'
SRC_FILM='testsrc2=size=720x480:rate=24:duration=6'

# DVD 相当の MPEG-2 符号量と形式（7 Mbps 上限・VBV 1.835 Mbit・4:2:0）
M2=mpeg2video
M2DVD="-b:v 7M -minrate 7M -maxrate 9M -bufsize 1835008 -pix_fmt yuv420p -aspect 4:3"
# field 符号化（interlaced）。
#   注: ffmpeg 9 の mpeg2video encoder には top_field_first を指定するオプションが無い（`-top` は decoder 側）。
#   生成結果は ffprobe で実測し、実測値を manifest に記録する（期待値を推測で書かない）。
M2I="-g 15 -bf 2 -flags +ildct+ilme"
# sequence_display_extension を必ず書かせる（DAR / video_format の実在確認。#5 の受入基準）
M2SEQ="-seq_disp_ext always -video_format ntsc"

# 1. NTSC インターレース、2:2 キャデンス、MPEG-2 program stream（.VOB と同じ容器）
gen ntsc480i-22-01.mpg \
  -f lavfi -i "$SRC_NTSC" \
  -vf "$NOISE,fieldorder=tff" \
  -c:v $M2 $M2I $M2DVD $M2SEQ

# 2. 1 と同じ条件を MP4 に格納（AVAssetReader で raw sample が取りやすい形の基準）
gen ntsc480i-22-01-in-mp4.mp4 \
  -f lavfi -i "$SRC_NTSC" \
  -vf "$NOISE,fieldorder=tff" \
  -c:v $M2 $M2I $M2DVD $M2SEQ

# 3. PAL インターレース
gen pal576i-22-01.mpg \
  -f lavfi -i "$SRC_PAL" \
  -vf "$NOISE,fieldorder=tff" \
  -c:v $M2 $M2I \
  -b:v 7M -minrate 7M -maxrate 9M -bufsize 1835008 -pix_fmt yuv420p -aspect 4:3 \
  -seq_disp_ext always -video_format pal

# 4. Film 24p progressive（2:3 pulldown の提示計画テストの入力）
gen film24p-01.mpg \
  -f lavfi -i "$SRC_FILM" \
  -c:v $M2 -g 12 $M2DVD $M2SEQ

# 5. Telecine（24 → 29.97 の 3:2 pull-down。telecine filter が field 配列を作る）
gen telecine-32-01.mpg \
  -f lavfi -i "$SRC_FILM" \
  -vf "telecine=pattern=3" \
  -r 30000/1001 \
  -c:v $M2 $M2I $M2DVD $M2SEQ

# 6. H.264 インターレース（field / cadence 情報の保持を確認する素材。OQ-08 用）
#    実測（docs/experiments/EXP-001）: yuv422p（High 4:2:2）にすると VideoToolbox が
#    handler で -8969 を返して復号できなかった。テスト素材としては VideoToolbox が
#    扱える 4:2:0 にする（4:2:2 の扱いは 4:2:2 素材を用意する課題に切り分ける）。
gen ntsc480i-h264-01.mp4 \
  -f lavfi -i "$SRC_NTSC" \
  -vf "fieldorder=tff" \
  -c:v libx264 -pix_fmt yuv420p -x264-params "tff=1:interlaced=1:keyint=15"

# 7. Progressive SD / H.264 / MP4（#4 の最小経路の基準素材）
gen progressive-sd-mp4-01.mp4 \
  -f lavfi -i "$SRC_NTSC" \
  -c:v libx264 -crf 28

# 8. AC3 音声を含む program stream（音声デコードと audio master clock の実験用）
gen ntsc480i-ac3-01.mpg \
  -f lavfi -i "$SRC_NTSC" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -vf "fieldorder=tff" -c:v $M2 $M2I $M2DVD $M2SEQ -c:a ac3 -b:a 192k

# 8b. DTS 音声（AVFoundation が開けるか・復号できるか。OQ-02 の音声側の口の測定。EXP-002 §5）
gen ntsc480i-dts-01.mpg \
  -f lavfi -i "$SRC_NTSC" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -vf "fieldorder=tff" -c:v $M2 $M2I $M2DVD $M2SEQ -strict -2 -c:a dca -b:a 768k -ar 48000 -ac 2

# 9. 破損 program stream（切り落とし。#4 の失敗系テスト）
gen truncated-01.mpg \
  -f lavfi -i 'testsrc2=size=720x480:rate=30000/1001:duration=6' \
  -c:v $M2 $M2I $M2DVD $M2SEQ -t 4
dd if="$OUT/truncated-01.mpg" of="$OUT/truncated-01-cut.mpg" bs=1024 count=400 2>/dev/null

# 10. 合成 DVD（VIDEO_TS フォルダ + ISO。#3。母材料は ntsc480i-ac3-01.mpg）
sh "$(dirname "$0")/gen-dvd-fixture.sh"

echo
echo "--- 生成物 ---"
ls -l "$OUT"
shasum -a 256 "$OUT"/*
echo
echo "--- 実測プロパティ（この値を manifest に記録する）---"
for f in "$OUT"/*; do
  echo "== $f"
  ffprobe -v error -show_entries stream=index,codec_type,codec_name,profile,width,height,pix_fmt,\
field_order,color_range,color_space,color_transfer,color_primaries,sample_rate,channels,\
r_frame_rate,avg_frame_rate,nb_frames,duration \
    -of default=noprint_wrappers=1 "$f"
done
