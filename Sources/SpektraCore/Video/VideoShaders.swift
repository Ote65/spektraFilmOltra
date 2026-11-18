import Foundation

/// MSL 源码，运行时 makeLibrary，避免 .metal 构建集成（方案 2.1）。
///
/// kernel 链：
///   develop：BGRA(Rec.709 display) → EOTF → 线性 ProPhoto →
///            t1→相机EV→t2→密度域颗粒→t3→印相EV→t4 → 线性 sRGB
///   bloomDownsample / bloomH / bloomV：半分辨率光晕/柔光金字塔
///   composite：bloom 合成 + 扫描 USM + Rec.709 OETF → BGRA8
enum VideoShaders {
    static let source: String = """
    #include <metal_stdlib>
    using namespace metal;

    // ---- 三线性查表，与 CPU lookupInPlace 的分解顺序完全一致 ----
    // packLUT 布局：3D 纹理 (x=b, y=g, z=r)，值与 CPU ((r*n+g)*n+b)*3+c 对齐。
    static inline float3 lutSample(texture3d<float, access::read> lut,
                                   uint n, float3 c) {
        // c = (r, g, b)；packLUT 把 b 放 width、g 放 height、r 放 depth，
        // 故纹理坐标 tex(x=b, y=g, z=r)。
        float3 x = clamp(c, 0.0f, 1.0f) * float(n - 1);
        uint r0 = uint(floor(x.x)), g0 = uint(floor(x.y)), b0 = uint(floor(x.z));
        uint r1 = min(r0 + 1u, n - 1u), g1 = min(g0 + 1u, n - 1u), b1 = min(b0 + 1u, n - 1u);
        float fr = x.x - float(r0), fg = x.y - float(g0), fb = x.z - float(b0);

        float3 v000 = lut.read(uint3(b0, g0, r0)).rgb;
        float3 v100 = lut.read(uint3(b0, g0, r1)).rgb; // r+1
        float3 v010 = lut.read(uint3(b0, g1, r0)).rgb; // g+1
        float3 v110 = lut.read(uint3(b0, g1, r1)).rgb;
        float3 v001 = lut.read(uint3(b1, g0, r0)).rgb; // b+1
        float3 v101 = lut.read(uint3(b1, g0, r1)).rgb;
        float3 v011 = lut.read(uint3(b1, g1, r0)).rgb;
        float3 v111 = lut.read(uint3(b1, g1, r1)).rgb;

        // 与 CPU lookupInPlace 相同的最大分量优先三线性分解。
        float3 value;
        if (fr > fg) {
            if (fg > fb) {
                value = v000 + fr*(v100-v000) + fg*(v110-v100) + fb*(v111-v110);
            } else if (fr > fb) {
                value = v000 + fr*(v100-v000) + fb*(v101-v100) + fg*(v111-v101);
            } else {
                value = v000 + fb*(v001-v000) + fr*(v101-v001) + fg*(v111-v101);
            }
        } else {
            if (fb > fg) {
                value = v000 + fb*(v001-v000) + fg*(v011-v001) + fr*(v111-v011);
            } else if (fb > fr) {
                value = v000 + fb*(v001-v000) + fr*(v101-v001) + fg*(v111-v101);
            } else {
                value = v000 + fg*(v010-v000) + fr*(v110-v010) + fb*(v111-v110);
            }
        }
        return value; // 不 clamp：t4 输出线性 sRGB 可能 >1，与 CPU predict 一致。
    }

    static inline float3 t1Shaped(float3 v, float autoEV, float loEV, float invSpan) {
        float3 p = max(v, 1e-10f);
        return clamp((log2(p) + autoEV - loEV) * invSpan, 0.0f, 1.0f);
    }

    // Rec.709 EOTF（与 sRGB 同形）+ 线性矩阵 → 线性 ProPhoto。
    static inline float3 displayToLinearProPhoto(float3 srgb, float3 m0, float3 m1, float3 m2) {
        float3 lin;
        lin.r = srgb.r <= 0.04045f ? srgb.r / 12.92f : pow((srgb.r + 0.055f)/1.055f, 2.4f);
        lin.g = srgb.g <= 0.04045f ? srgb.g / 12.92f : pow((srgb.g + 0.055f)/1.055f, 2.4f);
        lin.b = srgb.b <= 0.04045f ? srgb.b / 12.92f : pow((srgb.b + 0.055f)/1.055f, 2.4f);
        // m0/m1/m2 是矩阵的列；M*v = col0*v.x + col1*v.y + col2*v.z。
        // 不能用 dot(col, v)，那会把通道串位。
        return m0 * lin.x + m1 * lin.y + m2 * lin.z;
    }

    // ---- 密度域颗粒：整数哈希 + 逐帧种子 ----
    // 关键点：帧种子是 uint32（可达几十亿），绝不能先转 float 再 fract——
    // float32 在 2^31 量级的 ULP≈256，fract 后只剩 1/256 粗台阶，
    // 相邻帧会 hash 成同一个值，颗粒就退化成静态贴层。用整数位混合保证逐帧独立。
    static inline uint hashU32(uint x, uint y, uint seed) {
        uint h = x * 374761393u + y * 668265263u + seed * 2246822519u;
        h = (h ^ (h >> 13u)) * 1274126177u;
        return h ^ (h >> 16u);
    }
    static inline float hash21(int2 cell, uint seed) {
        uint h = hashU32(uint(cell.x), uint(cell.y), seed);
        return float(h) * (1.0f / 4294967296.0f);
    }
    static inline float valueNoise(float2 p, uint seed) {
        float2 fl = floor(p), f = fract(p);
        int2 i = int2(fl);
        float2 u = f*f*(3.0f - 2.0f*f);
        float a = hash21(i, seed);
        float b = hash21(i + int2(1,0), seed);
        float c = hash21(i + int2(0,1), seed);
        float d = hash21(i + int2(1,1), seed);
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }

    struct FrameParams {
        uint   lutSize;          // 0
        float  shaperLoEV;       // 4
        float  invSpan1;         // 8
        float  encodedMax;       // 12
        bool   encodedInput;     // 16
        float  autoEV;           // 20
        float  cameraOffset;     // 24
        float  printOffset;      // 28
        float  grainSigma;       // 32
        uint   frameSeed;        // 36
        float  grainR;           // 40
        float  grainG;           // 44
        float  grainB;           // 48
        float  densMinR;         // 52
        float  densMinG;         // 56
        float  densMinB;         // 60
        float  halation;         // 64
        float  diffusion;        // 68
        float  usm;              // 72
        float  padA;             // 76
        float3 m0;               // 80
        float3 m1;               // 96
        float3 m2;               // 112
        float3 tint;             // 128
        uint   width;            // 140
        uint   height;           // 144
        uint   padB;             // 148
        uint   padC;             // 152
        // ---- 显影 / 影调（显示域后处理，不参与 LUT 烘焙）----
        float  developStrength;  // 156  1 = 全显影，0 = 原片
        float  dynamicRange;     // 160  胶片宽容度补偿（进入胶片响应前）
        float  gradeShadows;     // 164  -1…1
        float  gradeHighlights;  // 168  -1…1
        float  gradeBlacks;      // 172  -1…1
        float  gradeWhites;      // 176  -1…1
        float  gradeContrast;    // 180  -1…1
        float  gradeSaturation;  // 184  1 = 原样
        float  grainPixelScale;  // 188  渲染像素 / 成片像素（预览降分辨率时补偿高频颗粒尺度）
        float  gradeTemperature; // 192  -1…1，正值偏暖
    };

    kernel void develop(
        texture2d<float, access::read>  inTex  [[texture(0)]],
        texture2d<float, access::write> outTex [[texture(1)]],
        texture3d<float, access::read>  t1 [[texture(2)]],
        texture3d<float, access::read>  t2 [[texture(3)]],
        texture3d<float, access::read>  t3 [[texture(4)]],
        texture3d<float, access::read>  t4 [[texture(5)]],
        constant FrameParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        // bgra8Unorm 采样返回逻辑 RGBA，故 .rgb 即显示编码 Rec.709。
        float3 display = inTex.read(gid).rgb;
        float3 c = displayToLinearProPhoto(display, p.m0, p.m1, p.m2);

        // 动态范围（胶片宽容度）：在进入 t1 之前做软压缩。
        // 视频源本身已经过一次显示编码，再叠胶片/相纸 S 曲线会把两端直接削平；
        // 这里按 log2 亮度做遮罩，只压高光、抬阴影，中灰不动，因此不会整片发灰。
        if (p.dynamicRange > 0.001f) {
            float lum = max(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), 1e-8f);
            float lg = log2(lum);
            float hiMask = smoothstep(-2.2f, 0.2f, lg);
            float loMask = 1.0f - smoothstep(-7.5f, -2.6f, lg);
            float gain = (1.0f + p.dynamicRange * 0.90f * loMask)
                       * (1.0f - p.dynamicRange * 0.60f * hiMask);
            c *= gain;
        }

        float3 t1in = p.encodedInput
            ? clamp(c * (exp2(p.autoEV) / p.encodedMax), 0.0f, 1.0f)
            : t1Shaped(c, p.autoEV, p.shaperLoEV, p.invSpan1);
        c = lutSample(t1, p.lutSize, t1in);
        c = clamp(c + p.cameraOffset, 0.0f, 1.0f);
        c = lutSample(t2, p.lutSize, c);

        float3 amp = float3(p.grainR, p.grainG, p.grainB);
        if (amp.r + amp.g + amp.b > 0.0f) {
            float3 dmin = float3(p.densMinR, p.densMinG, p.densMinB);
            float3 e = clamp((c - dmin) / max(1.0f - dmin, 1e-3f), 0.0f, 1.0f);
            e = 4.0f * e * (1.0f - e); // 中密度峰值
            float2 px = float2(gid);
            // 高频层的格子按「渲染像素 ÷ 成片像素」缩放：1/2 预览下格宽 0.5px，
            // 放大到屏幕后与成片 1px 颗粒同尺度。不补偿的话低分辨率预览会把颗粒看粗一倍。
            float2 hp = px / max(p.grainPixelScale, 0.25f);
            float3 g = float3(
                valueNoise(hp, p.frameSeed) - 0.5f
                  + 0.7f * (valueNoise(px / max(p.grainSigma,0.5f) + 17.0f, p.frameSeed+1u) - 0.5f),
                valueNoise(hp + 7.0f, p.frameSeed+3u) - 0.5f
                  + 0.7f * (valueNoise(px / max(p.grainSigma,0.5f) + 29.0f, p.frameSeed+1u) - 0.5f),
                valueNoise(hp + 13.0f, p.frameSeed+5u) - 0.5f
                  + 0.7f * (valueNoise(px / max(p.grainSigma,0.5f) + 41.0f, p.frameSeed+1u) - 0.5f)
            );
            c = clamp(c + g * amp * e, 0.0f, 1.0f);
        }

        c = lutSample(t3, p.lutSize, c);
        c = clamp(c + p.printOffset, 0.0f, 1.0f);
        c = lutSample(t4, p.lutSize, c);
        outTex.write(float4(c, 1.0f), gid);
    }

    kernel void bloomDownsample(
        texture2d<float, access::read>  inTex [[texture(0)]],
        texture2d<float, access::write> outTex [[texture(1)]],
        constant FrameParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint2 lo = uint2(gid.x > 0 ? gid.x-1 : 0, gid.y > 0 ? gid.y-1 : 0);
        uint2 hi = uint2(min(gid.x+1, p.width-1u), min(gid.y+1, p.height-1u));
        float3 avg = (inTex.read(lo).rgb + inTex.read(hi).rgb
                    + inTex.read(uint2(lo.x,hi.y)).rgb + inTex.read(uint2(hi.x,lo.y)).rgb) * 0.25f;
        float lum = dot(avg, float3(0.2126f, 0.7152f, 0.0722f));
        float t = clamp((lum - 0.6f) / 0.4f, 0.0f, 1.0f);
        t = t*t*(3.0f - 2.0f*t);
        outTex.write(float4(avg * t, 1.0f), gid);
    }

    kernel void bloomH(
        texture2d<float, access::read>  inTex [[texture(0)]],
        texture2d<float, access::write> outTex [[texture(1)]],
        constant FrameParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        float w0=0.227027f, w1=0.1945946f, w2=0.1216216f, w3=0.054054f, w4=0.016216f;
        float3 sum = inTex.read(gid).rgb * w0;
        for (int i = 1; i <= 4; ++i) {
            uint x1 = min(gid.x + uint(i), p.width - 1u);
            uint x0 = (gid.x >= uint(i)) ? gid.x - uint(i) : 0u;
            float wi = (i==1)?w1:((i==2)?w2:((i==3)?w3:w4));
            sum += inTex.read(uint2(x1, gid.y)).rgb * wi;
            sum += inTex.read(uint2(x0, gid.y)).rgb * wi;
        }
        outTex.write(float4(sum, 1.0f), gid);
    }

    kernel void bloomV(
        texture2d<float, access::read>  inTex [[texture(0)]],
        texture2d<float, access::write> outTex [[texture(1)]],
        constant FrameParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        float w0=0.227027f, w1=0.1945946f, w2=0.1216216f, w3=0.054054f, w4=0.016216f;
        float3 sum = inTex.read(gid).rgb * w0;
        for (int i = 1; i <= 4; ++i) {
            uint y1 = min(gid.y + uint(i), p.height - 1u);
            uint y0 = (gid.y >= uint(i)) ? gid.y - uint(i) : 0u;
            float wi = (i==1)?w1:((i==2)?w2:((i==3)?w3:w4));
            sum += inTex.read(uint2(gid.x, y1)).rgb * wi;
            sum += inTex.read(uint2(gid.x, y0)).rgb * wi;
        }
        outTex.write(float4(sum, 1.0f), gid);
    }

    static inline float3 bloomBilinear(texture2d<float, access::read> t, float2 uv, uint2 size) {
        float2 pos = uv * float2(size) - 0.5f;
        uint2 i = uint2(floor(pos));
        float2 f = fract(pos);
        uint2 lo = uint2(clamp(i.x, 0u, size.x - 1u), clamp(i.y, 0u, size.y - 1u));
        uint2 hi = uint2(min(lo.x+1u,size.x-1u), min(lo.y+1u,size.y-1u));
        float3 a = mix(t.read(lo).rgb, t.read(uint2(hi.x,lo.y)).rgb, f.x);
        float3 b = mix(t.read(uint2(lo.x,hi.y)).rgb, t.read(hi).rgb, f.x);
        return mix(a, b, f.y);
    }

    kernel void composite(
        texture2d<float, access::read>  base  [[texture(0)]],
        texture2d<float, access::read>  bloom [[texture(1)]],
        texture2d<float, access::write> outTex [[texture(2)]],
        texture2d<float, access::read>  srcRef [[texture(3)]],
        constant FrameParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        float3 c = base.read(gid).rgb;

        if (p.usm > 0.0f) {
            uint2 lo = uint2(gid.x > 0 ? gid.x-1 : 0, gid.y > 0 ? gid.y-1 : 0);
            uint2 hi = uint2(min(gid.x+1,p.width-1u), min(gid.y+1,p.height-1u));
            float3 blur = (base.read(uint2(gid.x,lo.y)).rgb + base.read(uint2(gid.x,hi.y)).rgb
                         + base.read(uint2(lo.x,gid.y)).rgb + base.read(uint2(hi.x,gid.y)).rgb
                         + base.read(lo).rgb + base.read(hi).rgb
                         + base.read(uint2(hi.x,lo.y)).rgb + base.read(uint2(lo.x,hi.y)).rgb) * 0.125f;
            c += (c - blur) * p.usm;
        }

        if (p.halation + p.diffusion > 0.0f) {
            float2 uv = (float2(gid) + 0.5f) / float2(p.width, p.height);
            float3 b = bloomBilinear(bloom, uv, uint2(p.width/2u > 0u ? p.width/2u : 1u,
                                                       p.height/2u > 0u ? p.height/2u : 1u));
            c += b * p.tint * (p.halation + p.diffusion);
        }

        c = clamp(c, 0.0f, 1.0f);
        float3 disp;
        disp.r = c.r <= 0.0031308f ? c.r * 12.92f : 1.055f * pow(c.r, 1.0f/2.4f) - 0.055f;
        disp.g = c.g <= 0.0031308f ? c.g * 12.92f : 1.055f * pow(c.g, 1.0f/2.4f) - 0.055f;
        disp.b = c.b <= 0.0031308f ? c.b * 12.92f : 1.055f * pow(c.b, 1.0f/2.4f) - 0.055f;

        // ---- 显影强度：与原始帧混合。0 = 完全原片，1 = 完整显影。----
        // 放在显示域混合，明度过渡最接近"不透明度"，不会在中灰出现色偏。
        if (p.developStrength < 0.999f) {
            float3 orig = srcRef.read(gid).rgb;
            disp = mix(orig, disp, clamp(p.developStrength, 0.0f, 1.0f));
        }

        // ---- 黑色 / 白色点：重新标定显示域端点 ----
        float lo = -p.gradeBlacks * 0.12f;
        float hi = 1.0f - p.gradeWhites * 0.12f;
        disp = (disp - lo) / max(hi - lo, 0.35f);

        // ---- 阴影 / 高光：按亮度的软蒙版，色相不变 ----
        float3 lw = float3(0.2126f, 0.7152f, 0.0722f);
        float luma = dot(disp, lw);
        float shadowMask = 1.0f - smoothstep(0.02f, 0.62f, luma);
        float highlightMask = smoothstep(0.38f, 0.98f, luma);
        disp += p.gradeShadows * 0.28f * shadowMask;
        disp += p.gradeHighlights * 0.28f * highlightMask;

        // ---- 对比：以 0.5 中灰为轴 ----
        disp = (disp - 0.5f) * (1.0f + p.gradeContrast * 0.7f) + 0.5f;

        // ---- 饱和度：按 Rec.709 亮度做保真混合 ----
        float luma2 = dot(disp, lw);
        disp = mix(float3(luma2), disp, max(p.gradeSaturation, 0.0f));

        // ---- 印相冷暖：显示域 R/B 互补增益，中灰亮度基本不变 ----
        if (abs(p.gradeTemperature) > 0.001f) {
            disp.r *= 1.0f + p.gradeTemperature * 0.12f;
            disp.b *= 1.0f - p.gradeTemperature * 0.12f;
        }

        outTex.write(float4(clamp(disp, 0.0f, 1.0f), 1.0f), gid);
    }
    """
}
