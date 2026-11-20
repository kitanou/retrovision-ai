#!/usr/bin/env python3
"""実盤（所有盤の ISO / VIDEO_TS）から、検査用の短い VOB を VOBU（NAV pack）境界で切り出す。
非同梱: 出力は fixtures/local/（.gitignore 済み）。使い方:
  python3 Scripts/extract-real-fixture.py <VOB> <開始 sector> <sector 数> <出力名>
開始 sector は次の NAV pack（private_stream_2 0xBF を持つ sector）まで進める。"""
import hashlib, pathlib, sys

src, start, count, name = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
out = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "local"
out.mkdir(parents=True, exist_ok=True)
S = 2048
with open(src, "rb") as f:
    f.seek(start * S)
    while True:                                   # 次の NAV pack まで進める
        pos = f.tell()
        sec = f.read(S)
        if len(sec) < S: sys.exit("NAV pack が見つからない")
        if sec[14:18] == b"\0\0\1\xbb" and sec[38:42] == b"\0\0\1\xbf":
            f.seek(pos); break
    data = f.read(count * S)
dest = out / f"{name}.vob"
dest.write_bytes(data)
print(dest, len(data) // S, "sectors, from", pos // S, "sha256", hashlib.sha256(data).hexdigest())
