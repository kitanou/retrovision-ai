#!/usr/bin/env python3
"""操作できる DVD メニューの検査用素材（合成。第三者の権利なし）を作る。標準ライブラリだけで動く。

材料は既存の合成素材: fixtures/generated/menu-still-01.vob（ピクチャ 1 枚の DVD 形式 VOB）と
truncated-01-cut.mpg（短い MPEG-2）。出力: fixtures/generated/dvd-menu-01/VIDEO_TS/
  VIDEO_TS.VOB   = truncated-01-cut.mpg（first-play のロゴ代わり）
  VTS_01_0.VOB   = menu-still-01.vob の NAV pack の PCI にボタン 3 つを書き込み、字幕（SPU）の sector を追加
  VTS_01_0.IFO   = タイトル 2（ttn1: セル 2 = チャプター 2、ttn2: 後半のセルだけ）+ メニューのパレット（黄色・ピンク）
  VTS_01_1.VOB   = truncated-01-cut.mpg（本編）
ボタン: 1 → JumpVTS_PTT(ttn 1, ptt 1)、2 → JumpVTS_PTT(ttn 1, ptt 2)、3 → JumpVTS_TT(ttn 2)。
ボタンの絵（SPU）: ボタンの矩形に、画素値 1 の縁（2 px）と画素値 2 の内側。SPU 自身はコントラスト 0（透明）で、
選択したときだけ PCI の btn_colit（画素値 1 → パレット 0、2 → パレット 1、コントラスト 11）で見える。
"""
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GEN = ROOT / "fixtures" / "generated"
OUT = GEN / "dvd-menu-01" / "VIDEO_TS"
OUT.mkdir(parents=True, exist_ok=True)

SECTOR = 2048


def be16(v): return struct.pack(">H", v)
def be32(v): return struct.pack(">I", v)


# ---- ボタン ----
BUTTONS = [  # (x0, x1, y0, y1, up, down, left, right, command)
    (100, 199, 100, 139, 0, 2, 1, 1, bytes.fromhex("3005000100010000")),
    (100, 199, 200, 239, 1, 3, 2, 2, bytes.fromhex("3005000200010000")),
    (100, 199, 300, 339, 2, 3, 3, 3, bytes.fromhex("3003000000020000")),
]


def make_pci(lbn, s_ptm, e_ptm):
    p = bytearray(979)
    p[0:4] = be32(lbn)
    p[12:16] = be32(s_ptm)
    p[16:20] = be32(e_ptm)
    h = 60 + 36
    p[h:h + 2] = be16(1)                        # hli_ss = 1（新規）
    p[h + 2:h + 6] = be32(s_ptm)
    p[h + 6:h + 10] = be32(0xFFFFFFFF)
    p[h + 10:h + 14] = be32(0xFFFFFFFF)
    p[h + 14] = 0x10                            # btngr_ns = 1
    p[h + 16] = 0                               # btn_ofn
    p[h + 17] = len(BUTTONS)                    # btn_ns
    p[h + 18] = 0                               # nsl_btn_ns
    p[h + 20] = 0                               # 強制選択なし → 1 番
    p[h + 22:h + 26] = be32(0x01070BB0)         # 色グループ 0 の選択: 画素値 1 → パレット 0、2 → パレット 1、コントラスト 11
    p[h + 26:h + 30] = be32(0x01070FF0)         # 実行: 同じ色で全不透明
    for k, (x0, x1, y0, y1, up, down, left, right, cmd) in enumerate(BUTTONS):
        o = h + 46 + k * 18
        w1 = (1 << 22) | (x0 << 12) | x1
        w2 = (0 << 22) | (y0 << 12) | y1
        p[o:o + 3] = w1.to_bytes(3, "big")
        p[o + 3:o + 6] = w2.to_bytes(3, "big")
        p[o + 6:o + 10] = bytes([up, down, left, right])
        p[o + 10:o + 18] = cmd
    return bytes(p)


# ---- 字幕（SPU）----
def rle_nibbles(length, color):
    v = (length << 2) | color
    n = lambda x: x & 0xF
    if length <= 3: return [n(v)]
    if length <= 15: return [n(v >> 4), n(v)]
    if length <= 63: return [0, n(v >> 4), n(v)]
    x = v >> 4
    return [0, n(x >> 4), n(x), n(v)]


def line_bytes(row):
    nib, i = [], 0
    while i < len(row):
        j = i
        while j < len(row) and row[j] == row[i]: j += 1
        nib += rle_nibbles(j - i, row[i])
        i = j
    if len(nib) % 2: nib.append(0)
    return bytes((nib[k] << 4) | nib[k + 1] for k in range(0, len(nib), 2))


def make_spu():
    x0 = min(b[0] for b in BUTTONS); x1 = max(b[1] for b in BUTTONS)
    y0 = min(b[2] for b in BUTTONS); y1 = max(b[3] for b in BUTTONS)
    w, h = x1 - x0 + 1, y1 - y0 + 1
    rows = []
    for y in range(y0, y1 + 1):
        row = []
        for x in range(x0, x1 + 1):
            v = 0
            for (bx0, bx1, by0, by1, *_r) in BUTTONS:
                if bx0 <= x <= bx1 and by0 <= y <= by1:
                    border = x < bx0 + 2 or x > bx1 - 2 or y < by0 + 2 or y > by1 - 2
                    v = 1 if border else 2
            row.append(v)
        rows.append(row)
    top = b"".join(line_bytes(r) for i, r in enumerate(rows) if i % 2 == 0)
    bottom = b"".join(line_bytes(r) for i, r in enumerate(rows) if i % 2 == 1)
    dcsq = 4 + len(top) + len(bottom)
    cmds = bytes([0x00, 0x03, 0x01, 0x23, 0x04, 0x00, 0x00])          # FSTA_DSP, SET_COLOR, SET_CONTR（全部 0 = 透明）
    cmds += bytes([0x05, x0 >> 4, ((x0 & 0xF) << 4) | (x1 >> 8), x1 & 0xFF, y0 >> 4, ((y0 & 0xF) << 4) | (y1 >> 8), y1 & 0xFF])
    cmds += bytes([0x06]) + be16(4) + be16(4 + len(top)) + bytes([0xFF])
    unit = bytearray(b"\0\0" + be16(dcsq) + top + bottom + be16(0) + be16(dcsq) + cmds)
    unit[0:2] = be16(len(unit))
    return bytes(unit)


def pes_sector(payload_with_substream):
    """private_stream_1（0xBD）の PES 1 個の sector（pack header + PES。余りは padding stream 0xBE）。"""
    s = bytearray(SECTOR)
    s[0:14] = bytes([0, 0, 1, 0xBA, 0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])
    length = 3 + len(payload_with_substream)
    s[14:23] = bytes([0, 0, 1, 0xBD]) + be16(length) + bytes([0x81, 0x00, 0x00])
    s[23:23 + len(payload_with_substream)] = payload_with_substream
    used = 23 + len(payload_with_substream)
    pad = SECTOR - used
    if pad >= 6:
        s[used:used + 6] = bytes([0, 0, 1, 0xBE]) + be16(pad - 6)
        s[used + 6:] = b"\xff" * (pad - 6)
    return bytes(s)


def spu_sectors(spu):
    chunk = SECTOR - 23 - 1 - 6
    out = []
    for i in range(0, len(spu), chunk):
        out.append(pes_sector(bytes([0x20]) + spu[i:i + chunk]))
    return out


# ---- メニュー VOB ----
still = (GEN / "menu-still-01.vob").read_bytes()
assert len(still) % SECTOR == 0
sectors = [bytearray(still[i:i + SECTOR]) for i in range(0, len(still), SECTOR)]
patched = False
for idx, sec in enumerate(sectors):
    # NAV pack: pack header の後（system header の後）に 0xBF の PCI（substream 0x00）。
    k = sec.find(b"\x00\x00\x01\xbf\x03\xd4\x00")
    if k != -1 and k < 64:
        sec[k + 7:k + 7 + 979] = make_pci(idx, 45045, 90090)
        patched = True
        break
assert patched, "menu-still-01.vob に NAV pack が見つからない"
menu = b"".join(bytes(s) for s in sectors) + b"".join(spu_sectors(make_spu()))
(OUT / "VTS_01_0.VOB").write_bytes(menu)

# ---- 本編・ロゴ ----
body = (GEN / "truncated-01-cut.mpg").read_bytes()
(OUT / "VTS_01_1.VOB").write_bytes(body)
(OUT / "VIDEO_TS.VOB").write_bytes(body)
body_sectors = len(body) // SECTOR


# ---- IFO ----
def pgc(programs, cells, duration, palette=(), pre=(), post=()):
    h = bytearray(0xEC)
    h[2] = len(programs); h[3] = len(cells)
    h[4:8] = duration
    for i, p in enumerate(palette[:16]): h[0xA4 + i * 4:0xA8 + i * 4] = be32(p)
    cmd = be16(len(pre)) + be16(len(post)) + be16(0) + be16(7 + (len(pre) + len(post)) * 8) + b"".join(pre) + b"".join(post)
    prog = bytes(programs) + (b"\0" if len(programs) % 2 else b"")
    cellpb = b"".join(be32(0x02000000) + t + be32(f) + be32(f) + be32(l) + be32(l) for (f, l, t) in cells)
    c_off = 0xEC; p_off = c_off + len(cmd); cell_off = p_off + len(prog)
    h[0xE4:0xE6] = be16(c_off); h[0xE6:0xE8] = be16(p_off); h[0xE8:0xEA] = be16(cell_off)
    h[0xEA:0xEC] = be16(cell_off + len(cellpb))
    return bytes(h) + cmd + prog + cellpb


def pgcit(entries):
    first = 8 + len(entries) * 8
    table, body_ = be16(len(entries)) + be16(0) + be32(0), b""
    for entry, data in entries:
        table += bytes([entry, 0]) + be16(0) + be32(first + len(body_))
        body_ += data
    out = bytearray(table + body_)
    out[4:8] = be32(len(out) - 1)
    return bytes(out)


def ptt(titles):
    first = 8 + len(titles) * 4
    table, body_ = be16(len(titles)) + be16(0) + be32(0), b""
    for t in titles:
        table += be32(first + len(body_))
        body_ += b"".join(be16(a) + be16(b) for a, b in t)
    out = bytearray(table + body_)
    out[4:8] = be32(len(out) - 1)
    return bytes(out)


half = body_sectors // 2
frames = lambda n: bytes([0x00, 0x00, 0x00, 0xC0 | n])           # n frame（29.97 fps）
cell1 = (0, half - 1, frames(6)); cell2 = (half, body_sectors - 1, frames(6))
# 実盤 PICHI と同じ作り: PRE で GPRM15 = 1、「GPRM12 == GPRM15 ならメニュー（VTSM ルート）を呼ぶ」。
# POST で GPRM12 = 1 にして自分へ Link（→ PRE の条件が成立してメニューへ戻る）。
title_pre = [bytes.fromhex("7100000f00010000"), bytes.fromhex("3028000001830c0f")]
title_post = [bytes.fromhex("7100000c00010000"), bytes.fromhex("2004000000000001")]
pgc1 = pgc([1, 2], [cell1, cell2], frames(12), pre=title_pre, post=[bytes.fromhex("7100000c00010000"), bytes.fromhex("2004000000000001")])
pgc2 = pgc([1], [cell2], frames(6), pre=title_pre, post=title_post)
palette = [0x00D88D2F, 0x008DC381] + [0x00108080] * 14
# メニューの PRE: GPRM12 = 0（本編の POST が立てた「終わった」印を下ろす。これが無いと、戻ったメニューから
# 本編に入った直後の PRE の条件（GPRM12 == GPRM15）が成立して、メニューへ戻されてしまう）。
menu_pgc = pgc([1], [(0, len(menu) // SECTOR - 1, frames(15))], frames(15), palette=palette,
               pre=[bytes.fromhex("7100000c00000000")])
lu = pgcit([(0x83, menu_pgc)])
ut = be16(1) + be16(0) + be32(0) + b"ja" + bytes([0, 0x80]) + be32(16)
ut = ut + b"\0" * (16 - len(ut)) + lu

ifo = bytearray(8 * SECTOR)
ifo[0:12] = b"DVDVIDEO-VTS"
ifo[0xC8:0xCC] = be32(1); ifo[0xCC:0xD0] = be32(2); ifo[0xD0:0xD4] = be32(3)
for sector, data in ((1, ptt([[(1, 1), (1, 2)], [(2, 1)]])), (2, pgcit([(0x81, pgc1), (0x82, pgc2)])), (3, ut)):
    ifo[sector * SECTOR:sector * SECTOR + len(data)] = data
(OUT / "VTS_01_0.IFO").write_bytes(bytes(ifo))
print("generated", OUT, "menu sectors:", len(menu) // SECTOR, "body sectors:", body_sectors)
