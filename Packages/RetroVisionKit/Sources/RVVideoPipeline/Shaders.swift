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

// ---------- denoise: metalGuided（非 AI。エッジ保存の空間フィルタ。07 §3） ----------
//
// 輝度: 5x5 の bilateral（空間重み × 値差の重み）。値差の sigma を strength で決めるので、
// 強い edge（字幕・線画・顔の輪郭）は値差が大きく平均に入らず保たれ、ブロックノイズ・粒子の
// ような小振幅の揺らぎだけが均される。strength 0 は恒等。
// 色: 3x3 の bilateral（chroma noise・色の滲み。小振幅のみ均す）。
// 時間方向（temporal blend）は前 *出力* が要るため v1 には入れない（ghost を避ける）。

kernel void rv_denoise_metalGuided_v1(texture2d<float, access::read>  inY  [[texture(0)]],
                                      texture2d<float, access::read>  inUV [[texture(1)]],
                                      texture2d<float, access::write> outY [[texture(2)]],
                                      texture2d<float, access::write> outUV [[texture(3)]],
                                      constant float& strength [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    int w = int(outY.get_width());
    int h = int(outY.get_height());
    int x = int(gid.x), y = int(gid.y);
    if (x < w && y < h) {
        float c = inY.read(gid).r;
        float sigmaR = mix(0.01, 0.12, strength);   // 値差の許容（輝度 [0,1]）。強いほど大きい振幅まで均す
        float acc = 0.0, wsum = 0.0;
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int sx = clamp(x + dx, 0, w - 1), sy = clamp(y + dy, 0, h - 1);
                float v = inY.read(uint2(sx, sy)).r;
                float ds = float(dx * dx + dy * dy);
                float dv = v - c;
                float wgt = exp(-ds / 4.5) * exp(-(dv * dv) / (2.0 * sigmaR * sigmaR));
                acc += wgt * v;
                wsum += wgt;
            }
        }
        outY.write(float4(acc / max(wsum, 1e-6), 0.0, 0.0, 1.0), gid);
    }
    int cw = int(outUV.get_width());
    int ch = int(outUV.get_height());
    if (x < cw && y < ch) {
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
    // 色（4:2:0）も field 交互（偶数 chroma 行 = 保持した上 field）。前 frame が無い = 全画素を
    // 「動き」とみなすのと同じで、奇数 chroma 行は保持 field の上下の行から補間する（motion-adaptive の
    // 動く画素と同じ規則。weave すると別の瞬間の色が混ざり、動く edge に点線状の色ずれが出る）。
    if (gid.x < w / 2u && gid.y < h / 2u) {
        int cy = int(gid.y), cH = int(h / 2u) - 1;
        float2 c = inUV.read(gid).rg;
        if ((cy & 1) == 1) {
            float2 up = inUV.read(uint2(gid.x, uint(max(cy - 1, 0)))).rg;
            float2 down = inUV.read(uint2(gid.x, uint(min(cy + 1, cH)))).rg;
            // 下端で奇数行の下が無いときは上の行だけ（cy + 1 > cH なら down は自分 = 別 field なので使わない）
            c = (cy + 1 <= cH) ? (up + down) * 0.5 : up;
        }
        outUV.write(float4(c.x, c.y, 0.0, 1.0), gid);
    }
}

// ---------- deinterlace: motion-adaptive（時間 + 空間。05 §5.2 の既定。前 frame が要る） ----------
//
// 偶数行は保持（edge-directed と同じ）。奇数行（他 field の線）は画素ごとに動きを測り、
//   - 静止: 現 frame の他 field の線をそのまま使う（weave。垂直解像度を保つ — 静止した
//     細い文字・字幕・縞が edge-directed の内挿で崩れない）
//   - 動き: edge-directed の空間内挿（comb を出さない）
// を連続的に混ぜる。動きの指標は「前 frame との同位置の差」を、補間行 y とその上下の
// 保持行 y±1 の 3 点の最大で取る（同 parity 同士の比較なので、field 間の時間差で
// 静止物を動きと誤判定しない）。しきい値は輝度 [0,1] 正規化値（video range の
// 約 7〜23 階調）。前 frame が無い / 寸法が違うときは host 側が edge-directed に倒す。

// 動き指標（輝度。前 frame との同位置差を、左右 1 画素・上下の保持行まで広げた 3x3 の最大）。
// 1 画素ごとに weave / 空間内挿が切り替わると、動く edge に点線状の縞が出る（実盤 ISO で確認）。
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
    if (x < w && y < h) {
        bool keepRow = (y & 1) == 0;
        if (keepRow) {
            outY.write(inY.read(gid), gid);
        } else {
            int yu = max(y - 1, 0), yd = min(y + 1, H);
            // 空間内挿（edge-directed と同じ）
            int bestA = 0;
            float bestCost = 1e30;
            for (int a = -4; a <= 4; a++) {
                float vu = inY.read(uint2(clamp(x + a, 0, W), yu)).r;
                float vd = inY.read(uint2(clamp(x - a, 0, W), yd)).r;
                float cost = fabs(vu - vd);
                if (cost < bestCost) { bestCost = cost; bestA = a; }
            }
            float spatial = (inY.read(uint2(clamp(x + bestA, 0, W), yu)).r
                             + inY.read(uint2(clamp(x - bestA, 0, W), yd)).r) * 0.5;
            float weave = inY.read(gid).r;
            float k = smoothstep(0.02, 0.07, rv_motionAt(inY, prevY, x, y, W, H));
            outY.write(float4(mix(weave, spatial, k), 0.0, 0.0, 1.0), gid);
        }
    }
    // 色（4:2:0）。インターレースでは chroma の行も field 交互（偶数行 = 上 field）なので、
    // 動く画素の色を weave すると別の瞬間の色が混ざり、動く edge に点線状の色ずれが出る
    // （chroma upsampling error）。動く画素は、輝度で保持した field（偶数行）の chroma だけから
    // 補間する。静止画素は従来どおり。
    int cw = int(outUV.get_width());
    int ch = int(outUV.get_height());
    if (x < cw && y < ch) {
        float2 weaveC = inUV.read(gid).rg;
        float2 outC = weaveC;
        if ((y & 1) == 1) {
            float2 up = inUV.read(uint2(x, uint(max(y - 1, 0)))).rg;
            float2 down = inUV.read(uint2(x, uint(min(y + 1, ch - 1)))).rg;
            float2 spatialC = (up + down) * 0.5;
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
