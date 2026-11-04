# 对拍报告（第二阶段）

参考实现：Python `skin` 分支；Swift `swift-native` 分支。
命令：`Tools/ParityCheck`（Swift）+ `Tools/parity/dump_reference.py`（Python），JSON 逐值比对。

## 1. 确定性模块（要求 ≤1e-9）

| 模块 | 用例 | 样本 | 最大绝对误差 | 结论 |
|------|------|------|--------------|------|
| DIR couplers | `couplers` | 4×4、pixel 6 µm、含空间扩散 | 1.1e-15 | 通过 |
| 颗粒逐层插值 | `grain_layers` | 4 像素 × 3 层 × 3 通道 | 3.5e-18 | 通过 |
| 柔光镜 PSF（四家族 + warmth） | `diffusion_psf` | 21×21 × 4 | 4.4e-16 | 通过 |
| 柔光镜全图卷积 | `diffusion_apply` | 16×16、glimmerglass 0.5 | 8.9e-16 | 通过 |
| CAM16-UCS 正/逆变换 | `cam16` | 参考 XYZ | 0 / 1.1e-16 | 通过 |
| 输出色域压缩 cam16ucs | `output_compress` | 4 像素（含超白/负值/高饱和） | 1.1e-15 | 通过 |
| 全管线基线（新效果全关） | `pipeline` | 2×2，6 个 tap | ≤5.0e-13 | 通过 |
| 全管线 + couplers | `pipeline COUPLERS=1` | 2×2，6 个 tap | ≤4.9e-13 | 通过 |
| 全管线 + 印相柔光镜 | `pipeline ENLARGER_DIFFUSION=1` | 2×2，6 个 tap | ≤5.0e-13 | 通过 |
| 全管线 + 输出压缩 | `pipeline OUTPUT=cam16ucs` | 2×2，6 个 tap | ≤4.0e-13 | 通过 |

> 全管线数值受 Swift smoke 的 `%.12f` 打印精度限制，5e-13 已是输出精度上限。

## 2. 统计模块（Python numba 并行 RNG 不可复现，按分布验收）

| 模块 | 用例 | 指标 | 结果 |
|------|------|------|------|
| 颗粒（子层路径） | `grain_stats` 128×128 × 5 密度档 | 均值：最大相对偏差 1.6% | 通过（≤2%） |
| 颗粒 | 同上 | 标准差：最大相对偏差 4.7%，各档同量级 | 通过（同量级） |
| 眩光 | `glare_stats` 128×128，p=0.03 | 均值 0.000284/0.000299/0.000326 vs 0.000284/0.000299/0.000326；标准差偏差 <2% | 通过 |

## 3. 顺带修复的基线偏差

- 印相中灰滤镜：Swift 此前用固定 55/65，Python `digest_params` 按 `(print stock, illuminant, film stock)` 查
  `filters/neutral_print_filters.json`。已补齐（kodak_supra_endura + TH-KG3 + kodak_portra_400 → c=0, m=50.730, y=55.565），
  修正前 `cmy_print` 偏差 1.5e-1，修正后 ≤5e-13。
- 胶片特定 DIR couplers 系数（负片 0.336/0.319/0.273 等）与 halation 预设（use/antihalation 分档）已按 `params_builder` 复刻。

## 4. 第三阶段（jzazbz 与导出）

| 模块 | 用例 | 样本 | 最大误差 | 结论 |
|------|------|------|----------|------|
| JzAzBz 正/逆变换 | `jzazbz` | 参考 XYZ | 0 / 3.6e-15（另乘 100 对齐绝对 XYZ） | 通过 |
| 输出压缩 jzazbz | `output_compress ALGO=jzazbz` | 4 像素 | 2.3e-13 | 通过 |
| 输出压缩 oklch | `output_compress ALGO=oklch` | 4 像素 | 2.6e-15 | 通过 |
| 输出压缩 oklrab | `output_compress ALGO=oklrab` | 4 像素 | 1.6e-15 | 通过 |
| 输出压缩 aces_rgc | `output_compress ALGO=aces_rgc` | 4 像素 | 0 | 通过 |
| 自动曝光（7 种方法，原始尺寸） | `autoexposure` | 24×16 | ≤1.1e-15 | 通过 |
| 自动曝光（含 256 预览重采样） | `autoexposure PREVIEW=1` | 320×200 | ≤1.4e-14 | 通过 |

说明：预览缩放已改为与 skimage `rescale(order=0)` 完全一致的坐标/边界规则
（`round(scale*dim)`、`(i+0.5)*(in/out)-0.5`、最近邻、镜像边界）。

导出验证（`CASE=export`，用 Python `tifffile` / `OpenImageIO` / `PIL` 读回）：

| 格式 | 结果 |
|------|------|
| TIFF uint8 / uint16 | 3 通道、Deflate（Compression=8）与 Python 一致，像素四舍五入一致 |
| TIFF float32 | 3 通道，原值精确 |
| TIFF ICC | tag 34675 存在，sRGB V2 9552 字节，PIL 可读出 |
| TIFF EXIF | Software=spektrafilm、DateTime、EXIF IFD（ColorSpace/PixelX/Y/Interop） |
| EXR half | R/G/B 三通道，half 舍入与 numpy float16 一致（0.1→0.09997559） |
| EXR float | 原值精确 |
| PNG / JPEG | 8-bit + ICC；PNG 像素精确，JPEG 有损 ±2 LSB |

TIFF Deflate 通过 `dlopen("/usr/lib/libz.1.dylib")` 调用系统 zlib 实现，绕开本机
`Compression` 模块的 SDK 版本冲突。

## 4.1 放大（upscale_factor）

Swift 使用 Catmull-Rom 双三次放大，输出尺寸与 skimage 一致；**像素值非逐位一致**：
8×6→16×12 测试最大偏差 2.5e-2、平均 3.7e-3（skimage 的 `order=3` 带 B 样条预滤波，更柔和）。
默认 `upscale_factor = 1` 时无影响。

## 5. 性能与健壮性（第五阶段）

基准：640×480，kodak_portra_400 + kodak_supra_endura，LUT 17，相机柔光镜 black_pro_mist 0.5。

| 场景 | 优化前 | 优化后 | 手段 |
|------|--------|--------|------|
| 全效果（含颗粒） | 193 s | 2.06 s | 颗粒二项分布对称采样；vDSP Double FFT + 转置；通道并行；光源 xy 与 RGB→XYZ 矩阵提到循环外 |
| 预览模式（无颗粒） | 184 s | 1.66 s | 同上 |
| 颗粒粒子模型 | 184 s | 0.11 s | p>0.5 时改数「未显影」粒子，避免反演法在 p≈1 时线性走 n 次 |
| 相机柔光镜 FFT | 1.73 s | 0.70 s | 列 FFT 改为「转置 + 行 FFT」；三通道并发 |
| 光谱上采样 | 2.24 s | 0.03 s | 消除逐像素光源查询与逐像素矩阵求逆 |

> 颗粒标准差与 Python 的最大相对差异从 4.7% 变为 6.9%（仍是同量级）。原因是 Python 的
> `fast_binomial` 在 p≈1 时走数值退化的反演分支；Swift 改用数学等价且稳定的对称采样。

新增 `PreviewRenderer`：串行渲染队列、代际取消、共享 LUT 服务、预览降采样、`keepTaps=false`
（只保留最终图，降低大图内存）。`SimulationPipeline` 支持协作式取消与共享 `SpectralLUTService`。

## 6. RAW 解码（不参与数值对拍）

Python 使用 LibRaw（rawpy）输出 16-bit 线性 ACES；macOS 侧使用 `CIRAWFilter`（Core Image）做去马赛克与相机矩阵，
再经 sRGB→目标空间转换。已验证解码/渲染链路可运行（用示例 JPEG 走通 `CIRAWFilter`），
但**去马赛克、白平衡与 LibRaw 不逐像素一致**；lensfun 镜头校正未复刻。仓库内没有真实 RAW 样本，故未做真机 RAW 验证。

## 6.1 照片库与导出队列（第六阶段）

验证用例 `CASE=library`：

| 项 | 结果 |
|----|------|
| 编码图导入 | `color-chart.jpg` 的 ICC 识别为 Adobe RGB (1998)，`cctfDecoding=true`，500×343 |
| 库索引持久化 | `index.json` 写盘、重载后照片数 1，完整 `PhotoEdit`（相机/放大机/胶片/相纸/扫描/IO）可恢复 |
| 缩略图 | 走预览模式管线渲染 256 长边，PNG 写入 `Thumbnails/<id>.png` |
| 导出队列 | 串行全尺寸渲染 + 写盘，进度回调与取消接口可用；输出 500×343 uint16 TIFF、Deflate、ICC 存在 |
| 输入识别 | RAW → ProPhoto 线性；EXR/HDR → ACES 线性；编码图按 ICC 描述映射，缺省 sRGB + CCTF 解码 |

## 7. 尚未覆盖

- 放大（`upscale_factor`）与 skimage `rescale(order=3)` 的逐位一致（当前为 Catmull-Rom 近似）。
- RAW：真实相机文件验证、LibRaw 等价性（不可能逐像素）、lensfun 校正。
- 导出：XMP 元数据复制（EXIF/IPTC 已支持 PNG/JPEG；TIFF 仅基础 EXIF）、TIFF 多 strip。
- UI 接线、库/持久化、预览与导出队列。

## 8. LUT 预览预测（第十阶段，新增近似路径）

不参与物理 tap 对拍；比较对象是 Swift 自身的确定性精算（`debug.lutMode`），
指标为 ProPhoto 线性空间的 CIEDE2000（`PreviewPreflight`）。

| 项 | 结果 |
|----|------|
| 合成图 96×72，65³ | ΔE₀₀ max 0.82 / p99 0.43（门禁 ≤2.0 / ≤1.0） |
| 真实 12 MP DNG（256 长边），65³ | ΔE₀₀ max 1.60 / p99 0.83；通过 |
| 同图 45³ 对照 | max 2.65 / p99 1.45；p99 不达标，故默认 65³ |
| 45³ → 65³ 提升 | p99 1.45 → 0.83；四面体插值同时用于全部四段表 |
| 快速拍摄曝光 +1（关闭补偿） | 真实 DNG p99 0.985；预测/精算平均亮度差 0.004，曝光单调提亮 |
| 快速拍摄曝光映射 | 拖动时关闭印相自动亮度补偿，回 0 恢复基线；否则印相归一化会把它变成反差 |
| 自动曝光位置 | 放在 t1 shaper 坐标偏移，匹配真管线 preprocess 顺序 |
| 补偿管线 | 常驻，补偿开关不入缓存键；开关补偿不重烘 |
| 烘焙耗时 65³ | 冷启动 0.8–1.3 s（含谱 LUT/印相 LUT 首次构建），热缓存约 0.6 s |
| 查表 + 显示耗时 | 800×600：查表 23–39 ms + 显示 6–10 ms |
| CIEDE2000 公式 | Sharma 6 组参考对，最大误差 4.0e-5 |
| 连续轴 | 相机曝光/自动曝光/印相曝光/预闪外部施加；补偿开关不参与烘焙键 |
| 空间/随机效果 | LUT 预测不含颗粒/眩光/光晕/USM；导出预检单独报告 effects 差异 |

说明：预测与精算使用同一 `RuntimePhotoParams`；LUT 只承载确定性逐像素链路。
物理显影/印相/扫描阶段未改动，原 tap 对拍表（§1）不受影响。
