import Foundation

// MARK: - 埋め込み MSL（05 §9 の命名規約 <stage>_<variant>）
//
// シェーダはソース文字列として埋め込む（SPM library/executable に Bundle が無い。#16 で
// バンドル化してもこの形は壊れない）。段の並び順は plan が決める（05 §4 の固定ポリシー）。
// ここでは基底の vertex（全画面三角）と、色変換・スケール・デインターレース・field 差分の
// kernel/fragment を用意する。
//
// 段のデータ領域（05 §3: 中间は RGBA16F ではなく YUV のまま。deint は源の luma に対して
// 行う — 色変換より前。スケールも deint の後。§4 の順序どおり）:
//   import(NV12: r8 + rg8) → [deinterlace: 读 r8/rg8, 写 r8/rg8（progressive 化）]
//     → colorConvert+scale（读 r8/rg8, 写 drawable/offscreen RGBA）

public enum MetalShaders {
    public static let source = """
#include <metal_stdlib>
using namespace metal;

// ---------- 共通: 全画面三角 ----------

struct VSOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VSOut rv_vs_fullscreen(uint vid [[vertex_id]]) {
    float2 pts[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VSOut o;
    float2 p = pts[vid];
    o.pos = float4(p, 0.0, 1.0);
    // 頂点 uv: 左下(0,0) → 右上(2,2) で覆う。CVPixelBuffer→texture は行 0 = 画面上部、
    // CAMetalLayer の内容も行 0 = 表示上部（CALayer は左上原点）。clip 系は y 上向きなので
    // ここで y を反転して揃える（#5 の GPU 検査で反転を実測: 反転なしだと上下逆になった）。
    // 以降の uv（sourceRect/destRect）は全て「行 0 = 上」の画像系として一貫する。
    o.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return o;
}

// ---------- colorConvert + scale（単一 pass: crop / letterbox / 色 / 缩放） ----------

struct ColorParams {
    float m[9];        // YCbCr→RGB（行优先。ColorMatrixBuilder が host 側で展開）
    float b[3];
    float4 sourceRect; // 取り込み域（cleanAperture を uv で。05 §6）
    float4 destRect;   // 出力内の letterbox 矩形（normalized [x,y,w,h]。05 §6）
};

fragment float4 rv_colorConvert_v1(const VSOut in [[stage_in]],
                                 constant ColorParams& p [[buffer(0)]],
                                 texture2d<float> yTex [[texture(0)]],
                                 texture2d<float> uvTex [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
    float2 q = (in.uv - p.destRect.xy) / p.destRect.zw;
    float2 suv = p.sourceRect.xy + q * p.sourceRect.zw;
    float y = yTex.sample(s, suv).r;
    float2 cbcr = uvTex.sample(s, suv).rg;
    float3 ycb = float3(y, cbcr.x, cbcr.y);
    float3 rgb;
    rgb.r = dot(float3(p.m[0], p.m[1], p.m[2]), ycb) + p.b[0];
    rgb.g = dot(float3(p.m[3], p.m[4], p.m[5]), ycb) + p.b[1];
    rgb.b = dot(float3(p.m[6], p.m[7], p.m[8]), ycb) + p.b[2];
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// ---------- deinterlace: bob（safe 側。各 field を full height へ） ----------
// 入力: r8(Y, WxH), rg8(UV, W/2 x H/2)（weave 済み: 走査線が field 交互）。
// 出力: 同じ寸法の progressive Y/UV。topFieldFirst=true: 符号列 0 = 上 field。
// 表示行 y（0..H-1）は field 線 k=y/2 を 2 倍したもの:
//   top-first:    源行 = (y/2)*2
//   bottom-first: 上 field は奇数列に格納（PCE tff=0。実 fixture はすべてこれ — 04 §3）なので
//                 源行 = (y/2)*2 + 1
// chroma はそのまま通す（4:2:0 の chroma は field 共有。bob で chroma の動きは作らない）。
// function constant は program scope の定数宣言でなければならない（MSL の制約。実測）。

constant bool topFieldFirst [[function_constant(0)]];

kernel void rv_deint_bob_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                            texture2d<float, access::read>  inUV [[texture(1)]],
                            texture2d<float, access::write> outY [[texture(2)]],
                            texture2d<float, access::write> outUV [[texture(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint w = outY.get_width();
    uint h = outY.get_height();
    if (gid.x >= w || gid.y >= h) return;
    uint srcRow = (gid.y / 2u) * 2u + (topFieldFirst ? 0u : 1u);
    float v = inY.read(uint2(gid.x, srcRow)).r;
    outY.write(float4(v, 0.0, 0.0, 1.0), gid);
    if (gid.x < w / 2u && gid.y < h / 2u) {
        outUV.write(inUV.read(uint2(gid.x, gid.y)), uint2(gid.x, gid.y));
    }
}

// ---------- deinterlace: edge-directed（空間方向・単一フレームのみ。05 §5.2） ----------
//
// 偶数行は保持（一方の field の線そのまま）。奇数行（他 field が来る線）は源の値を
// 使わず、保持 field の上下線（y-1, y+1）からの「対称 2 点内挿」で埋める:
//   対 (x+a, y-1), (x-a, y+1) を結ぶ線分の中点は必ず (x, y) を通る。
//   a を -4..+4 で走らせ、両端の画素値の差が最小（= 一本の辺を跨ぐ対）a を選ぶ。
// 等速で動く斜 edge では選ばれる a が実際の傾きに一致し、simple average の
// gray fringe（comb 低減が働かない）が出ない。平坦部は a の選びようと同じ値 → 無変化。
// 結果は常に 2 点の中間値なので overshoot 無し。chroma は源のまま（補間しない）。

kernel void rv_deint_edgeDirected_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                                     texture2d<float, access::read>  inUV [[texture(1)]],
                                     texture2d<float, access::write> outY [[texture(2)]],
                                     texture2d<float, access::write> outUV [[texture(3)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    uint w = outY.get_width();
    uint h = outY.get_height();
    if (gid.x >= w || gid.y >= h) return;
    bool keepRow = (gid.y & 1u) == 0u;   // 偶数行は保持（源の field 線）
    if (keepRow) {
        outY.write(inY.read(gid), gid);
    } else {
        int x = int(gid.x), y = int(gid.y);
        int W = int(w) - 1, H = int(h) - 1;
        int yu = max(y - 1, 0), yd = min(y + 1, H);   // 保持 field の隣接線（y は奇数 → 偶数行）
        int bestA = 0;
        float bestCost = 1e30;
        for (int a = -4; a <= 4; a++) {
            float vu = inY.read(uint2(clamp(x + a, 0, W), yu)).r;
            float vd = inY.read(uint2(clamp(x - a, 0, W), yd)).r;
            float cost = fabs(vu - vd);
            if (cost < bestCost) { bestCost = cost; bestA = a; }
        }
        float vu = inY.read(uint2(clamp(x + bestA, 0, W), yu)).r;
        float vd = inY.read(uint2(clamp(x - bestA, 0, W), yd)).r;
        outY.write(float4((vu + vd) * 0.5, 0.0, 0.0, 1.0), gid);
    }
    if (gid.x < w / 2u && gid.y < h / 2u) {
        outUV.write(inUV.read(uint2(gid.x, gid.y)), uint2(gid.x, gid.y));
    }
}

// ---------- field 間 SAD（05 §5.1 detector: 1 枚内の 2 field 差分 = comb 信号） ----------
// 8x8 block ごとに、相邻走査線（= 2 つの field 同士の対応線）の平均絶対差を算出。
// 値は正規化 [0,1] のまま（GPU 内完結。判定閾値は host 側の detector が決める — #5 次増分）。
// vector 型を buffer 引数に取るなら参照（constant T&）でなければならない（MSL の制約。実測）。

kernel void rv_fieldMatch_sad_v1(texture2d<float, access::read> inY [[texture(0)]],
                                 device float* blockSAD [[buffer(0)]],
                                 constant uint2& blocks [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= blocks.x || gid.y >= blocks.y) return;
    float sum = 0.0;
    uint x0 = gid.x * 8u, y0 = gid.y * 16u;
    uint W = inY.get_width(), H = inY.get_height();
    for (uint dy = 0; dy < 16u; dy += 2u) {
        uint yt = y0 + dy;
        uint yb = yt + 1u;
        if (yb >= H) break;
        for (uint dx = 0; dx < 8u; dx++) {
            uint xt = x0 + dx;
            if (xt >= W) break;
            sum += fabs(inY.read(uint2(xt, yt)).r - inY.read(uint2(xt, yb)).r);
        }
    }
    blockSAD[gid.y * blocks.x + gid.x] = sum / 64.0;
}
""";
}
