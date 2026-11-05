# 实施任务清单（spec.md 对应）

> 顺序即依赖顺序。每项完成需 `./build.sh` 通过；G1/G4/G6 需附对拍证据。

## T1 DIR couplers（G1）
- [x] 新建 `Model/Couplers.swift`：`computeMatrix` / `curvesBeforeCouplers` / `exposureCorrection` / `applyDensityCorrection`
- [x] `FilmingStage.develop` 串入 couplers（`developSimple` → couplers → grain 占位）
- [x] 新增 numpy `interp` 语义工具（异号/非单调 x 段），复用 `Interpolation`
- 验收：grain off、couplers on，`cmy_film` 4×4 与 32×24 对拍 ≤1e-9；`active=false` 与基线逐位一致

## T2 随机统计与颗粒（G2）
- [x] `Utils/RandomStats.swift`：SplitMix64 + poisson/binomial/lognormal（`.toNearestOrEven`）
- [x] `Model/Grain.swift`：`layerParticleModel` / `interpDensityCMYLayers` / `applyToDensity` / `applyToDensityLayers` / `addMicroStructure` / `apply`
- [x] `FilmingStage.develop` 接入 grain；尊重 `debug.deactivateStochasticEffects`
- 验收：`active=false` 与 T1 输出逐位一致；`active=true` 时 256×256 灰度块 5 档密度统计：均值偏差 ≤2%，RMS 与 Python 同量级；子层/非子层两条路径均跑到

## T3 眩光（G3）
- [x] `Model/Glare.swift` 的 `addGlare`
- [x] `ScanningStage.addGlare` 调用；`scanFilm` 传 nil
- 验收：`percent=0` 恒等；`percent=0.03/roughness=0.7/blur=0.5` 时 XYZ 增量均值 ≈ percent/100×illuminant（±3%），空间相关长度与 blur 一致

## T4 柔光镜（G4）
- [x] `Model/DiffusionFilter.swift`：家族表、`strengthToScatter`、`expandGroup`、`haloChannelWeights`、`resolveFamilyCfg`、`psf`
- [x] `Utils/FFTConvolution.swift`：vDSP 实数 FFT、same 裁剪、reflect pad
- [x] `SpatialEffects.diffusionFilter` 实现；四家族 × strength 0.25/1/2 × warmth 0/1 覆盖
- 验收：单位脉冲响应与 Python `diffusion_filter_psf` 中心/边缘 ≤1e-9（用 `psf` 直出比对）；全链路 `active=false` 与 T3 基线一致；`black_pro_mist, 0.5` 图像对拍 ≤1e-9（无随机项）

## T5 印相像素尺寸（G5）
- [x] `PrintingStage.pixelSizeUM` + `Pipeline.preprocess` 写入
- 验收：`enlarger.diffusion.active=true` 时 `log_e_print` 与 Python 对拍 ≤1e-9；关闭时基线不变

## T6 输出色域压缩（G6）
- [x] `Color/CAM16UCS.swift`：CAM16 forward/inverse + UCS 变换
- [x] `Model/OutputGamutCompression.swift`：`reinhardKnee`、`cMaxLookup`、表构建与缓存、`aces_rgc`、`cam16ucs`（oklch/oklrab 已实现，jzazbz 暂缺）
- [x] `ScanningStage.compressRGB` 接线
- 验收：`algorithm=off` 与 T5 基线逐位一致；`cam16ucs` 在 sRGB 输出的 `rgb_out` 对拍 ≤1e-9（4×4、32×24 各一组，含超白与高饱和像素）；表构建耗时 <3 s

## T7 对拍与回归
- [x] `Tools/PipelineSmoke` 增加 JSON 导出/导入
- [x] `Tools/parity/dump_reference.py`（跑 Python 参考管线，输出同结构 JSON）
- [x] 备份「G1-G6 全关」基线 JSON，回归 6 个 tap
- [x] 汇总对拍报告（写入 `docs/parity_report.md`，仅数据表）

## 完成后
- [x] 更新 `docs/PORTING_PLAN.md` 的「已完成/剩余」段落
- [x] 向用户汇报：哪些模块与 Python 逐位一致、哪些为统计等价、剩余缺口（UI 接线、RAW、导出）

## 第三阶段（用户追加：jzazbz / RAW / 导出）
- [x] `Color/JzAzBz.swift`：Safdar 2017 正逆变换 + ST2084 PQ
- [x] `OutputGamutCompression` 补齐 `jzazbz` 表与逐像素路径
- [x] `Services/ImageExport.swift`：TIFF（8/16/32-bit + ICC + EXIF）、EXR（half/float）、PNG/JPEG（8-bit + ICC）
- [x] `Services/RawDecoder.swift`：CIRAWFilter 解码 + EXIF 读取（原生 macOS 路径）
- 验收：jzazbz 正逆 0 / 3.6e-15；jzazbz 压缩 2.3e-13；oklch 2.6e-15、oklrab 1.6e-15、aces_rgc 0；
  导出像素 8/16/32-bit TIFF 与 half/float EXR 全部精确；PNG/JPEG 8-bit（JPEG 有损 ±2 LSB）；ICC 已嵌入

## 第四阶段（引擎收尾）
- [x] 自动曝光 7 种方法对拍（原始尺寸与 256 预览路径）
- [x] `Resize.smallPreview` 对齐 skimage `rescale(order=0)` 坐标/边界规则
- [x] TIFF Deflate（系统 zlib via `dlopen`，Compression=8）
- [x] 导出支持复制源 EXIF/IPTC（PNG/JPEG）
- [x] `upscale_factor != 1` 走双三次 Catmull-Rom 并同步像素尺寸
- 验收：autoexposure ≤1.4e-14；TIFF compression=8 且像素不变；放大尺寸一致（像素值近似，偏差 ≤2.5e-2）

## 第五阶段（性能与健壮性）
- [x] 颗粒二项分布对称采样（消除 p≈1 时的 O(n) 退化）
- [x] vDSP Double FFT（dlopen）+ 转置列变换 + 三通道并发
- [x] 光谱上采样：光源 xy 与 RGB→XYZ 矩阵提出循环
- [x] `PreviewRenderer`：串行队列、代际取消、共享 LUT、降采样、`keepTaps`
- [x] `SimulationPipeline` 协作式取消与共享 `SpectralLUTService`
- 验收：640×480 全效果 193 s → 2.06 s；预览 184 s → 1.66 s；全管线基线仍 ≤5e-13

## 第六阶段（库与导出队列）
- [x] `Services/ImageLoader.swift`：RAW / EXR / 编码图识别与解码
- [x] `Services/LibraryStore.swift`：原图拷贝、索引持久化、缩略图、PhotoEdit（Codable）
- [x] `Services/ExportQueue.swift`：串行全尺寸渲染、进度、取消、保存
- 验收：示例 JPEG 识别为 Adobe RGB；库重载后编辑可恢复；导出 500×343 uint16 Deflate TIFF + ICC

## 第七阶段（SpektraSkin 引擎接入）
- [x] `SpektraSkin/Engine/EngineHost.swift`：库快照、编辑器快照、快速/专业动作、预览渲染、导入、导出
- [x] 九个快速控制按计划书映射 + 基线锚定 + 色盘；快速意图与基线持久化（`quickBaselineData`）
- [x] `PreviewStage` 注入真实预览与缩略图；`FilmThumbnail` / 库网格 / 列表全部改用引擎缩略图
- [x] 库内缺失缩略图后台补渲染（`warmThumbnails`，串行队列，320px）
- [x] 直方图改为从预览输出计算（56 桶 RGB，桶峰值归一）；调色台注入当前预览
- [x] 顶部与空态的「导入照片/文件夹」接到 `NSOpenPanel`；文件夹递归只收 RAW
- 验收：`HostSmoke` 预览 3.5 s、快速/专业写回生效、缩略图生成、导出 16-bit TIFF 成功

## 第八阶段（RAW 闪退与交互修复）
- [x] 修复 RAW 极端像素导致 `OutputGamutCompression.cMaxLookup` 的 NaN/Inf 索引陷阱
- [x] 扫描输出与 RAW 解码统一 `sanitizedNonFinite()`；预览/导出/8·16-bit 写盘再兜底
- [x] 显影台改为只接受 RAW：库导入、文件夹导入、旧索引过滤；删除 JPEG/样图与 JPEG 导出
- [x] 预览不再强制 `preview_mode=True`：颗粒、锐化、柔光、halation 按实际参数渲染
- [x] 预览降采样改用 `Resize.smallPreview`（与 Python GUI 同一重采样规则）
- [x] 窗口拖动只保留顶部状态栏 `WindowDragArea`，`isMovableByWindowBackground = false`
- [x] 预览支持滚轮/触控板缩放、拖拽平移、双击复位、旋转与适应窗口
- [x] 预览工具栏：渲染比例（1/8–1/1）、对比原图、重新渲染、显示倍率全部可交互
- [x] 导出菜单（sRGB TIFF 16/8、ProPhoto 线性 TIFF 16、ACES 线性 EXR half）+ `NSSavePanel`
- [x] 库搜索/筛选/排序、收藏、颜色标签、移除照片；编辑器收藏写回
- 验收：`HostSmoke` 载入 12 MP DNG 预览 3.5 s、导出 TIFF 71 MB，无闪退；NaN/Inf 色域压缩回归通过

## 第九阶段（electron 最新交互与调色台移植）
- [x] 显影预览调度：参数停止 1 s 后渲染；期间新参数立即中断在途渲染并显示「已中断，等待新参数…」
- [x] `RenderPhase` 进度（预处理/胶片曝光/显影/印相/扫描，index/total）显示在画布上
- [x] 对比改为可拖分割线：原图叠在显影图上按比例裁剪，拖动改变分界
- [x] 导出设置面板：格式、长边像素、目录、文件名模板（{name}/{film}/{paper}）
- [x] 正片扫描模式下印相类快速轴禁用并给出原因
- [x] `Sources/SpektraCore/Grade/GradeRecipe.swift`：与 Python `grade_recipe.py` 同字段、同默认、同钳位
- [x] `Sources/SpektraCore/Grade/GradeEngine.swift`：曝光/白平衡 → sRGB 编码 → 影调 → 色彩 → 通透 → 清晰度/纹理 → 去雾 → 降噪 → 锐化 → 暗角/色差/颗粒 → LUT → 后处理
- [x] `.cube` 解析、三线性插值、强度混合；内置「中性/清透/暖调/冷夜/黑白」预设 + 用户预设 JSON
- [x] 调色台页面：LUT/预设左栏、画布、光影/色彩右栏、曲线/通透/画质/光学折叠、直方图与黑/白场分析
- [x] 调色预览调度：120 ms/800 px 代理图 + 1.1 s/1600 px 精修，步骤间取消
- [x] 调色导出：全尺寸显影 → 线性交接 → 调色 → 目标色彩空间转换 → TIFF/EXR
- 验收：`HostSmoke` identity 配方与 sRGB 编码最大差 0；identity LUT 最大差 1.1e-16；12 MP DNG 交接图 8 s、暖调导出 1200 px TIFF 6.3 MB

## 第十阶段（双层渲染，代码完成，待 UI 验收）
> 参考 electron `d17128d` 的 `lut_preview.py`；方案与差异见 `docs/PORTING_PLAN.md` §14。
- [x] P0 实测：65³ 冷启动烘焙 0.8–1.3 s、800×600 查表 18–32 ms
- [x] P1 `PreviewLUTService`：log shaper、一次 grid 烘焙、Float32 四面体、LRU 3 组、换片预烘
- [x] P1 `CIEDE2000` + `PreviewPreflight`：ΔE₀₀ max ≤2.0 / p99 ≤1.0，Sharma 参考对误差 4.0e-5
- [x] P2 `EngineHost`：D0 150 ms、D1 1 s、180 ms 渐变、过期帧丢弃、预测帧在真算中也可上屏
- [x] P2 `PreviewStage`：D0/D1 交叉淡入
- [x] P3 导出面板预检提示（模型差异 / 效果缺失）
- [x] 快速“拍摄曝光”拖动时临时关闭印相自动亮度补偿、回 0 恢复；否则会变成反差
- [x] 对齐快速轴钳位/映射（印相明暗 0.25–4、影调反差 0.5–2、色彩浓度 0–1.5、
      颗粒逐通道、颗粒尺寸 0.02–0.8、光晕 0–2、柔光负向与反算）
- [x] 自动曝光放 t1 shaper 坐标（匹配真管线 preprocess 顺序）
- [x] 补偿管线常驻、补偿开关不入烘焙键（拖动曝光不重烘）
- [x] 预测显示段只做矩阵 + CCTF（色域压缩/USM 留给 D1），D0 合计约 30–49 ms
- [ ] 用户 UI 实测：渐变手感、预测帧上屏时机、曝光拖动手感、导出面板提示位置
- 验收：合成图 ΔE₀₀ max 0.82 / p99 0.43；真实 12 MP DNG max 1.60 / p99 0.83；
  快速曝光 +1 时 p99 0.985、预测/精算平均亮度差 0.004、曝光单调提亮；
  快速帧可见 True；导出 71.39 MB、调色 identity 0 / 1.11e-16
- 未做：三档开关（预测常开，与 electron 一致）、强制精算开关、81³ 高质量档

## 第十一阶段（调色台 UI 与影调修复，`swift-ui` 独立分支）
- [x] 左栏 LUT/预设改为卡片式：图标、类型副标题、选中勾、活动 LUT 内联强度滑块
- [x] 左栏与右栏 Tab 改为居中、占满宽度
- [x] 调色台接入显影台同款画布交互：滚轮/触控板缩放、拖拽平移、双击与空格回正、旋转、适应窗口
- [x] 调色台预览分辨率切换（1/8–1/1）；交接图仍固定 1600 长边，切换只影响降采样代理
- [x] 影调分区重写：高光/阴影峰值权重 0.26/0.28，白色/黑色 0.20/0.18（旧值为 0.003–0.015）
- [x] `HostSmoke` 增加影调力度阈值，防止白色/黑色再次静默失效
- 验收：`./build.sh` 通过；identity 差 0、identity LUT 1.1e-16；
  影调实测 shadows 0.280 / highlights 0.260 / whites 0.199 / blacks 0.180




## 第十一阶段（Adaptive Clarity 净化与库页双入口）
- [x] `Sources/SpektraCore/Clarity`：sRGB/OKLab 数学、1024 分析（影调/灰雾/局部/偏色）、去雾/影调/局部/色净四个处理器、一次验证回退
- [x] `GradeRecipe.adaptive` + `GradeEngine` 分支：曝光/白平衡 → sRGB 编码 → 净化 → 锐化 → 光学 → LUT；手动分支保持原顺序
- [x] `EngineHost`：净化分析缓存；曝光/色温/色调变化才重算；预览 1024、导出全尺寸验证
- [x] 调色台「智能净化」卡：开关、通透/色净滑块、一键、诊断摘要；显影后调色切 `.film`（只做局部层次）
- [x] 主页悬停双区：上「显影台」走正常路径，下「仅调色」用 `RawDecoder` 直解线性 sRGB，跳过光谱显影；非 RAW 回退显影台
- [x] `ClaritySmoke`：合成影调/灰雾/偏色；`HostSmoke` 增加自适应调色冒烟
- 验收：1600×1067 分析约 210 ms、渲染约 300 ms；identity 差 0；LUT identity 差 1.11e-16；ClaritySmoke PASS
- 未做：高级保护开关联动、完整 `ClarityPlan` 持久化、24MP 导出实测、真实 RAW 直入目视验收

## 第十二阶段（性价比优化）
- [x] LUT 烘焙键只保留影响 LUT 的字段：颗粒/光晕/柔光/清晰度/镜头模糊/黑白场校正/自动曝光方法不再触发重烘
- [x] D0 预测帧长边封顶 1000 px：1000×750 查表+显示 44.5 ms，高像素拖动不再随 1/4 比例变慢
- [x] App 图标与 Licenses 纳入 `build.sh`，重新构建不再丢图标，许可随 App 分发
- 验收：HostSmoke `spatialKeyStable=True`、`gammaKeyChanges=True`；真实 DNG 预检 p99 0.985；
  bake 786 ms、predict 33.9 ms、display 10.7 ms；identity 0 / 1.11e-16

## 第十四阶段（SpektrafilmOltra 品牌与安装器）
- [x] 新 logo 生成 macOS 圆角图标（16–1024）并替换 `Resources/Spektrafilm.icns`
- [x] 顶部栏改为 16 pt 应用图标 + SPEKTRAFILM 字标
- [x] Oltra 风格标准 DMG：暖石墨背景、黄铜箭头、产品标记、Licenses & Source、卷图标
- [x] `Tools/package_dmg.sh` 可重跑，自动写 Finder 布局与卷图标
- [ ] SpektrafilmOltra 独立官网（本地未找到站点；按用户要求不改 Ote.asia）
- 验收：`./build.sh` 通过；DMG 挂载含 `.background`、`.VolumeIcon.icns`、`.DS_Store`；
  App 与 DMG 签名校验通过；图标 16–1024 全部生成
