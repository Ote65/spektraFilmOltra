# Spektrafilm 视频显影方案：iOS 端 + macOS 端

> 状态：方案待评审，**本文不含代码改动**
> 编写日期：2026-11-17
> 适用工程：`SpektrafilmSwift-ios`
> 覆盖端：iPhone（`SpektraMobile`，iOS 17+）与 macOS（`SpektraSkin`，macOS 14+）
> 目标：拍摄后离线渲染胶片感视频，不追求实时；v1 支持 1080p SDR、负片、24/25/30fps、音频直通

---

## 0. 结论摘要

### 0.1 已验证的事实

- 现有 `PreviewLUTService` 已经把显影拆成四段 3D LUT：`input → t1 → logE film → t2 → CMY film → t3 → logE print → t4 → linear sRGB`，65³ 烘焙一次约 0.46 s（M 系列 Mac），且明确把颗粒、光晕、USM 等空间/随机效果排除在 LUT 之外。
- 预研微基准（M1 8 核 GPU，1080p，65³ rgba16 LUT，200 帧）：
  - 单段 LUT + 颗粒：**0.43–0.48 ms/帧**
  - 四段 LUT + 密度域颗粒：**0.42–0.48 ms/帧**
  - 四段 LUT 与单段几乎同价，瓶颈是输入/输出带宽，不是 LUT 采样。
- 按 A15 5 核 GPU ≈ M1 的 0.55–0.6 倍折算，iPhone 13 Pro 约 **0.8–1.2 ms/帧**；1440 帧（60 秒 24fps）纯渲染约 **1.2–1.7 秒**。
- 全物理 CPU 路径在同机约 **2 小时** 才能渲染 60 秒 1080p24，因此视频功能**必须走 LUT + GPU**，不能逐帧跑 `SimulationPipeline`。

### 0.2 v1 目标

| 指标 | iOS（iPhone 13 Pro 基线） | macOS（M1 基线） |
|---|---|---|
| 渲染 60 秒 1080p24 | 端到端 ≤ 60 秒（目标 20–30 秒） | 端到端 ≤ 20 秒（目标 8–15 秒） |
| 渲染 24 帧 1080p | ≤ 3 秒 | ≤ 1 秒 |
| 颗粒 | 密度域生成，逐帧变化，非静态贴层 | 同 iOS |
| 编码 | HEVC 10-bit，40/60 Mbps | HEVC 10-bit / ProRes 422 LT |
| 音频 | 直通，不重编码 | 直通 |
| 输出 | 系统相册 + 分享 | 文件夹 + 可选相册 |

### 0.3 明确不做

- 不做实时 24fps 预览；预览用 3–5 秒低分辨率代理片。
- v1 不做 4K、HDR（PQ/HLG）、正片（`scanFilm`）、关键帧参数动画。
- 不引入 AV1 Film Grain Synthesis：13 Pro 无硬件 AV1 编码，且它是解码端重建颗粒，等于把颗粒从像素里拿掉，不符合“颗粒必须在画面里”的要求。
- 不改现有照片显影/调色算法；视频只复用其 LUT 与参数模型。

---

## 1. 设计原则

1. **一套核心，两端复用**：所有视频渲染、LUT、颗粒、编码逻辑放在 `Sources/SpektraCore/Video/`，iOS 与 macOS 只做壳层。
2. **LUT 负责颜色，颗粒在密度域注入**：LUT 只做确定性颜色/密度变换；颗粒在 `t2 → t3` 之间注入 CMY 密度，而不是最后叠显示域噪声。这样颗粒会被印相/扫描曲线正确塑形，观感接近物理显影，也满足“颗粒不分开”。
3. **空间效果单独 GPU Pass**：光晕、柔光、扫描 USM 无法塞进 3D LUT，用半分辨率 bloom + 可分离高斯 + 合成实现；颗粒仍留在主 LUT kernel 内。
4. **零拷贝**：`CVPixelBuffer → CVMetalTextureCache → Metal → CVPixelBuffer → AVAssetWriter`，不做 CPU 逐帧 memcpy。
5. **参数一次烘焙**：全片固定参数，LUT 只烘一次；曝光锁定到参考帧，避免逐帧自动测光导致呼吸。
6. **可断点**：按帧记录进度，切后台/被杀后可续算；临时文件与最终文件分离。
7. **不动照片核心**：视频只复用 `PreviewLUTService` 的烘焙结果与 `PhotoEdit` 参数，不修改 `SimulationPipeline`、`Grain.swift`、`ScanningStage` 的数值语义；任何“为了视频”改核心的改动都必须单独评审并跑现有对拍门禁。

---

## 2. 共享核心架构

### 2.1 模块划分

```
Sources/SpektraCore/Video/
├── VideoModels.swift          // VideoProject / VideoExportSettings / VideoProgress
├── VideoLUTPayload.swift      // 四段 LUT + wiring + uniforms 的 GPU 传输结构
├── VideoLUTBaker.swift        // 复用 PreviewLUTService 烘焙 65³ 表，导出 payload
├── VideoGrainModel.swift      // 密度域颗粒参数、统计标定与逐帧种子
├── VideoMetalRenderer.swift   // Metal 设备/管线/纹理缓存，单帧渲染
├── VideoShaders.swift         // MSL 源码（运行时 makeLibrary，避免 .metal 构建集成）
├── VideoFramePipeline.swift   // AVAssetReader → Metal → AVAssetWriter 的帧循环
├── VideoExporter.swift        // 导出会话、进度、取消、断点
├── VideoColorIO.swift         // Rec.709 / YCbCr / 线性 ProPhoto / 10-bit 转换
└── VideoProjectStore.swift    // 视频工程 JSON 与缓存目录
```

iOS/macOS 壳层：

```
SpektraMobile/Sources/Screens/MVideoScreen.swift      // iOS 视频台
SpektraMobile/Sources/Engine/MVideoSession.swift      // iOS 会话（@MainActor）
SpektraSkin/Sources/SpektraSkin/Screens/VideoView.swift // macOS 视频台
SpektraSkin/Sources/SpektraSkin/Engine/VideoHost.swift  // macOS 会话
```

### 2.2 数据流

```
视频文件
  → AVAssetReader（硬件解码，10-bit YUV）
  → VideoColorIO（YCbCr → RGB → 线性 → ProPhoto 线性）
  → Metal kernel #1：t1 → 曝光偏移 → t2 → 密度域颗粒 → t3 → 印相偏移 → t4
  → Metal kernel #2：光晕/柔光 bloom 合成（半分辨率）
  → Metal kernel #3：扫描 USM + 线性 sRGB → Rec.709 OETF → YUV10
  → CVPixelBuffer（10-bit 4:2:0）
  → AVAssetWriter（HEVC 10-bit 硬编）
  → .mov/.mp4
```

### 2.3 与现有代码的关系

| 现有能力 | 视频复用方式 |
|---|---|
| `PreviewLUTService` 四段烘焙 | 复用 `bundle(for:key:resolution:)` 与 `cacheKey`，65³；新增 `VideoLUTPayload(bundle:)` 读出 t1–t4、wire1–3、`encodedInput`、`bakedFactor` |
| `Bundle.predict` 的查表顺序与偏移 | GPU 严格复刻：t1 shaper → camera EV 偏移 → t2 → t3 → print EV + comp 偏移 → t4 |
| `PhotoEdit` / `RuntimePhotoParams` | 视频工程直接持有 `PhotoEdit`，复用胶片/相纸/快速轴/专业参数 |
| `ExportQueue` | 不改；视频新建 `VideoExporter`，串行队列 + 进度回调 |
| `PhotoLibraryExport` | 复用授权与相簿归档；新增 `.video` 资源写入 |
| `build.sh`（macOS） | 已链接 `-framework Metal`；补 `AVFoundation`、`VideoToolbox`、`CoreMedia` |
| iOS `project.yml` | `Sources/SpektraCore` 整目录纳入；新增文件需 xcodegen 或手动登记 pbxproj |

---

## 3. LUT 契约

### 3.1 烘焙

- 分辨率：65³（33³ 在暗部渐变会出现肉眼可见断层，现有门禁已确认 65³ 为最低档）。
- 格式：`Float16`，四张表各 65³×4×2 B ≈ 2.2 MB，合计 ≈ 8.8 MB；显存/内存无压力。
- 烘焙参数：
  - `camera.autoExposure = false`，曝光固定为参考帧测光值。
  - `printExposure`、`printExposureCompensation` 由 GPU uniform 施加，不参与烘焙键。
  - `grain / halation / USM / lens blur / glare` 全部关闭（与现有 `makeBakeParams` 一致）。
  - 输入色彩空间固定为 `ProPhoto RGB` 线性，`inputCCTFDecoding = false`；视频帧先在 `VideoColorIO` 转成线性 ProPhoto。
- 烘焙键：直接复用 `PreviewLUTService.cacheKey(edit:inputColorSpace:inputCCTF:)`，连续轴已归零，拖动/换片不会重复烘焙。
- 参考帧：取片段中间帧或首帧，用 256 长边小图测 `AutoExposure.measureEV`，全片锁定。
- 缓存：按 `projectID + bakeKey + resolution` 存二进制 payload，切工程/重启可复用。

### 3.2 GPU 查表顺序（必须与 CPU 一致）

```
c = 线性 ProPhoto 输入
c = t1_shaped(c, autoEV)                 // log2 + wire1 lo/span
c += cameraEV * log10(2) / span1
c = t2(c)                                // logE film → CMY film
c += grain(c, frameSeed, grainParams)    // 密度域，逐帧种子
c = t3(c)                                // CMY film → logE print
c += (log10(printExposure) + log10(compRatio)) / span3
c = t4(c)                                // → 线性 sRGB
```

- `t1_shaped` 的 `shaperLowEV / shaperHighEV / evHeadroom` 与 `Bundle.predict` 完全一致；GPU 用 `log2` 与相同 lo/span。
- `compRatio` 在烘焙时算一次，作为 uniform；避免每帧跑 `compPipeline`。
- 中间值用 `Float16` 纹理或 `float` 寄存器；输出线性 sRGB。

### 3.3 正确性门禁

- 用同一张 1920×1080 测试帧，对比 GPU 链路与 `Bundle.predict` + `displayImage`：
  - 8-bit 输出：`max |Δ| ≤ 1/255`，`mean ≤ 0.2/255`。
  - 10-bit 输出：`max |Δ| ≤ 2/1023`。
- 四段 LUT 的中间 wire 归一化必须在 GPU 与 CPU 完全一致；任何一处偏差都会在暗部放大。
- 65³ 仍不足时，升级到 65³ + 四面体插值；不要退回 33³。

---

## 4. 颗粒模型

### 4.1 为什么不能做成独立贴层

现有物理颗粒在 `Grain.layerParticleModel` 里按通道/子层做泊松/二项采样，输出是**密度扰动**。如果在最后显示域叠一层噪声，会出现三个问题：

1. 颗粒不随印相/扫描曲线塑形，亮部和暗部形态不对。
2. 与画面内容脱钩，看起来像电视雪花，而不是胶片颗粒。
3. 缩放/编码后容易被压成块状。

因此颗粒必须在 `t2` 输出的 CMY 密度域注入，再走 `t3 → t4`。

### 4.2 GPU 颗粒生成

- 3 个独立噪声场（R/G/B 或 CMY），每个由 2–3 个尺度的哈希噪声叠加：
  - `n1`：像素级，粒子边缘；
  - `n2`：半分辨率，颗粒团簇；
  - `n3`：四分之一分辨率，染料云。
- 幅度包络：
  - 由局部密度 `d = mean(CMY)` 调制，峰值在中密度，阴影/高光收敛；对应 `densityMin`、`uniformity`、`particleAreaUM2`、`blur`。
  - 通道比与子层比来自物理模型统计，不在 GPU 里重新推导。
- 空间尺度：
  - `pixelSizeUM = filmFormatMM * 1000 / longEdge`；
  - 颗粒团簇 σ（像素）= `sqrt(particleAreaUM2) / pixelSizeUM`，并叠加 `grain.blur`。
- 时间维：
  - `frameSeed = hash(clipID, frameIndex)`，逐帧重随机；真实胶片颗粒每帧独立，不做帧间相关。
  - 不提供“静态颗粒”选项，避免用户误选后整段视频像脏镜头。

### 4.3 参数标定

不靠肉眼拍脑袋，按物理模型输出拟合：

1. 用现有 `SimulationPipeline` 在 3 个亮度块（低/中/高）上分别渲染单帧，开启颗粒，关闭其他空间效果。
2. 统计每个亮度块的颗粒标准差、自相关长度、RGB 协方差。
3. 拟合 GPU 颗粒的 `densityMin / uniformity / particleArea / blur / 通道比`，使三个亮度块的统计量落在 ±10% 内。
4. 视觉 A/B：同一帧 100% 与 200% 放大，确认颗粒形态与物理结果同向；允许纹理重排，不允许幅度/尺度明显偏离。

### 4.4 颗粒强度轴

- 复用现有快速轴 `grain_amount` 与 `grain_size`：
  - `grain_amount` → 密度域幅度；
  - `grain_size` → 团簇 σ 与 `particleAreaUM2`。
- 专业页 `grain_density_min / grain_uniformity / particle_area_um2 / grain_blur` 在 v1 只读展示“视频近似”，不承诺逐像素一致。

---

## 5. 空间效果

LUT 无法表达空间卷积，以下效果用独立 GPU Pass，按“半分辨率优先”控制成本：

| 效果 | 实现 | 成本（1080p/帧，A15 估） |
|---|---|---|
| 光晕 halation | 高光阈值 → 1/2 或 1/4 降采样 → 可分离高斯（σ 由 `halationSpatialScale`/μm 换算）→ 暖色 tint → 加法合成；多 bounce 用 2–3 次模糊叠加近似 | 1–2 ms |
| 柔光 diffusion | 与光晕共享 bloom 金字塔，按 `strength/spatialScale/haloWarmth` 调节 | 复用上者 |
| 印相/胶片眩光 | 低分辨率 bloom，按 `percent/roughness/blur` 合成 | 0.3–0.8 ms |
| 扫描 USM | 可分离 3×3/5×5 unsharp，沿亮度通道 | 0.3–0.8 ms |
| 镜头模糊 | v1 不做（视频上代价高、收益低），保留开关但置灰并说明 | — |

- bloom 在 1/2 或 1/4 分辨率做，合成时双线性放大；光晕本身是低频，肉眼几乎无损。
- 所有空间 Pass 在 10-bit 线性域运算，最后统一编码。
- 颗粒不进入任何空间 Pass，避免被模糊掉；这是“颗粒不分开”的硬约束。

---

## 6. 视频 I/O 与编码

### 6.1 解码

- `AVAssetReader` + `AVAssetReaderTrackOutput`，`alwaysCopiesSampleData = false`。
- 通过 `AVAssetReaderVideoCompositionOutput` 应用 `preferredTransform`，统一方向；输出 10-bit YUV（`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`）。
- v1 只接受 SDR Rec.709；检测到 PQ/HLG 直接提示“暂不支持 HDR”，不做隐性 tone map。
- 变帧率：保留原始 PTS，不重定时；引擎逐帧独立，不依赖固定步长。

### 6.2 颜色

```
YCbCr(10-bit, video range)
  → RGB(0…1, Rec.709)
  → Rec.709 EOTF
  → 线性 Rec.709
  → 3×3 矩阵 → 线性 ProPhoto
  → LUT 链
  → 线性 sRGB
  → Rec.709 OETF
  → RGB → YUV(10-bit, video range)
```

- `VideoColorIO` 负责矩阵、range 缩放、EOTF/OETF；不要把“sRGB 近似”写死，否则暗部会偏。
- 输出写入 `AVVideoColorPropertiesKey`：`ITU_R_709_2` primaries / transfer / matrix。
- 8-bit 输入可以走同一链路，但输出仍用 10-bit 编码，减少断层。

### 6.3 编码

v1 两档：

| 档位 | 编码 | 码率 | 60 秒大小 | 用途 |
|---|---|---|---|---|
| 标准 | HEVC Main10 | 40 Mbps | ≈300 MB | 日常分享 |
| 高 | HEVC Main10 | 60 Mbps | ≈450 MB | 保留颗粒 |
| 母版（macOS） | ProRes 422 LT | ≈102 Mbps | ≈765 MB | 后续剪辑/转码 |

- `AVAssetWriter` 设置：
  - `AVVideoCodecKey = .hevc`
  - `AVVideoProfileLevelKey = AVVideoProfileLevelH265Main10AutoLevel`
  - `AVVideoAverageBitRateKey = 40_000_000 / 60_000_000`
  - `AVVideoMaxKeyFrameIntervalKey = 2 × fps`
  - `AVVideoExpectedSourceFrameRateKey = 源 fps`
  - `AVVideoColorPropertiesKey = Rec.709`
- 音频：`AVAssetReaderTrackOutput` 读出，`AVAssetWriterInput` 以 `outputSettings: nil` 直通；无音轨时跳过。
- 不使用 AV1 FGS：
  - 13 Pro 无硬件 AV1 编码；
  - FGS 是解码端重建颗粒，文件本身没有颗粒，分享/转码后不保证保留；
  - 与“颗粒不分开”的产品要求冲突。
- 码率与颗粒的取舍要在 UI 明示：20 Mbps 以下颗粒会被编码器磨平，不提供“低码率但颗粒完整”的假承诺。

### 6.4 文件与元数据

- 容器：`.mov`（HEVC 10-bit 兼容性最好）。
- 文件命名：`<原名>-film-<yyyyMMdd-HHmmss>.mov`。
- 保留源旋转、时长、帧率、音频；色彩标签写 Rec.709。
- 导出前显示预估大小：`码率 × 时长 / 8`，允许用户取消。

---

## 7. iOS 端方案

### 7.1 入口

- 主页顶部或底部动作区新增「视频显影」入口，进入 `MVideoScreen`。
- 导入：
  - `PhotosPicker(matching: .videos)`；
  - `fileImporter` 支持 Files 中的 `.mov/.mp4`；
  - 需要新增 `NSPhotoLibraryUsageDescription`（读取视频），现有只有 `NSPhotoLibraryAddUsageDescription`（写入）。
- 导入后复制到沙盒 `Documents/Spektrafilm/Videos/<projectID>/source.mov`，避免相册资源被用户删除后工程失效。

### 7.2 视频工程模型

```swift
struct MVideoProject: Codable {
    var id: String
    var displayName: String
    var sourcePath: String
    var duration: Double
    var fps: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var edit: PhotoEdit              // 胶片/相纸/快速轴/专业参数
    var referenceTime: Double        // 测光参考帧
    var createdAt: Date
}
```

- 复用 `PhotoEdit`，不新建第二套参数模型。
- `MVideoProjectStore` 独立于 `LibraryStore`，避免视频污染照片库；JSON 落盘，缩略图单独缓存。
- 参数变更只改工程，不立刻重渲染；用户点「预览」或停手 0.4 s 后刷新代理片。

### 7.3 预览

- v1 用**代理片**，不做实时播放：
  - 540p、24fps、3–5 秒，从片段中间截取；
  - 参数变更后防抖 0.4 s，后台重渲染代理片；
  - `AVPlayer` 循环播放，支持原片/成片切换。
- 代理片成本：120 帧 × 1–2 ms + HEVC 编码 ≈ 2–4 秒；对 13 Pro 可接受。
- 预览必须包含颗粒与光晕，否则用户看到的和导出不一致；代理片可以降低分辨率，但不能关效果。

### 7.4 导出

- 流程：
  1. 锁定参考帧测光，烘焙 65³ LUT（约 1–2 秒，显示进度）。
  2. `AVAssetReader` 逐帧解码 → Metal → `AVAssetWriter`。
  3. 每 1% 或每 24 帧回调一次进度（帧号、百分比、预计剩余）。
  4. 完成后写入系统相册（`PHAssetCreationRequest.addResource(with: .video, ...)`），并保留沙盒文件供分享。
- 进度条必须分字段：`exportLabel`（阶段）+ `exportProgress`（帧/总数），不要复用预览的 `phaseLabel`。
- 取消：`VideoExporter.cancel()` 在下一帧边界退出，200 ms 内响应；删除临时文件。
- 后台：iOS 不允许长时间后台 GPU；导出时关闭自动锁屏，提示“请保持 App 在前台”。进入后台时暂停并保留帧号，回前台续算；`beginBackgroundTask` 只用于收尾写文件，不作为长任务依赖。
- 热状态：监听 `ProcessInfo.thermalState`；`.serious` 时暂停并在 UI 提示，`.critical` 时强制停止并保留进度。

### 7.5 机型门槛

- v1 最低 iOS 17 / A14；推荐 iPhone 13 Pro 及以上。
- 1080p 全链路内存在 150–250 MB，6 GB 机型无压力；旧机型先做 720p 降级。
- 4K 不在 v1；后续按 GPU 能力与热状态分档。

### 7.6 iOS 文件改动清单

| 文件 | 改动 |
|---|---|
| `SpektraMobile/Sources/Screens/MVideoScreen.swift` | 新增：导入、预览、胶片/相纸/快速轴、导出面板 |
| `SpektraMobile/Sources/Engine/MVideoSession.swift` | 新增：`@MainActor` 会话，持有 `MVideoProject` 与 `VideoExporter` |
| `SpektraMobile/Sources/Screens/HomeScreen.swift` | 修改：新增视频入口 |
| `SpektraMobile/Sources/Screens/MobileRootView.swift` | 修改：新增 `.video` 屏幕与转场 |
| `SpektraMobile/Sources/Models/MobileModels.swift` | 修改：如需视频专用设置项，放这里，避免新文件 |
| `SpektraMobileApp/Info.plist` / `project.yml` | 修改：新增 `NSPhotoLibraryUsageDescription` |
| `SpektraMobileApp/SpektraMobile.xcodeproj` | 修改：登记新文件；建议安装 xcodegen 后 `xcodegen generate` |

---

## 8. macOS 端方案

### 8.1 入口

- `EngineRootView` 新增 `.video` 屏幕，或 Library 顶部加「视频」分段。
- 导入：
  - `NSOpenPanel` 允许 `.movie/.mpeg4Movie/.quickTimeMovie`；
  - 支持把视频拖进窗口；
  - 导入后复制/引用源文件，建立 `VideoProject`。
- 视频工程与 iOS 共用 `VideoProjectStore` 格式；macOS 可以直接打开 iOS 工程目录（可选，v1 不做同步）。

### 8.2 视频台

- 布局复用 `EditorView`：
  - 左侧/底部：视频列表与批量选择；
  - 中央：代理片播放器 + 时间轴 scrub；
  - 右侧：胶片/相纸/快速轴/专业参数，复用现有 Inspector；
  - 顶部：原片/成片切换、导出。
- 预览：
  - 720p 代理片，3–5 秒，参数变更 0.3 s 防抖；
  - 可选「全片低清预览」：540p 全片渲染到临时文件，适合长片检查。
- 参数模型与 iOS 完全一致，保证同一 `PhotoEdit` 在两端出片一致。

### 8.3 导出

- 格式：
  - HEVC 10-bit（40/60 Mbps）；
  - ProRes 422 LT（母版，便于后续剪辑）。
- 分辨率：v1 1080p；4K 作为 M6 之后的扩展，需单独做 GPU 性能与显存门禁。
- 输出：用户选择文件夹；命名规则同 iOS；可选同时写入照片 App（通过 `PHPhotoLibrary`，macOS 14 支持）。
- 批量：
  - 多选视频 → 同一 `PhotoEdit` 批量导出；
  - 串行队列，逐条显示进度；
  - 失败不阻塞后续，生成失败清单。
- 性能：
  - M1 60 秒 1080p24 预计 8–15 秒端到端；ProRes 编码略慢于 HEVC，但仍远快于实时。
  - 可选「高质量」档：65³ LUT、全分辨率光晕、ProRes LT；不改变算法，只提高空间效果精度。

### 8.4 macOS 文件改动清单

| 文件 | 改动 |
|---|---|
| `SpektraSkin/Sources/SpektraSkin/Screens/VideoView.swift` | 新增：视频库 + 播放器 + 时间轴 + 参数面板 |
| `SpektraSkin/Sources/SpektraSkin/Engine/VideoHost.swift` | 新增：`@MainActor` 会话，桥接 `VideoExporter` |
| `SpektraSkin/Sources/SpektraSkin/Screens/EngineRootView.swift` | 修改：新增 `.video` 屏幕 |
| `SpektraSkin/Sources/SpektraSkin/Screens/Library/LibraryView.swift` | 修改：新增视频导入/拖放入口 |
| `build.sh` | 修改：补 `-framework AVFoundation -framework VideoToolbox -framework CoreMedia` |
| `Sources/SpektraCore/Video/*` | 新增：共享核心，`build.sh` 自动 glob，无需登记 |

---

## 9. 性能预算

### 9.1 单帧预算（1080p）

| 环节 | M1 实测/估算 | iPhone 13 Pro 估算 |
|---|---|---|
| 四段 LUT + 密度域颗粒 | 0.42–0.48 ms | 0.8–1.2 ms |
| 光晕/柔光 bloom（半分辨率） | 0.4–0.8 ms | 0.8–1.6 ms |
| USM + YUV 输出 | 0.2–0.4 ms | 0.4–0.8 ms |
| 解码（硬件） | 1–2 ms | 2–4 ms |
| 编码（硬件） | 2–5 ms | 3–8 ms |
| 合计 | **4–9 ms** | **7–16 ms** |

### 9.2 整段预算（60 秒 24fps = 1440 帧）

| 端 | 纯渲染 | 端到端 |
|---|---|---|
| M1 Mac | 0.6–1.3 秒 | 6–15 秒 |
| iPhone 13 Pro | 1.2–2.3 秒 | 15–40 秒（保守 60 秒） |

- 以上是“LUT + 颗粒 + 光晕 + HEVC”的预算，不含 4K、不含 ProRes。
- 真实数字必须在 13 Pro 上跑 24 帧与 60 秒两条基准后回填；本方案中的 iPhone 数字是按 A15/M1 比例外推，误差可能 ±40%。

---

## 10. 质量门禁与验收

### 10.1 颜色

- GPU vs CPU LUT：8-bit `max Δ ≤ 1/255`，10-bit `max Δ ≤ 2/1023`。
- 与照片导出的同一帧对比：肉眼无明显色偏；允许因 10-bit/色域转换产生 ≤1 级差异。
- 渐变测试图（灰阶、肤色、天空）无带状断层；必要时在输出前加 ±0.5 LSB 蓝噪声抖动。

### 10.2 颗粒

- 低/中/高三个亮度块的颗粒 σ 与自相关长度落在物理模型 ±10%。
- 24 帧连续播放：颗粒逐帧变化，无静态图案、无闪烁式整体明暗跳动。
- 100% 与 200% 放大 A/B：颗粒形态与物理单帧同向，不出现“数字雪花”或“块状噪声”。

### 10.3 光晕/空间效果

- 高光测试图（灯泡、窗边、金属反光）与物理单帧对比：光晕范围、暖色偏移方向一致。
- 半分辨率 bloom 在 1080p 输出上看不到明显块边界。

### 10.4 工程

- 24 帧 1080p：iOS ≤3 秒，macOS ≤1 秒（纯渲染）。
- 60 秒 1080p24：iOS 端到端 ≤60 秒；macOS ≤20 秒。
- 5 分钟视频：内存峰值 <300 MB，无逐帧增长；取消 200 ms 内生效。
- 切后台/回前台：能续算，不重复已完成帧。
- 输出文件在照片 App、QuickTime、系统分享中可正常播放；音频同步、旋转正确、时长/帧率一致。

---

## 11. 里程碑

| 阶段 | 交付 | 通过条件 |
|---|---|---|
| M0 | `VideoLUTPayload` + Metal 单帧渲染器 | 1080p 单帧 GPU vs CPU LUT 门禁通过；M1 单帧 ≤1 ms |
| M1 | 24 帧 AVAssetReader/Writer 导出（无音频） | 24 帧 HEVC 10-bit 可播放；13 Pro 计时回填 |
| M2 | 密度域颗粒 + 逐帧种子 + 参数标定 | 三亮度块统计 ±10%；24 帧无静态颗粒 |
| M3 | 光晕/柔光/USM | 高光测试图通过；单帧总成本 ≤16 ms（A15 估） |
| M4 | iOS 视频台（导入/代理预览/导出/相册） | 13 Pro 60 秒端到端 ≤60 秒；切后台可续算 |
| M5 | macOS 视频台（拖放/批量/ProRes） | M1 60 秒 ≤20 秒；批量失败不阻塞 |
| M6 | 验收报告 | 颜色/颗粒/性能/稳定性四项全过；形成基准数据 |

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| LUT 代理与物理导出有色差 | 用户认为“视频和照片不是同一套胶片” | 65³ + 四面体；GPU vs CPU 门禁；同一 `PhotoEdit` 参数 |
| 程序化颗粒不像胶片 | 核心卖点失真 | 先拟合物理统计，再做视觉 A/B；不允许直接上白噪声 |
| 逐帧自动测光导致呼吸 | 整段视频明暗跳动 | 参考帧测光 + 全片锁定；UI 不提供逐帧自动曝光 |
| 正片（scanFilm）无法走 LUT | 正片用户不可用 | v1 明确只支持负片；v2 增加 scan-film LUT 或物理回退 |
| iOS 后台被挂起 | 长片导出中断 | 前台导出提示、关闭自动锁屏、按帧断点、回前台续算 |
| 热降频 | 长片越跑越慢 | 监听 `thermalState`；`.serious` 暂停；分块导出 |
| 10-bit HEVC 兼容性 | 个别平台无法播放 | v1 提供 8-bit H.264 兼容档（可选）；默认 HEVC 10-bit |
| 码率不足磨平颗粒 | 用户觉得“导出后颗粒没了” | 40/60 Mbps 两档；导出前显示预估大小与颗粒保留说明 |
| 旋转/可变帧率/音频同步 | 成片方向或音画错位 | `AVAssetReaderVideoCompositionOutput` 统一方向；保留 PTS；音频直通 |
| 4K/长片内存 | 峰值升高 | v1 只做 1080p；流式 2–3 帧；像素缓冲池 |

---

## 13. 待确认决策

| # | 议题 | 建议默认 |
|---|---|---|
| 1 | v1 是否做 4K | 不做，M6 后再评估 |
| 2 | 帧率策略 | 保留源帧率（23.976/24/25/30），不重定时 |
| 3 | 输出落点 | iOS：相册 + 分享；macOS：文件夹，可选相册 |
| 4 | 默认码率 | 高：60 Mbps；标准：40 Mbps |
| 5 | 正片是否在 v1 | 不支持；UI 明确提示 |
| 6 | 颗粒强度默认值 | 跟随照片预设的 `grain_amount`，不额外加 |
| 7 | macOS 是否保留 ProRes | 保留；作为母版选项 |
| 8 | 视频工程是否进照片库 | 不进；独立 `VideoProjectStore` |

---

## 14. 附：关键参考

- 四段 LUT 烘焙与查表：`Sources/SpektraCore/Services/PreviewLUTService.swift`
- LUT 键与连续轴归零：同文件 `cacheKey`
- 物理颗粒：`Sources/SpektraCore/Model/Grain.swift`
- 显影管线：`Sources/SpektraCore/Runtime/Pipeline.swift`
- 照片导出基线：`docs/engineering/baseline-report.md`
- iOS 入口与根导航：`SpektraMobile/Sources/Screens/MobileRootView.swift`、`HomeScreen.swift`
- macOS 入口：`SpektraSkin/Sources/SpektraSkin/Screens/EngineRootView.swift`
- macOS 构建：`build.sh`（已链接 Metal，需补 AVFoundation/VideoToolbox/CoreMedia）
- iOS 工程源：`SpektraMobileApp/project.yml`（`Sources/SpektraCore` 整目录纳入）
