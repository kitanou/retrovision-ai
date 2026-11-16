#!/bin/bash
# 合成 DVD fixture（#3。09 §3 の生成物）。
# 決定的な合成 ISO と VIDEO_TS フォルダを作る。内容は #12 の MPEG fixture の複製・分割
# （VOB は MPEG プログラムストリームそのものなので、再生経路の実測素材として等価）。
# 注意: hdiutil の ISO 生成はタイムスタンプ充填で完全決定論にならない。
# よって検査は「存在・構造・再生可能」まで（内容の integrity は元 .mpg の sha256 で担保し、
# マニフェストの sha256 は母材料のそれを記録する — derived fixture の約束）。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="fixtures/generated"
SRC="$OUT/ntsc480i-ac3-01.mpg"
[ -f "$SRC" ] || { echo "gen-fixtures.sh: 基となる MPEG fixture がありません: $SRC（先に ./Scripts/gen-fixtures.sh）" >&2; exit 1; }

mkdir -p "$OUT"
# 生成物は毎回作り直す（前の版の残骸がチェーン判定を汚染する — 実測で VTS_02_2 が残った）。
rm -rf "$OUT/dvd-video-ts-01" "$OUT/dvd-iso-01.iso"
mkdir -p "$OUT/dvd-video-ts-01/VIDEO_TS"
# IFO/BUP はダミータイトル列挙の検証用（中身はゼロ長: 「IFO が読めない」系の
# 警告を構造走査が正しく出すかの検査材料）。実パースは IFO 解析の増分で対応。
touch "$OUT/dvd-video-ts-01/VIDEO_TS/VIDEO_TS.IFO" "$OUT/dvd-video-ts-01/VIDEO_TS/VIDEO_TS.BUP"

# タイトル 1 を 2 パートのチェーンにする（segment demux の実測対象）。
# 実測（2026-11-17、SegmentPSDemuxerTests §2 のフォレンジック）:
#   * 中央の任意の pack 境界で機械分割 → GOP が途中で割れ part2 先頭 15 帧が復号不能
#     （part2 が 75/90 sample。AVF は圧縮素材の途中から読めない）。
#   * keyframe（I 帧）の PES 開始位置で切る → 喪失は part1 末尾の forward reference
#     frame 4 帧だけ（86+90=176/180。この合成 mpeg2 素材は open GOP で、GOP 末尾の
#     B 帧が次 GOP の frame を参照する。実 DVD authoring の cell 分割は closed-GOP で
#     喪失 0 — PICHI 実盤では part 全体が通ることを issue #3 で実測済み）。
# よって分割地点は ffprobe の keyframe 位置（packet flags に K）から選ぶ。直前の pack
# ヘッダ位置は keyframe PES と一致しない実測（この素材は pack ヘッダが 4096 B 間隔で
# セクタ境界に無いことがある）— PES 開始位置そのもので切る（2048 バイト境界の実測。
# 連結は母素材とバイト一致のまま）。
python3 - "$SRC" "$OUT/dvd-video-ts-01/VIDEO_TS" <<'PY'
import subprocess, sys, os
src, outdir = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
n = len(data)
half = n // 2
probe = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v",
     "-show_entries", "packet=pts,pos,flags", "-of", "csv", src],
    capture_output=True, text=True, check=True).stdout
keyframes = []
for line in probe.splitlines():
    parts = line.strip().split(",")
    if len(parts) >= 4 and "K" in parts[3]:
        pos = parts[2].strip()
        if pos.isdigit():
            keyframes.append(int(pos))
assert keyframes, "ffprobe が keyframe 位置を返さなかった"
target = min(keyframes, key=lambda k: abs(k - half))
assert n // 5 < target < n * 4 // 5, f"分割位置が偏っている: {target}"
assert target % 2048 == 0, f"keyframe PES がセクタ境界に無い: {target}"
open(os.path.join(outdir, "VTS_01_1.VOB"), "wb").write(data[:target])
open(os.path.join(outdir, "VTS_01_2.VOB"), "wb").write(data[target:])
print(f"VTS_01 分割（keyframe 整合）: {target} / {n} バイト（keyframe {len(keyframes)} 地点から中央最寄りを選択）")
PY

# タイトル 2 は別素材（truncated-01 の複製。単一 MPEG の機械スライスだと本数が
# タイトル 1 に近く、タイトル切り替えの e2e が数値で区別できなかった — 実測で別素材に
# 変更: タイトル 1 = 180 / タイトル 2 = 120（engine 経由。raw probe total=122 / 有効 120）。
# 列挙・切り替えの実測対象）。
cp "$OUT/truncated-01.mpg" "$OUT/dvd-video-ts-01/VIDEO_TS/VTS_02_1.VOB"
echo "VTS_02 = truncated-01.mpg の複製（4.04 s）"

# VMGM メニュー（VIDEO_TS.VOB。03 §5 のメニュー増分の fixture）。実盤ではメニューは
# 別素材だが、この fixture は構造・first-play 経路の検査材料なので truncated-01 の
# 複製で足りる（item id 0 / 1 / 2 で区別できる — VideoTsNavigator の menu 約束）。
cp "$OUT/truncated-01.mpg" "$OUT/dvd-video-ts-01/VIDEO_TS/VIDEO_TS.VOB"
echo "VIDEO_TS.VOB = truncated-01.mpg の複製（menu。4.04 s）"

# 合成 ISO（#3 のテスト対象は「マウントして VIDEO_TS が見えること」。実 DVD と同じ ISO9660）。
# 実測: `-quiet` を付けると失敗理由を出力せず exit 1 になる（2026-11-16）。素の出力で通す。
hdiutil makehybrid -iso -o "$OUT/dvd-iso-01.iso" "$OUT/dvd-video-ts-01"
ls -la "$OUT/dvd-iso-01.iso" "$OUT/dvd-video-ts-01/VIDEO_TS"
