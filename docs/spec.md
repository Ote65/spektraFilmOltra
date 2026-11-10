# Swift 移植第二阶段规格：物理模拟补齐

> 分支：`swift-native`（孤儿分支，禁止合入 Python 分支）。
> 参考实现：`/Users/megmeet/Documents/开发 APP/Spektrafilm`（branch `skin`，只读）。
> 本规格只覆盖「引擎物理链路缺口」，不含 UI 接线、RAW 解码、导出/库管理。

## 1. 现状（已验证）

已完成并与 Python 对拍通过（1e-12）：

- Profile JSON 解析（含 null→NaN）、ColorData、Illuminants、CAT16/CAT02、CCTF、矩阵往返。
- 光谱上采样（hanatos2025）、tc LUT（含输入色域压缩 remap）、3D PCHIP LUT。
- `FilmingStage.expose`：曝光补偿、boost highlights、镜头模糊、halation。
- `PrintingStage.expose`：enlarger 光谱积分 + LUT、midgray 曝光因子、preflash、黑/白参考校正。
- `ScanningStage.scan`：cmy→logXYZ LUT、黑/白 XYZ 校正、XYZ→RGB、模糊 + USM、CCTF 编码。
- 确定性 tap：`rgb_pre` / `log_e_film` / `cmy_film` / `log_e_print` / `cmy_print` / `rgb_out`。

## 2. 缺口（本阶段要补）

| # | 缺口 | Python 参考 | Swift 现状 |
|---|------|-------------|-----------|
| G1 | DIR couplers | `model/couplers.py`、`model/develop.py::develop` | `FilmingStage.develop` 只有 `developSimple` |
| G2 | 颗粒 | `model/grain.py`、`utils/fast_stats.py`、`density_curves.py::interp_density_cmy_layers` | 无 |
| G3 | 扫描眩光 | `model/glare.py` | `ScanningStage.addGlare` 恒等 |
| G4 | 相机/放大机柔光镜 | `model/diffusion.py` 271-642 | `SpatialEffects.diffusionFilter` 恒等 |
| G5 | 印相柔光镜像素尺寸 | `PrintingStage.expose` 传 `resize_service.pixel_size_um` | 传 `nil → 1`（错误） |
| G6 | 输出色域压缩（默认 cam16ucs） | `utils/gamut_compression.py` 1103-1240 + `reinhard_knee`/`_c_max_lookup` | `compressRGB` 恒等 |

## 3. 不变量

1. 任何改动只在 `SpektrafilmSwift` 的 `swift-native` 分支；不触碰 Python 仓库工作区。
2. 物理公式逐行照搬 Python，不改符号、归一化、次序、epsilon。
3. 确定性模块（G1/G5/G6）必须与 Python 对拍至 1e-9；随机模块（G2/G3）按统计量验收（均值/标准差/直方图），因为 Python 侧 numba 并行 RNG 本身不可复现。
4. 不引入第三方依赖；仅 Foundation + Accelerate（vDSP）。
5. 每个缺口独立可回滚：默认参数下关闭（active=false）时链路与现状逐位一致。

## 4. G1：DIR couplers

**新文件** `Sources/SpektraCore/Model/Couplers.swift`，`enum Couplers`。

1. `computeMatrix(_ p: DirCouplersParams) -> [[Double]]`（3×3）
   - `M_self = diag(gammaSameLayerRGB * inhibitionSameLayer)`
   - `M_inter`: `[0][1]=gammaInterlayerRToGB[0]`, `[0][2]=gammaInterlayerRToGB[1]`,
     `[1][0]=gammaInterlayerGToRB[0]`, `[1][2]=gammaInterlayerGToRB[1]`,
     `[2][0]=gammaInterlayerBToRG[0]`, `[2][1]=gammaInterlayerBToRG[1]`，整体乘 `inhibitionInterlayer`
   - 返回 `M_self + M_inter`（调用方再乘 `amount`）。
2. `curvesBeforeCouplers(densityCurves:[[Double]], logExposure:[Double], matrix:[[Double]], positive:Bool) -> [[Double]]`
   - `silver = positive ? nanmaxPerChannel(densityCurves) - densityCurves : densityCurves`
   - `couplersAmount[j][m] = Σ_k silver[j][k] * matrix[k][m]`
   - `logExposure0[j][m] = logExposure[j] - couplersAmount[j][m]`
   - 每通道：positive → `-interp(logExposure, logExposure0[:,i], -densityCurves[:,i])`，否则 `interp(... , densityCurves)`
   - `interp` 必须是 numpy `np.interp` 语义（升序 x、端点夹取、NaN 处理与既有 `Interpolation` 一致）。若 `logExposure0` 非严格升序，按 numpy 行为逐段线性（不排序、不假设单调）。
3. `exposureCorrection(logRaw:ImageRGB, densityCMY:ImageRGB, densityMax:[Double], matrix:[[Double]], diffusionSizePixel:Double, diffusionTailPixel:Double, diffusionTailWeight:Double, positive:Bool) -> ImageRGB`
   - `silver = positive ? densityMax - densityCMY : densityCMY`
   - `correction[p][m] = Σ_k silver[p][k] * matrix[k][m]`
   - 若 `diffusionSizePixel > 0`：`correction = (1-w)*FastGaussian.filter(correction, size) + w*FastGaussian.exponentialFilter(correction, decay: tail)`
     （`fast_exponential_filter(log_raw_correction, diffusion_tail_size_pixel)` 标量版，nGaussians=3，与 `SpatialEffects` 现有一致）
   - 返回 `logRaw - correction`。
4. `applyDensityCorrection(densityCMY, logRaw, logExposure, densityCurvesNormalized, params, profileType, gammaFactor) -> ImageRGB`
   - `!params.active` → 原样返回；`matrix = computeMatrix(params) * params.amount`
   - `curves0 = curvesBeforeCouplers(densityCurvesNormalized, logExposure, matrix, positive)`
   - `densityMax = nanmaxPerChannel(densityCurvesNormalized)`
   - `diffusionSizePixel = params.diffusionSizeUM > 0 ? params.diffusionSizeUM / pixelSizeUM : 0`；tail 同理
   - `logRaw0 = exposureCorrection(...)` → `DensityCurves.interpolateExposureToDensity(logExposureRGB: logRaw0, densityCurves: curves0, logExposure: logExposure, gammaFactor: [g,g,g])`

**接线** `FilmingStage.develop`：`developSimple(normalized)` → `Couplers.applyDensityCorrection(...)` → `Grain.apply(...)`。
`densityCurves_layers` 与 `profile type` 由 `Profile` 读取（`film.data.densityCurvesLayers`、`film.info.type`）。

## 5. G2：颗粒

**新文件** `Sources/SpektraCore/Model/Grain.swift` + `Sources/SpektraCore/Utils/RandomStats.swift`。

1. `RandomStats`（独立 `RandomGenerator`，SplitMix64 种子；默认种子 `[0,1,2] + sublayer*10`，可配置 `fixedSeed`）：
   - `poisson(λ, rng)`：λ≤0→0；λ<30 → Knuth（`p=1; while p>exp(-λ) { k+=1; p*=u }`）；否则正态近似 `round(λ + sqrt(λ)*z)`，负数夹 0，`round` 用 `.toNearestOrEven`（对齐 numpy）。
   - `binomial(n, p, rng)`：p≤0→0；p≥1→n；n<25 → n 次 `u<p` 计数；否则 `var=n p (1-p)`，`var>10` → 正态近似 + 夹取 [0,n]；否则反演法（照抄 prob/cdf 递推）。
   - `lognormalFromMeanStd(m, s, rng)`：`sigma²=ln(1+s²/m²)`, `mu=ln m - sigma²/2`；`sigma<1e-6 → exp(mu)`；否则 `exp(mu+sigma*z)`；`m<=0 → 1.0`（对齐 `fast_lognormal_from_mean_std` 的 mu=sigma=0）。
2. `layerParticleModel(density, densityMax, nParticlesPerPixel, uniformity, rng, blurParticle)`：
   - `p = clip(density/densityMax, 1e-6, 1-1e-6)`；`od = densityMax/n`
   - `saturation = 1 - p*uniformity*(1-1e-6)`
   - `seeds = poisson(n/saturation)`；`grain = binomial(seeds, p) * od * saturation`
   - `blurParticle>0` → `FastGaussian.filter(grain, sigma: blurParticle*sqrt(od))`
3. `interpDensityCMYLayers(densityCMY, densityCurves, densityCurvesLayers, positive)` → `[pixel][layer][channel]`
   - negative：`interp(densityCMY_c, densityCurves[:,c], densityCurvesLayers[:,:,c])`
   - positive：`-interp(-densityCMY_c, -densityCurves[:,c], densityCurvesLayers[:,:,c])`
   （图层轴与通道轴顺序对齐 numpy `(x,y,layer,rgb)`）。
4. `applyToDensity(...)`（无子层）：`density += densityMin`；每通道 `layerParticleModel`；`/= nSubLayers`；`-= densityMin`；`sigmaBlur>0.4` → `FastGaussian.filter(sigmaBlur)`。
5. `applyToDensityLayers(...)`（默认路径）：
   - `densityMaxTotal = Σ_layers`；`fractions = layers/total`；`minLayers = fractions * densityMin`
   - `nParticles[l][c] = pixelArea * fractions[l][c] / (particleArea * particleScale[c] * particleScaleLayers[l])`
   - 逐通道/子层累加 `layerParticleModel(..., blurParticle: blurDyeCloudsUM)`
   - `addMicroStructure`：`blurPx = micro[0]/pixelUM`，`sigma = micro[1]*0.001/pixelUM`；`sigma>0.05` → `clumping = lognormalFromMeanStd(1, sigma)`（每像素独立），`blurPx>0.4` → 高斯；`density *= clumping`
   - `-= densityMin`；`grain.blur>0` → 高斯
6. `apply(...)` 入口与 Python `apply_grain` 一致：`!active || bypass || debug.deactivateStochasticEffects` → 原样；`!sublayersActive` 走 4；否则走 5。
   `pixelSizeUM` 使用 `FilmingStage.pixelSizeUM`（preprocess 已设）。

## 6. G3：眩光

**新文件** `Sources/SpektraCore/Model/Glare.swift`。
`addGlare(xyz, illuminantXYZ, params?)`：
- 条件 `params != nil && active && percent > 0`
- `amount = lognormalFromMeanStd(mean: percent, std: roughness*percent)` 每像素一个
- `FastGaussian.filter(amount, sigma: blur)`（逐像素标量图，直接 2D，非 3 通道）
- `/=100`；`xyz[c] += amount * illuminantXYZ[c]`
- `scanFilm == true` 时 Python 传 `glare=None`，Swift 保持传 `nil`。

## 7. G4：柔光镜族

**改写** `Sources/SpektraCore/Utils/SpatialEffects.swift` 的 `diffusionFilter`，新增
`Sources/SpektraCore/Model/DiffusionFilter.swift`（数据表 + 权重）与 `Utils/FFTConvolution.swift`。

1. 家族表：`glimmerglass` / `black_pro_mist` / `pro_mist` / `cinebloom`，字段 `core/halo/bloom {lambda_um, spread, n_components, alpha}` + `w_c/w_h/w_b` + `halo_warmth_base`，数值逐项照抄 Python 185-242。
2. `_DIFFUSION_FAMILY_TOTAL_GAIN` 与强度表 `[0.125,0.25,0.5,1,2] → [0.10,0.20,0.35,0.55,0.75]`，log2 线性内插，`clip(0,0.99)`。
3. `expandGroup`：`n==1||spread<=1` → 单分量；否则 `logspace(log(λ/spread), log(λ*spread), n)`，bloom 权重 `λ^(2-alpha)`，组内归一。
4. `haloChannelWeights(weights, warmth)`：`g = linspace(-1,1,n) - weightedAverage(g, weights)`；每通道 `w*(1 + warmth*axis[c]*g)`，`axis=[1.3,0.15,-1.45]`，clip≥0 后按目标总权重归一；warmth 夹 [-1.5,1.5]。
5. `resolveFamilyCfg` 支持 `core/halo/bloom_intensity` 与 `_size` 覆盖，三权重重新归一。
6. `psf(shape, family, spatialScale, pixelSizeUM, warmth, overrides)`：半径网格 `r`（像素），`core = w_c Σ exp(-r/λ)/(2πλ²)`，halo 每通道，bloom 同理；每通道求和后 `sum` 归一。
7. `apply(image, params, pixelSizeUM)`：
   - `!active || strength<=0 || spatialScale<=0` → 原样
   - `p_s = strengthToScatter`；`radius = min(ceil(max(8*bloomMaxLambda_px, 5)), max(min(h,w)/2-1, 1))`
   - `psfShape = (2r+1, 2r+1)`；reflect padding；每通道与 PSF 做 **same** 卷积（FFT）
   - `out = (1-p_s)*image + p_s*blurred`
8. `FFTConvolution`：Accelerate `vDSP_fft_zrip`，零填充到 2 的幂 ≥ (N+kernel-1)，逐通道；结果取 same 区域。与 numpy `fftconvolve(mode='same')` 对齐（same 中心 = 卷积中心偏移 `(k-1)/2` 向下取整）。

## 8. G5：印相像素尺寸

`PrintingStage` 增加 `var pixelSizeUM: Double = 1.0`，`Pipeline.preprocess` 同时写入 `filming.pixelSizeUM` 与 `printing.pixelSizeUM`（同 `filmFormatMM*1000/longEdge/upscale`）。`PrintingStage.applyDiffusion` 不再传 nil。

## 9. G6：输出色域压缩

**新文件** `Sources/SpektraCore/Color/CAM16UCS.swift`、`Model/OutputGamutCompression.swift`。

1. `CAM16UCS`：实现 colour-science 的 `XYZ_to_CAM16UCS` / `CAM16UCS_to_XYZ`（含 forward 的 CAT16 适应、`L_A=64`、`Y_b=20`、average surround、`XYZ_w` = 输出空间白点 Y=1），以及 `XYZ_to_CAM16` 中间量 ↔ CAM16-UCS 变换（`J' = 1.7J/(1+0.007J)`，`M' = ln(1+0.0228M)/0.0228`，`a=M'cos h`, `b=M'sin h`），逆向逐行照搬。
2. `compress(rgb, spec, outputColorSpace)`：
   - `off` → 原样；`aces_rgc` → 逐通道 knee；`oklch/oklrab/jzazbz/cam16ucs` → 对应感知空间
   - `knee=(0,1,6)`；`lightness_compression=(0.7,1.0,2.2)`，在 chroma 步之前作用于归一化 `L/L_white`
   - `reinhard_knee`: `d>t → t + (l-t) * y`，`x=(d-t)/(l-t)`，`y=x/(1+x^p)^(1/p)`
   - `C_max(L,h)` 表：`N_L=64, N_H=720, N_BISECT=18`，`h=linspace(-π,π,720,endpoint=false)`，`L` 网格按空间（cam16ucs 1→110，oklch/oklrab 0.02→1，jzazbz 0.002→0.18），初始上界 150/0.5/0.3，二分判据 `RGB∈[-1e-6,1+1e-6]`
   - 双线性查找按 Python `_c_max_lookup`（h 环绕、L 夹取）
3. 性能：表按 `(space, outputColorSpace)` 懒构建并缓存（Swift 下 64×720×18≈83 万次转换，需 <3 s）。
4. 输出空间无对应表（非 sRGB/Rec.2020/Display P3/ProPhoto 等已支持 RGB 空间）时：保持 `aces_rgc`；感知算法直接返回原 rgb 并记一次 warning，不静默改色。

**接线** `ScanningStage.compressRGB` 调用 `OutputGamutCompression.apply`，参数 `io.outputGamutCompressAlgorithm`、`io.outputGamutCompressKnee`。

## 10. 验证

1. `./build.sh` 通过（Swift 6.0.3 CLT，无 Xcode）。
2. 新建 `Tools/ParityCheck/main.swift`（或扩展现有 `PipelineSmoke`）：
   - `SPEKTRA_DUMP_JSON=/tmp/x.json`：导出 4×4、32×24 的 `log_e_film`、`cmy_film`、`log_e_print`、`cmy_print`、`rgb_out`。
   - Python 侧脚本 `scripts/dump_reference.py`（放在 Swift worktree `Tools/parity/`，不写入 Python 仓库）复用 `SimulationPipeline` 导出同结构 JSON。
   - 用例矩阵：grain off/on、couplers on、glare on、diffusion on（4 家族）、output compress cam16ucs on；每组断言 `max|Δ| ≤ 1e-9`（随机组仅比对关闭随机项的子集 + 统计量 `|mean diff|/mean ≤ 2%`，`std` 同量级）。
3. 回归：现有 6 个确定性 tap 在「G1-G6 全关」下仍与当前基线逐位一致（备份基线 JSON 比对）。
4. 视觉抽检：`Tools/PipelineSmoke` 输出 PNG 前后对比（至少 1 组 35mm 全链路）。

## 11. 明确不在本阶段

- RAW 解码（LibRaw / CIRAWFilter 选型未定）。
- 图像导出（TIFF/EXR/ICC/EXIF）、库/持久化、预览与导出队列。
- `SpektraSkin` 静态壳接入真实状态（slider/toggle/choice/pad 的 `SkinActions` 扩展）。
- upscale 的 `skimage.rescale` 复刻（当前仅按 `upscaleFactor` 改像素尺寸）。
- 自动曝光的完整方法集验证（留待 UI 联调）。

## 12. 风险与决策

- **RNG**：不追求与 Python 逐像素同噪声（numba 并行 RNG 不可复现）；按分布算法同构 + 统计验收。若日后要求可复现，改由 Python 导出噪声图作为测试夹具。
- **FFT 卷积**：numpy `fftconvolve(same)` 的边界为 valid 区居中；Swift 用零填充 + 频域乘，需按 `(k-1)/2` 偏移裁剪，测试用 5×5 核与单位脉冲验证。
- **CAM16 表构建耗时**：允许懒构建；若 >3 s 则改为构建期离线烘焙 JSON 到 `Resources/Data/Color/`（附录放 Python 烘焙脚本）。
- **gamma 语义**：`interpolateExposureToDensity` 的 x 轴是 `logExposure/gamma`，现有 Swift 已一致，G1/G2 复用，不再改写。
