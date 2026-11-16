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

# タイトル 1 を 2 パートのチェーンにする（連結 demuxer の実測対象）。
# 単一 MPEG を pack 境界で機械分割する（000001BA ヘッダを探す。VOB の分割単位は 2048 バイト・セクタ）。
python3 - "$SRC" "$OUT/dvd-video-ts-01/VIDEO_TS" <<'PY'
import sys, os
src, outdir = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
# 約半分の位置以降で最初のパック境界を探す（pack ヘッダ = 00 00 01 BA + program_stream_map）。
half = len(data) // 2
idx = data.find(b"\x00\x00\x01\xba", half)
assert idx > 0, "パック境界が見つからない"
assert idx % 2048 == 0, f"セクタ境界でない: {idx}"
open(os.path.join(outdir, "VTS_01_1.VOB"), "wb").write(data[:idx])
open(os.path.join(outdir, "VTS_01_2.VOB"), "wb").write(data[idx:])
print(f"VTS_01 分割: {idx} / {len(data)} バイト")
PY

# タイトル 2 は単一パート（小さい切り出し。列挙の検査用で、再生 e2e はタイトル 1 を使う）。
python3 - "$SRC" "$OUT/dvd-video-ts-01/VIDEO_TS" <<'PY'
import sys, os
src, outdir = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
head, idx = data[:200000], len(data)
tail_idx = data.rfind(b"\x00\x00\x01\xba")  # 終端パケットへ切りを寄せる
assert 0 < tail_idx < idx
open(os.path.join(outdir, "VTS_02_1.VOB"), "wb").write(data[:tail_idx])
print(f"VTS_02 切り出し: {tail_idx} バイト")
PY

# 合成 ISO（#3 のテスト対象は「マウントして VIDEO_TS が見えること」。実 DVD と同じ ISO9660）。
# 実測: `-quiet` を付けると失敗理由を出力せず exit 1 になる（2026-11-16）。素の出力で通す。
hdiutil makehybrid -iso -o "$OUT/dvd-iso-01.iso" "$OUT/dvd-video-ts-01"
ls -la "$OUT/dvd-iso-01.iso" "$OUT/dvd-video-ts-01/VIDEO_TS"
