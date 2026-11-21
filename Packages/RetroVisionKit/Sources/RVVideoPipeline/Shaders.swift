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

// ---------- RGB texture の提示（AI 段の後の最終 scale。letterbox は destRect） ----------

fragment float4 rv_rgbPresent_v1(const VSOut in [[stage_in]],
                                 constant float4& destRect [[buffer(0)]],
                                 texture2d<float> rgb [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
    float2 q = (in.uv - destRect.xy) / destRect.zw;
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) { return float4(0.0, 0.0, 0.0, 1.0); }
    return float4(rgb.sample(s, q).rgb, 1.0);
}

// ---------- RGB の最終拡大 v2（設計 11 §5.6。AI 段の後 / RGB 経路の最終 scale） ----------
//
// 軸ごとに倍率で核を選ぶ: 拡大（invScale <= 1）は Catmull-Rom（4 tap）、縮小は三角（tent）核を
// 倍率に合わせて広げる（半径 = invScale 画素。1 回の bilinear sample では縮小で縞・モアレが出る —
// PAL を 1080p に出すときの縦 0.9375 倍など）。重みは正規化する。片側の tap は 4 まで（縮小 1/4 まで正確）。
// 8 bit の drawable へ書くので、量子化の段差を崩す ±0.5 LSB の ordered noise を足す（dither フラグ）。

struct RGBPresentParams {
    float4 destRect;
    float2 invScale;   // 出力 1 画素あたりの入力画素数（軸ごと）
    uint dither;
    uint pad;
};

static float rv_catmullRom(float x) {
    x = fabs(x);
    if (x < 1.0) { return 1.5 * x * x * x - 2.5 * x * x + 1.0; }
    if (x < 2.0) { return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0; }
    return 0.0;
}

static float rv_resampleWeight(float d, float invScale) {
    if (invScale <= 1.0) { return rv_catmullRom(d); }
    return max(0.0, 1.0 - fabs(d) / invScale);
}

fragment float4 rv_rgbPresent_v2(const VSOut in [[stage_in]],
                                 constant RGBPresentParams& p [[buffer(0)]],
                                 texture2d<float, access::read> rgb [[texture(0)]]) {
    float2 q = (in.uv - p.destRect.xy) / p.destRect.zw;
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) { return float4(0.0, 0.0, 0.0, 1.0); }
    float2 size = float2(rgb.get_width(), rgb.get_height());
    float2 pos = q * size - 0.5;
    float2 radius = float2(p.invScale.x <= 1.0 ? 2.0 : min(p.invScale.x, 4.0),
                           p.invScale.y <= 1.0 ? 2.0 : min(p.invScale.y, 4.0));
    int2 lo = int2(ceil(pos - radius)), hi = int2(floor(pos + radius));
    int2 maxC = int2(size) - 1;
    float3 acc = float3(0.0);
    float wsum = 0.0;
    for (int j = lo.y; j <= hi.y; j++) {
        float wy = rv_resampleWeight(float(j) - pos.y, p.invScale.y);
        if (wy == 0.0) { continue; }
        for (int i = lo.x; i <= hi.x; i++) {
            float wx = rv_resampleWeight(float(i) - pos.x, p.invScale.x);
            if (wx == 0.0) { continue; }
            int2 c = clamp(int2(i, j), int2(0), maxC);
            acc += wx * wy * rgb.read(uint2(c)).rgb;
            wsum += wx * wy;
        }
    }
    float3 c = acc / max(wsum, 1e-6);
    if (p.dither != 0u) {
        float n = fract(52.9829189 * fract(dot(in.pos.xy, float2(0.06711056, 0.00583715))));
        c += (n - 0.5) / 255.0;
    }
    return float4(clamp(c, 0.0, 1.0), 1.0);
}

// ---------- SR の 16 bit テンソル（NCHW planar）の詰め込み / 展開（設計 11 §5.4） ----------
//
// テンソル texture は r16Float、幅 W × 高さ 3H（R の面・G の面・B の面を縦に積む）。

kernel void rv_pack_nchw_f16_v1(texture2d<float, access::read>  rgb    [[texture(0)]],
                                texture2d<float, access::write> tensor [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    uint w = rgb.get_width(), h = rgb.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float3 c = rgb.read(gid).rgb;
    tensor.write(float4(c.r), uint2(gid.x, gid.y));
    tensor.write(float4(c.g), uint2(gid.x, gid.y + h));
    tensor.write(float4(c.b), uint2(gid.x, gid.y + 2u * h));
}

kernel void rv_unpack_nchw_f16_v1(texture2d<float, access::read>  tensor [[texture(0)]],
                                  texture2d<float, access::write> rgb    [[texture(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    uint w = rgb.get_width(), h = rgb.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float r = tensor.read(uint2(gid.x, gid.y)).r;
    float g = tensor.read(uint2(gid.x, gid.y + h)).r;
    float b = tensor.read(uint2(gid.x, gid.y + 2u * h)).r;
    rgb.write(float4(clamp(float3(r, g, b), 0.0, 1.0), 1.0), gid);
}

// ---------- SR のタイル（設計 11 §5.4、D4 の予備）: 切り出しと重みつき合成（GPU） ----------
//
// 切り出し: 全画面のテンソル（W×3H）から、(x, y) を左上とするタイル（tw×3th）を写す。
// 合成: 各タイルの出力（tw·s × 3·th·s）を、出力全体の累積 texture（rgba32Float: rgb = Σ w·値、a = Σ w）へ
// 足し込む。重みは TilePlan.axisWeight と同じ（隣と重なる側だけ、重なり幅で 0→1）。タイルごとの dispatch は
// 同じ encoder 内で直列に実行される（既定の serial dispatch）。最後に正規化して planar のテンソルへ書く。

struct TensorTileParams {
    uint2 origin;      // 出力全体での左上（出力 px）
    uint2 size;        // タイルの出力寸法
    uint4 neighbours;  // x: 左あり、y: 右あり、z: 上あり、w: 下あり
    uint ramp;         // 重なり幅（出力 px）
    uint pad0, pad1, pad2;
};

kernel void rv_tensor_crop_v1(texture2d<float, access::read>  src  [[texture(0)]],
                              texture2d<float, access::write> tile [[texture(1)]],
                              constant uint2& origin [[buffer(0)]],
                              constant uint2& srcSize [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint tw = tile.get_width(), th = tile.get_height() / 3u;
    if (gid.x >= tw || gid.y >= th) return;
    for (uint c = 0; c < 3u; c++) {
        float v = src.read(uint2(origin.x + gid.x, c * srcSize.y + origin.y + gid.y)).r;
        tile.write(float4(v), uint2(gid.x, c * th + gid.y));
    }
}

static float rv_tileAxisWeight(uint u, uint length, bool hasPrev, bool hasNext, uint ramp) {
    float r = float(max(ramp, 1u)) + 1.0;
    float w = 1.0;
    if (hasPrev) { w = min(w, float(u + 1u) / r); }
    if (hasNext) { w = min(w, float(length - u) / r); }
    return w;
}

kernel void rv_tensor_tile_accumulate_v1(texture2d<float, access::read>       tile [[texture(0)]],
                                         texture2d<float, access::read_write> acc  [[texture(1)]],
                                         constant TensorTileParams& p [[buffer(0)]],
                                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.size.x || gid.y >= p.size.y) return;
    float w = rv_tileAxisWeight(gid.x, p.size.x, p.neighbours.x != 0u, p.neighbours.y != 0u, p.ramp)
            * rv_tileAxisWeight(gid.y, p.size.y, p.neighbours.z != 0u, p.neighbours.w != 0u, p.ramp);
    float3 v = float3(tile.read(uint2(gid.x, gid.y)).r,
                      tile.read(uint2(gid.x, p.size.y + gid.y)).r,
                      tile.read(uint2(gid.x, 2u * p.size.y + gid.y)).r);
    uint2 o = p.origin + gid;
    float4 cur = acc.read(o);
    acc.write(float4(cur.rgb + w * v, cur.a + w), o);
}

kernel void rv_tensor_tile_resolve_v1(texture2d<float, access::read>  acc [[texture(0)]],
                                      texture2d<float, access::write> out [[texture(1)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    uint w = acc.get_width(), h = acc.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 a = acc.read(gid);
    float3 v = a.a > 0.0 ? a.rgb / a.a : float3(0.0);
    out.write(float4(v.r), uint2(gid.x, gid.y));
    out.write(float4(v.g), uint2(gid.x, gid.y + h));
    out.write(float4(v.b), uint2(gid.x, gid.y + 2u * h));
}

// ---------- オーバーレイ（字幕・メニューのハイライト）: premultiplied の BGRA を映像の上に重ねる ----------
//
// 映像と同じ幾何（取り込み域 = sourceRect、目標比率の枠 = destRect）で重ねるので、画面の座標系の絵
// （DVD の SPU は coded frame の 720x480）が映像に合う。ブレンドは pipeline 側（src + dst × (1 − srcα)）。

struct OverlayParams {
    float4 sourceRect;
    float4 destRect;
};

fragment float4 rv_overlay_v1(const VSOut in [[stage_in]],
                              constant OverlayParams& p [[buffer(0)]],
                              texture2d<float> overlay [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float2 q = (in.uv - p.destRect.xy) / p.destRect.zw;
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) { return float4(0.0); }
    return overlay.sample(s, p.sourceRect.xy + q * p.sourceRect.zw);
}

// ---------- colorConvert + bicubic（Catmull-Rom。ScaleFilter.highQuality。拡大時のみ使う） ----------
//
// 輝度だけ 4x4 tap の Catmull-Rom で補間する（SD → HD の拡大でエッジを鈍らせない）。
// chroma は 4:2:0 で元々低解像なので linear のまま（bicubic にしても見た目が変わらず tap だけ増える）。
// overshoot は clamp(0,1) で抑える。縮小時は host 側が linear を選ぶ（bicubic は折り返しを強めるため）。

static float4 rv_catmullRomWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t3 + t2 - 0.5 * t,
                  1.5 * t3 - 2.5 * t2 + 1.0,
                  -1.5 * t3 + 2.0 * t2 + 0.5 * t,
                  0.5 * t3 - 0.5 * t2);
}

fragment float4 rv_colorConvert_bicubic_v1(const VSOut in [[stage_in]],
                                           constant ColorParams& p [[buffer(0)]],
                                           texture2d<float> yTex [[texture(0)]],
                                           texture2d<float> uvTex [[texture(1)]],
                                           sampler s [[sampler(0)]]) {
    float2 q = (in.uv - p.destRect.xy) / p.destRect.zw;
    float2 suv = p.sourceRect.xy + q * p.sourceRect.zw;
    float2 size = float2(yTex.get_width(), yTex.get_height());
    float2 pos = suv * size - 0.5;
    float2 base = floor(pos);
    float2 f = pos - base;
    float4 wx = rv_catmullRomWeights(f.x);
    float4 wy = rv_catmullRomWeights(f.y);
    int2 maxC = int2(size) - 1;
    float acc = 0.0;
    for (int j = 0; j < 4; j++) {
        float row = 0.0;
        for (int i = 0; i < 4; i++) {
            int2 c = clamp(int2(base) + int2(i - 1, j - 1), int2(0), maxC);
            row += wx[i] * yTex.read(uint2(c)).r;
        }
        acc += wy[j] * row;
    }
    float y = clamp(acc, 0.0, 1.0);
    float2 cbcr = uvTex.sample(s, suv).rg;
    float3 ycb = float3(y, cbcr.x, cbcr.y);
    float3 rgb;
    rgb.r = dot(float3(p.m[0], p.m[1], p.m[2]), ycb) + p.b[0];
    rgb.g = dot(float3(p.m[3], p.m[4], p.m[5]), ycb) + p.b[1];
    rgb.b = dot(float3(p.m[6], p.m[7], p.m[8]), ycb) + p.b[2];
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// ---------- アーティファクト除去（非 AI。設計 11 §5.2・D1・D11。07 §3） ----------
//
// target ごとに別の kernel。有効なものだけが host から順に呼ばれる（plan の targets）。
// 輝度の全面平滑化はしない（粒子・細部・線画を守る）。
//
// blocking: 符号化座標の 8 px 格子をまたぐ段差だけを均す（H.264 の deblocking と同型）。
//   境界の両側が平らで（|p1-p0|, |q1-q0| が小さい）、段差 |q0-p0| も小さいときだけ。大きい段差は実の縁。
//   direction 0 = 横方向の境界（x 方向に均す）、1 = 縦方向の境界。2 回に分けて呼ぶ。
//   origin = 符号化座標での texture 原点（格子の位相。D11）。

kernel void rv_deblock_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                          texture2d<float, access::write> outY [[texture(1)]],
                          constant float& strength [[buffer(0)]],
                          constant int2&  origin   [[buffer(1)]],
                          constant uint&  direction [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int w = int(outY.get_width());
    int h = int(outY.get_height());
    int x = int(gid.x), y = int(gid.y);
    if (x >= w || y >= h) return;
    float c = inY.read(gid).r;
    bool horiz = (direction == 0);
    int pos = horiz ? x : y;
    int size = horiz ? w : h;
    int phase = horiz ? origin.x : origin.y;
    int k = ((pos + phase) % 8 + 8) % 8;          // 格子内の位置 0...7
    // 近い境界: k <= 1 なら左（上）の境界、k >= 6 なら右（下）の境界。それ以外は触らない。
    int d;          // 境界からの距離（0 = 境界に接する画素, 1 = その隣）
    int qStart;     // 境界の q 側の最初の画素の位置
    bool isQ;
    if (k <= 1) { d = k; qStart = pos - k; isQ = true; }
    else if (k >= 6) { d = 7 - k; qStart = pos + d + 1; isQ = false; }
    else { outY.write(float4(c, 0.0, 0.0, 1.0), gid); return; }
    if (qStart - 2 < 0 || qStart + 1 >= size) { outY.write(float4(c, 0.0, 0.0, 1.0), gid); return; }
    float v[4];
    for (int i = 0; i < 4; i++) {
        int sp = qStart - 2 + i;                  // p1, p0, q0, q1
        v[i] = horiz ? inY.read(uint2(sp, y)).r : inY.read(uint2(x, sp)).r;
    }
    float step = v[2] - v[1];
    float alpha = mix(0.01, 0.08, strength);
    float beta = alpha * 0.5;
    bool blocky = abs(step) < alpha && abs(v[0] - v[1]) < beta && abs(v[3] - v[2]) < beta;
    float weight = (d == 0) ? 0.375 : 0.125;
    float delta = blocky ? weight * step * (isQ ? -1.0 : 1.0) : 0.0;
    // p 側は +step 分だけ q 側へ、q 側は -step 分だけ p 側へ寄せる（delta に符号を含めてある）。
    outY.write(float4(clamp(c + delta, 0.0, 1.0), 0.0, 0.0, 1.0), gid);
}

// ringing: 強い縁から 4 画素以内で、自身は縁ではない画素にだけ、値差の許容を小さくした 5x5 bilateral。
//   縁そのもの・平坦部（粒子）は変えない。
kernel void rv_ringing_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                          texture2d<float, access::write> outY [[texture(1)]],
                          constant float& strength [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int w = int(outY.get_width());
    int h = int(outY.get_height());
    int x = int(gid.x), y = int(gid.y);
    if (x >= w || y >= h) return;
    float c = inY.read(gid).r;
    float maxGrad = 0.0, ownGrad = 0.0;
    for (int dy = -4; dy <= 4; dy++) {
        for (int dx = -4; dx <= 4; dx++) {
            int sx = clamp(x + dx, 0, w - 2), sy = clamp(y + dy, 0, h - 2);
            float a = inY.read(uint2(sx, sy)).r;
            float g = max(abs(inY.read(uint2(sx + 1, sy)).r - a), abs(inY.read(uint2(sx, sy + 1)).r - a));
            maxGrad = max(maxGrad, g);
            if (dx == 0 && dy == 0) ownGrad = g;
        }
    }
    float result = c;
    if (maxGrad > 0.15 && ownGrad < 0.05) {
        float sigmaR = mix(0.01, 0.08, strength);
        float acc = 0.0, wsum = 0.0;
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int sx = clamp(x + dx, 0, w - 1), sy = clamp(y + dy, 0, h - 1);
                float v = inY.read(uint2(sx, sy)).r;
                float dv = v - c;
                float wgt = exp(-float(dx * dx + dy * dy) / 4.5) * exp(-(dv * dv) / (2.0 * sigmaR * sigmaR));
                acc += wgt * v;
                wsum += wgt;
            }
        }
        result = acc / max(wsum, 1e-6);
    }
    outY.write(float4(result, 0.0, 0.0, 1.0), gid);
}

// chromaNoise: 色差の 3x3 bilateral（小振幅の揺らぎ・滲みだけ均す）。輝度には触らない。
kernel void rv_denoise_chroma_v1(texture2d<float, access::read>  inUV  [[texture(0)]],
                                 texture2d<float, access::write> outUV [[texture(1)]],
                                 constant float& strength [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int cw = int(outUV.get_width());
    int ch = int(outUV.get_height());
    int x = int(gid.x), y = int(gid.y);
    if (x >= cw || y >= ch) return;
    float2 c = inUV.read(gid).rg;
    float sigmaC = mix(0.01, 0.12, strength);
    float2 acc = float2(0.0);
    float wsum = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int sx = clamp(x + dx, 0, cw - 1), sy = clamp(y + dy, 0, ch - 1);
            float2 v = inUV.read(uint2(sx, sy)).rg;
            float2 d = v - c;
            float wgt = exp(-float(dx * dx + dy * dy) / 2.0) * exp(-dot(d, d) / (2.0 * sigmaC * sigmaC));
            acc += wgt * v;
            wsum += wgt;
        }
    }
    float2 o = acc / max(wsum, 1e-6);
    outUV.write(float4(o.x, o.y, 0.0, 1.0), gid);
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
    // 色も同じ field の chroma 行だけを行複製する（chroma 行も field 交互。輝度と同じ規則）。
    if (gid.x < w / 2u && gid.y < h / 2u) {
        uint cSrc = min((gid.y / 2u) * 2u + (topFieldFirst ? 0u : 1u), h / 2u - 1u);
        outUV.write(inUV.read(uint2(gid.x, cSrc)), uint2(gid.x, gid.y));
    }
}

// ---------- deinterlace 共通（保持 field・空間内挿） ----------
//
// 保持する field は「フレームの先に撮った field」（top-first なら偶数行、bottom-first なら奇数行）。
// 欠けた行の時間的な推定（前 frame の同じ行と現 frame の同じ行の平均）が、保持 field の時刻を
// 前後から挟む位置になるので、動きに対しても内挿の誤りを抑えられる（yadif と同じ考え方）。
// topFieldFirst は function constant（bob / IVTC と共有。.unknown は top-first 仮定）。

static inline uint rv_keptParity() { return topFieldFirst ? 0u : 1u; }

// 欠けた行 y の保持 field の隣接行（画像の端では反対側の行を使う。自分自身 = 別 field の行は読まない）。
static inline int2 rv_keptNeighbours(int y, int H) {
    return int2(y - 1 >= 0 ? y - 1 : y + 1, y + 1 <= H ? y + 1 : y - 1);
}

// 辺の方向に沿った 2 点内挿（edge-directed）。対 (x+a, yu), (x-a, yd) の中点は必ず (x, y) を通る。
// 費用は 3 画素幅の絶対差の和（1 画素だと細い線で別の線を拾って点線になる）。±5 画素まで探し、
// 同点なら真っすぐ（a = 0）を選ぶよう a の大きさに小さな罰を足す。結果は 2 点の中間値なので overshoot しない。
static float rv_spatialInterp(texture2d<float, access::read> inY, int x, int yu, int yd, int W) {
    int bestA = 0;
    float bestCost = 1e30;
    for (int a = -5; a <= 5; a++) {
        float cost = 0.004 * float(abs(a));
        for (int k = -1; k <= 1; k++) {
            float vu = inY.read(uint2(uint(clamp(x + a + k, 0, W)), uint(yu))).r;
            float vd = inY.read(uint2(uint(clamp(x - a + k, 0, W)), uint(yd))).r;
            cost += fabs(vu - vd);
        }
        if (cost < bestCost) { bestCost = cost; bestA = a; }
    }
    return (inY.read(uint2(uint(clamp(x + bestA, 0, W)), uint(yu))).r
            + inY.read(uint2(uint(clamp(x - bestA, 0, W)), uint(yd))).r) * 0.5;
}

// ---------- deinterlace: edge-directed（空間方向・単一フレームのみ。05 §5.2） ----------
//
// 保持 field の行はそのまま、欠けた行は源の値を使わず保持 field の上下の行から内挿する。
// 等速で動く斜 edge では選ばれる a が実際の傾きに一致し、単純平均の gray fringe が出ない。
// 色は保持 field の chroma 行だけから補間（別の瞬間の色を混ぜない — D8）。

kernel void rv_deint_edgeDirected_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                                     texture2d<float, access::read>  inUV [[texture(1)]],
                                     texture2d<float, access::write> outY [[texture(2)]],
                                     texture2d<float, access::write> outUV [[texture(3)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    uint w = outY.get_width();
    uint h = outY.get_height();
    if (gid.x >= w || gid.y >= h) return;
    int x = int(gid.x), y = int(gid.y);
    int W = int(w) - 1, H = int(h) - 1;
    if ((gid.y & 1u) == rv_keptParity()) {
        outY.write(inY.read(gid), gid);
    } else {
        int2 n = rv_keptNeighbours(y, H);
        outY.write(float4(rv_spatialInterp(inY, x, n.x, n.y, W), 0.0, 0.0, 1.0), gid);
    }
    if (gid.x < w / 2u && gid.y < h / 2u) {
        int cy = int(gid.y), cH = int(h / 2u) - 1;
        float2 c = inUV.read(gid).rg;
        if ((gid.y & 1u) != rv_keptParity()) {
            int2 n = rv_keptNeighbours(cy, cH);
            c = (inUV.read(uint2(gid.x, uint(n.x))).rg + inUV.read(uint2(gid.x, uint(n.y))).rg) * 0.5;
        }
        outUV.write(float4(c.x, c.y, 0.0, 1.0), gid);
    }
}

// ---------- deinterlace: motion-adaptive（時間 + 空間。05 §5.2 の既定。前 frame が要る） ----------
//
// 保持 field の行はそのまま。欠けた行は、
//   空間 S = edge-directed の内挿
//   時間 D = (前 frame の同じ行 + 現 frame の同じ行) / 2（保持 field の時刻の推定）
// を、動きの大きさ diff で挟む: 結果 = clamp(S, D - diff, D + diff)（yadif と同じ形）。
//   - 静止: diff ≈ 0 → D（= 他 field の線そのまま = weave。垂直解像度・静止した細い文字や縞を保つ）
//   - 動き: diff が大きく S がそのまま通る（comb を出さない）。S が D から外れすぎるときだけ D 側へ寄る
//     ので、細い線で内挿の方向を間違えても点線にならない。
// diff は、欠けた行の前 frame との差の半分（= 前後の同 field の差の半分）と、保持 field の
// 前 frame との差の大きい方を、左右 1 画素まで広げて取る（1 画素ごとに切り替わると縞が出る）。

// 動き指標（輝度。前 frame との同位置差を、左右 1 画素・上下の保持行まで広げた 3x3 の最大）。chroma の判定に使う。
static float rv_motionAt(texture2d<float, access::read> inY,
                         texture2d<float, access::read> prevY, int x, int y, int W, int H) {
    int yu = max(y - 1, 0), yd = min(y + 1, H);
    float motion = 0.0;
    for (int dx = -1; dx <= 1; dx++) {
        uint sx = uint(clamp(x + dx, 0, W));
        motion = max(motion, fabs(inY.read(uint2(sx, uint(y))).r - prevY.read(uint2(sx, uint(y))).r));
        motion = max(motion, fabs(inY.read(uint2(sx, uint(yu))).r - prevY.read(uint2(sx, uint(yu))).r));
        motion = max(motion, fabs(inY.read(uint2(sx, uint(yd))).r - prevY.read(uint2(sx, uint(yd))).r));
    }
    return motion;
}

kernel void rv_deint_motionAdaptive_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                                       texture2d<float, access::read>  inUV [[texture(1)]],
                                       texture2d<float, access::write> outY [[texture(2)]],
                                       texture2d<float, access::write> outUV [[texture(3)]],
                                       texture2d<float, access::read>  prevY [[texture(4)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    int w = int(outY.get_width());
    int h = int(outY.get_height());
    int W = w - 1, H = h - 1;
    int x = int(gid.x), y = int(gid.y);
    uint kept = rv_keptParity();
    if (x < w && y < h) {
        if ((uint(y) & 1u) == kept) {
            outY.write(inY.read(gid), gid);
        } else {
            int2 n = rv_keptNeighbours(y, H);
            float spatial = rv_spatialInterp(inY, x, n.x, n.y, W);
            float cur = inY.read(gid).r;
            float temporal = (cur + prevY.read(gid).r) * 0.5;
            float diff = 0.0;
            for (int dx = -1; dx <= 1; dx++) {
                uint sx = uint(clamp(x + dx, 0, W));
                float missing = fabs(inY.read(uint2(sx, uint(y))).r - prevY.read(uint2(sx, uint(y))).r) * 0.5;
                float keptChange = (fabs(inY.read(uint2(sx, uint(n.x))).r - prevY.read(uint2(sx, uint(n.x))).r)
                                    + fabs(inY.read(uint2(sx, uint(n.y))).r - prevY.read(uint2(sx, uint(n.y))).r)) * 0.5;
                diff = max(diff, max(missing, keptChange));
            }
            outY.write(float4(clamp(spatial, temporal - diff, temporal + diff), 0.0, 0.0, 1.0), gid);
        }
    }
    // 色（4:2:0）。インターレースでは chroma の行も field 交互なので、動く画素の色を weave すると
    // 別の瞬間の色が混ざり、動く edge に点線状の色ずれが出る。動く画素は保持 field の chroma だけから
    // 補間する。静止画素は従来どおり weave。
    int cw = int(outUV.get_width());
    int ch = int(outUV.get_height());
    if (x < cw && y < ch) {
        float2 weaveC = inUV.read(gid).rg;
        float2 outC = weaveC;
        if ((uint(y) & 1u) != kept) {
            int2 n = rv_keptNeighbours(y, ch - 1);
            float2 spatialC = (inUV.read(uint2(x, uint(n.x))).rg + inUV.read(uint2(x, uint(n.y))).rg) * 0.5;
            // 対応する輝度位置（2x, 2y の周辺）の動きを使う。
            float k = smoothstep(0.02, 0.07, rv_motionAt(inY, prevY, min(2 * x, W), min(2 * y, H), W, H));
            outC = mix(weaveC, spatialC, k);
        }
        outUV.write(float4(outC.x, outC.y, 0.0, 1.0), gid);
    }
}

// ---------- inverse telecine: field matching（weave 復元。05 §5.1） ----------
//
// 3:2 の縞ありフレーム（周期内位置 2・3）は、隣り合う映画コマの field を 1 つずつ持つ。
// 元のコマは「現 frame の先行 field + 前 frame の後続 field」を行ごとに織る（weave）と復元できる:
//   top-first:    偶数行（top）= 現 frame、奇数行（bottom）= 前 frame
//   bottom-first: 奇数行（bottom）= 現 frame、偶数行（top）= 前 frame
// chroma（4:2:0）も行が field 交互なので同じ規則で織る。この kernel は縞ありと判定された
// frame にだけ host 側が使う（縞なしの frame は weave のまま = 元から正しい）。
// topFieldFirst は function constant（bob と共有。PSO は field 順が変わるときだけ作り直す）。

kernel void rv_ivtc_weave_v1(texture2d<float, access::read>  inY   [[texture(0)]],
                             texture2d<float, access::read>  inUV  [[texture(1)]],
                             texture2d<float, access::write> outY  [[texture(2)]],
                             texture2d<float, access::write> outUV [[texture(3)]],
                             texture2d<float, access::read>  prevY  [[texture(4)]],
                             texture2d<float, access::read>  prevUV [[texture(5)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint w = outY.get_width();
    uint h = outY.get_height();
    // 現 frame から取る行の parity: top-first は偶数行（0）、bottom-first は奇数行（1）。
    uint curParity = topFieldFirst ? 0u : 1u;
    if (gid.x < w && gid.y < h) {
        float v = ((gid.y & 1u) == curParity) ? inY.read(gid).r : prevY.read(gid).r;
        outY.write(float4(v, 0.0, 0.0, 1.0), gid);
    }
    if (gid.x < w / 2u && gid.y < h / 2u) {
        float4 c = ((gid.y & 1u) == curParity) ? inUV.read(gid) : prevUV.read(gid);
        outUV.write(c, gid);
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
