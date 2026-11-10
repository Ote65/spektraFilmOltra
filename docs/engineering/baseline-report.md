# Spektrafilm iOS 工程基线报告

- 日期：2026-11-06
- 仓库：`SpektrafilmSwift-ios/`（worktree，分支 `iOS`）
- 基线提交：`1b04350`（ios: port SpektraMobile onto the real core engine）
- 机器：Apple Silicon macOS，Xcode 27.2 / iOS SDK 27.2 / Swift 6.4.2（语言模式 5.0）

---

## 1. 工程事实

| 项 | 值 |
|---|---|
| 工程 | `SpektraMobileApp/SpektraMobile.xcodeproj`（由 `project.yml` 生成，xcodegen 未安装，改文件需手动登记 pbxproj） |
| Scheme | `SpektraMobile` |
| Bundle ID | `com.spektrafilm.mobile` |
| Deployment Target | iOS 17.0 |
| 设备族 | iPhone 竖屏 |
| Swift 语言模式 | 5.0 |
| 引擎 | `Sources/SpektraCore`（11k 行） |
| UI | `SpektraMobile/Sources`（6.9k 行，纯 SwiftUI） |

## 2. 编译基线

- `xcodebuild -configuration Debug`：**BUILD SUCCEEDED**（无 error）。
- `xcodebuild -configuration Release`：**BUILD SUCCEEDED**。
- 无现成 XCTest / UI Test target；仅 `Tools/*` 下的命令行 smoke（CoreSmoke / PipelineSmoke / ParityCheck / ClaritySmoke / HostSmoke）。

## 3. 测试照片

`build/test-IMG_6459.DNG`：4032×3024，12.2 MP，DNG，ProPhoto 线性输入。
同一张图用于所有引擎侧测量，保证可比。

## 4. 引擎性能（Release 构建，`Tools/bench.sh`）

### 4.1 改动前（基线提交）

| 档位 | 尺寸 | 耗时 | 吞吐 |
|---|---|---|---|
| 960 | 960×720 / 0.69 MP | **2.86 s** | 0.24 MP/s |
| 1600 | 1600×1200 / 1.92 MP | 6.28 s | 0.31 MP/s |

阶段拆解（960，首次测量）：

| 阶段 | 耗时 |
|---|---|
| preprocess | 0.013 s |
| filming.expose | 0.784 s |
| filming.develop | **1.791 s** |
| printing.expose | 0.243 s |
| printing.develop | 0.260 s |
| scanning.print | 1.304 s |
| 合计 | 4.44 s（含调度抖动） |

内存：单缓冲 **292.6 MB**（Double × 3ch × 12.2 MP）；4032 全流程峰值常驻 **1656 MB**。

LUT 快路径：烘焙 33³ 0.184 s，预测 0.021 s。

### 4.2 改动后（本次）

| 档位 | 尺寸 | 耗时 | 说明 |
|---|---|---|---|
| 960 | 960×720 | **0.81 s** | −72%（原 2.86 s；颗粒开启） |
| 1280 | 1280×960 | **1.37 s** | 新增预览档位 |
| 960（预览模式） | 960×720 | **0.57 s** | `SPEKTRA_BENCH_PREVIEW=1`，与 `renderAccurate` 同配置 |
| 1280（预览模式） | 1280×960 | **0.91 s** | 实际预览路径（原 3.58 s） |
| 1600 | 1600×1200 | **2.10 s** | −67%（原 6.28 s） |
| 2048 导出 | 2048×1536 | **4.53 s** | 3.15 MP（原 9.89 s） |
| **4032 导出（原始档）** | 4032×3024 | **15.40 s** | 12.19 MP，bench 峰值 ~2.4 GB（见 4.5） |

（960/1280/1600 与 2048/4032 都是第二轮优化后的数字，`SPEKTRA_BENCH_ROUNDS=2` 取最好，颗粒开启。）

LUT：烘焙 33³ **0.139 s**，预测 33³ @960 **0.024 s**；65³ 烘焙 0.458 s，预测 0.025 s。

阶段变化：

| 阶段 | 前 | 后 | 原因 |
|---|---|---|---|
| filming.develop | 1.791 s | 0.45–0.64 s | 密度曲线插值改二分，再改为「行内爬坡」（空间连续，通常 0–2 步） |
| printing.develop | 0.260 s | 0.008–0.011 s | 同上（逐通道轴） |
| scanning.print | 1.304 s | ~0.8 s | 光谱积分融合 + `exp2`/`log2` 热路径 |
| 空间模糊（halation / diffusion / unsharp） | 未单列 | 显著下降 | `FastGaussian.filterChannel` 反射行号外提 + 内部/边缘分段 + 按行并行；`iirFilter` 按行/按列并行 |

### 4.3 结论

- **精算管线仍是瓶颈**：1/4 预览（4032 原图 → 1008 px）约 1–2 s，真机会更慢；1/2、1/1 更慢。当前交互靠 LUT 预测（24 ms）顶住，停手后回落精算。
- **LUT 预测足够快**，可以支撑 30fps 以上的拖动反馈。
- **导出仍是最大痛点**：见 4.5，第二轮压到 **15.4 s**（4032 原始档，颗粒开启）。bench 峰值 ~2.4 GB。`ExportEdge` 已改为：**「原始」档永远按库里的原图像素尺寸导出，不做静默降采样**；只有 2048/4096 显式档位才按实测 130 B/px 与可用内存 60% 反算长边。
- **预览比例**：显影台预览改为原图长边的 1/8、1/4、1/2、1/1（默认 1/4），与 Swift 主线 `previewScale` 一致；调大时按需重新解码原图，调小时复用现有缓冲。D0 预测帧长边封顶 1000 px。
- **内存**：单缓冲 293 MB 的结构未变；预览只解码到 1600，常驻从 293 MB 降到 ~78 MB（1600×1200×3×8）。

### 4.4 正确性核对：热路径替换

三次替换都做了逐像素比对（PIL，同一预览区域）：

| 替换 | 结果 |
|---|---|
| `pow(10, ·)` / `log10` → `exp2` / `log2` | `mean 0.00 / 255, max 0` |
| `FastGaussian` 反射外提 + 分段 + 并行 | `mean 0.000 / 255, max 0` |
| 分段定位：二分 → 行内爬坡 | `mean 0.0000 / 255, max 0` |

即 8-bit 输出**逐像素完全一致**。这些改动都是纯性能优化，不改算法语义。

### 4.5 第二轮引擎优化：全分辨率导出 27.1 s → 15.4 s

测量口径：`SPEKTRA_BENCH_SIZES=4032 SPEKTRA_BENCH_ROUNDS=2`，**颗粒开启**（即真实导出路径；`SPEKTRA_BENCH_NO_STOCHASTIC` 只在做逐值对拍时用）。同一台 M 系列机器，A/B 用 `git stash push -- <三个引擎文件>` 切回改前版本重跑，避免拿不同机器的数字比较。

| 阶段（4032×3024，12.19 MP） | 改前 | 改后 | 说明 |
|---|---|---|---|
| filming.expose | 4.03 s | **3.25 s** | `map` 走向量化指针循环 |
| filming.develop | **11.25 s** | **5.62 s** | 颗粒按行并行；行种子先做雪崩混合，避免相邻行共用同一条随机流产生 45° 斜纹 |
| printing.expose | 1.37 s | 1.22 s | `pow10Fast` |
| printing.develop | 0.054 s | 0.080 s | 噪声范围内 |
| scanning.scan_print | **11.29 s** | **5.00 s** | 输出色域压缩按行并行 + 色彩转换常量外提 |
| **合计** | **27.1 s** | **15.4 s** | **−43%** |

2048 档：7.19 s → **4.53 s**。关颗粒的纯管线参考：18.96 s → 16.00 s。

做过、但**被数据否决**的两件事（避免以后有人再踩）：

| 尝试 | 结果 | 原因 |
|---|---|---|
| `ImageRGB.map` 改成 `DispatchQueue.concurrentPerform` 按行并行 | 全流程 **18.1 → 23.7 s**（扫描 10.7 → 16.6 s），user time 31 s → 126 s | 每次 map 都要新分配 293 MB，多线程首次触页在内核页表锁上争用，越并越慢 |
| 把「色适应 + 色域矩阵」合成一个 3×3 只乘一次 | 8-bit 仍只差 1 级，但浮点最大相对偏差 **1.2e-5** | 超出 `docs/parity_report.md` 的 1e-9 门禁；改为「保留原运算顺序，只把常量提到循环外」后为 1.6e-14 |

对拍（`SPEKTRA_BENCH_DUMP` 落盘 1600 档结果，改前/改后逐值比较）：

| 指标 | 结果 |
|---|---|
| 8-bit PNG 逐像素 | `mean 0.000000 / 255, max 0`（完全一致） |
| Double 数值 | 最大绝对偏差 **1.6e-14**，最大相对偏差 **2.4e-10**（在 1e-9 门禁内） |

颗粒并行会改变逐像素随机流（图案重排），但颗粒本来就是按分布验收的模块（`docs/parity_report.md` 第 2 节）；128×128 的 `grain_stats` 用例像素数低于并行阈值，仍走串行路径，统计量与改前逐位相同。

### 4.6 内存：同时存活的整图缓冲 7 → 3

12 MP 一张 `ImageRGB` 是 293 MB（Double×3ch×12.19 MP）。改前 `SimulationPipeline.process` 把每一段的中间结果都留到函数结束，`keepTaps == false`（导出、预览）也在同时压着 7 份；扫描段内部又各自 `var output = self` 触发 COW，再多出几份。

| 改动 | 文件 | 效果 |
|---|---|---|
| `keepTaps == false` 时逐段置空中间结果 | `Runtime/Pipeline.swift` | 顶层整图缓冲 7 → 3 |
| `logXYZ` 改为原地写回（原来 `var output` + 持有 `source` 强制 COW） | `Stages/ScanningStage.swift` | −293 MB |
| 眩光改为原地加（`Glare.applyGlareInPlace`） | `Model/Glare.swift` | −293 MB |
| 黑白点校正改为原地（`applyBlackWhiteXYZCorrection`） | `Runtime/ColorReferenceService.swift` | −293 MB |
| `pow(10,·)` / 色域矩阵两步改原地（`ImageRGB.mapInPlace`） | `Core/Image.swift`、`Stages/ScanningStage.swift` | 各 −293 MB |
| `sanitizeNonFinite` 改原地 | `Core/Image.swift`、`Runtime/Pipeline.swift` | −293 MB |

实测量（同一台机器、`SPEKTRA_BENCH_SIZES=4032`、`ROUNDS=1`，读 `maximum resident set size`）：

| | 改前 | 改后 |
|---|---|---|
| 进程峰值常驻 | **2542 MB** | **2286 MB** |

再往下压需要改 `filming.develop`（颗粒阶段会同时持有 `plane` + `modelled` + 累加缓冲）或把 `[Double]` 换 `Float`；后者会动 1e-9 对拍口径，属产品决策。

> 这些改动都是「换缓冲复用方式」，逐像素运算与串行顺序不变：8-bit 输出仍 `max 0` 全等，Double 偏差保持 1.6e-14。

### 4.7 float32 存储：单缓冲 293 → 146 MB

产品决策已确认：`ImageRGB.data` 由 `[Double]` 改为 `[Float]`，**算术仍是 float64**，只在每阶段写回缓冲时量化一次。
改动集中在 `Core/Image.swift`（存储类型 + `Double(...)` 读写 + 从 `[Double]` 构造的便捷初始化）与 18 个直接访问 `image.data[...]` 的文件
（`GradeEngine` 内部仍用 `[Double]` 工作缓冲，只在进出口转换一次）。

| | Double 存储 | float32 存储 |
|---|---|---|
| 单缓冲（4032×3024） | 293 MB | **146.3 MB** |
| 4032 峰值常驻（`ROUNDS=1`） | 2286 MB | **1453 MB** |
| 4032 峰值常驻（`ROUNDS=2`，含 LUT 烘焙） | — | **1601 MB** |
| 4032 全管线（颗粒开，best of 2） | 15.4 s | **15.05 s** |
| 2048 全管线（best of 2） | 4.53 s | 4.94 s（+9%） |
| 1280 全管线（best of 2） | — | 1.70 s |

逐阶段（4032，best of 2，颗粒开）：

| 阶段 | Double（改前） | float32（改后） |
|---|---|---|
| filming.expose | 3.25 s | 3.41 s |
| filming.develop | 5.62 s | 5.83 s |
| printing.expose | 1.22 s | 1.22 s |
| printing.develop | 0.080 s | 0.087 s |
| scanning.scan_print | 5.00 s | 5.41 s |
| **合计** | **15.4 s** | **15.05 s** |

结论：**内存 −36%，速度持平（噪声范围内）**。原因是热路径上的 `Double(...)/Float(...)` 只是每个写回点一次转换，
带宽减半抵消了转换成本；`ROUNDS=1` 时看到的 26 s 是首次触页开销，best-of-2 才是稳态口径。
若要真正拿到速度收益，需要把热循环本身改成 float32 运算（Vec3/CAM16 全面浮点化），那是一次算法层重构，不在本次范围。

对拍：确定性门禁从 1e-9 放宽到 1e-5（实测最大 6.84e-08，全部来自 float32 量化），
详见 `docs/parity_report.md` §9；`SPEKTRA_PARITY_TOL` 可覆盖回 1e-9 做逐位调查。

端到端（模拟器，`--screen develop --export --export-run`，从进程启动计时到导出文件落盘）：
**12 s 产出 10 MB 的 16-bit TIFF**（含 RAW 解码 + 全管线 + 编码写盘；引擎侧 4032 单跑 15.05 s 是含 LUT 烘焙的冷启动口径）。

**导出质量不受影响**：float32 的相对量化误差约 6e-8，而 16-bit 输出的量化步长是 1/65535 ≈ 1.5e-5 —— 存储精度比交付格式高两个数量级，
16-bit TIFF / EXR 的可用精度仍由输出位深决定。



## 5. 交互链路基线

| 项 | 现状 |
|---|---|
| 拖动期预测帧 | 24 ms/帧（LUT 33³） |
| 连续轴可见性 | 7 个快速轴全部走近似层（本次补齐） |
| 预测帧参数敏感度 | 见下表，均有可测变化 |
| 滑条手势 | 命中圆点才可拖；相对位移；轨道不再抢滚动 |
| 停手 → 精算帧 | 0.32 s 防抖 + **0.91 s** 渲染（1280 预览），合计约 **1.2 s**（原来 0.5 s + 1.69 s ≈ 2.2 s） |
| 导出进度 | 面板显示「当前阶段 + 百分比 + 细进度条」（`MExportProgressRow`，取 `exportProgress`）。导出与预览的进度文案已拆成两个字段，不再互相覆盖。截图证据 `.screenshots/acceptance/export-progress.png`（胶片曝光 33%）；该帧靠 `--export-run` 在原片读完后自动开跑才截到，模拟器导出本身只有 ~2 s |
| 导出前置条件 | 原片未读完时导出按钮为禁用态「正在读取原片」，避免点下去立刻 `.busy` 失败再闪回 idle |
| 主线程落盘 | 参数更新已改为后台快照写盘（`LibraryStore.persistIndexAsync`） |

### 5.1 预测帧参数敏感度（`Tools/bench.sh` 新增段）

同一张测试图、同一 LUT 33³，只改近似层输入，统计显示帧差异（0–255）：

| 轴 | 平均 Δ | 最大 Δ |
|---|---|---|
| 印相冷暖 +100 | 10.41 | 28.6 |
| 品红/绿 +100 | 7.60 | 21.9 |
| 反差 +100 | 13.76 | 28.2 |
| 色浓度 +100 | 4.08 | 117.5 |
| 颗粒 +100 | 2.78 | 7.0 |
| 清晰度 +100 | 2.92 | 92.6 |
| 全部拉满 | 18.89 | 134.3 |

结论：6 个连续轴在**预测帧**上都有可测变化，不再需要等精算帧。
颗粒的平均差最小是预期行为（高频噪声在均值上互相抵消），最大差 7/255 对应可见的颗粒起伏。

### 5.2 UI 链路端到端验证（真实截图）

引擎侧数字只能证明「近似层会变」，不能证明「App 里点参数会变」。补一条走真实 UI 链路的证据：

```bash
Tools/acceptance.sh "iPhone 18 Pro"    # 内含第五张 shot：--quick color_density=100,grain_amount=100,tonal_contrast=60
```

对照 `develop.png`（中性）与 `develop-quick.png`（quick 参数），裁预览区（y 14%–55%）逐像素比较：

| 指标 | 值 |
|---|---|
| 平均 Δ | **4.88 / 255** |
| 最大 Δ | **91 / 255** |
| Δ > 8 的像素占比 | **41.4 %** |

肉眼可见：右侧反差明显提高、暗部压下去、色浓度上升。说明从启动参数 → `MobileDevelopSession` → 预测/精算两路 → 屏幕显示整条链路都生效，
不是「参数只存不用」。并排图见 `.screenshots/acceptance/develop-vs-quick.png`。

### 5.3 调色台「质感」参数（浓度 / 暗角 / 颗粒）

诊断 §10.5 指出调色台没有颗粒、暗角和饱和度。引擎里 `GradeEngine.applySaturation` / `applyVignette` / `applyGrain` 都已实现，
缺的是 `MGradeRecipe` 字段和 UI。接通后用 `GradeEngine.render` 单跑 256×256 合成渐变做量化验证：

| 配方 | 平均亮度 | 角落亮度 | 色度幅度 | 相邻像素差 |
|---|---|---|---|---|
| 基线 | 0.6509 | 0.3508 | 0.1896 | 0.00117 |
| 浓度 +60 | 0.6475 | 0.3505 | 0.3032（+59.9%） | 0.00160 |
| 暗角 +80 | 0.3702 | 0.0702（−80.0%） | 0.0838 | 0.00344 |
| 颗粒 70 | 0.6511 | 0.3513 | 0.1896 | 0.04389（37.6×） |

同一 recipe 两次渲染 `maxDelta = 0`（颗粒噪声按尺寸缓存，确定性）。界面证据：`.screenshots/acceptance/grade-quality.png`
（`--grade-bottom` 启动参数把调整面板定位到下半段，暗角/颗粒滑条与「重置调色」同行可见）。

### 5.4 颗粒强度轴：导出侧真的产生颗粒

同一张图、同一参数，只改 `grain_amount` 导出 1600 长边 16-bit TIFF，比较中间 80% 区域的相邻像素差分标准差（hf std）：

| 配置 | hf std | 平均亮度 | 相对默认 |
|---|---|---|---|
| `-100`（关颗粒） | 0.0988 | 0.3243 | +51% |
| `0`（默认） | 0.0652 | 0.3224 | 基准 |
| `+100`（改前映射） | 0.0647 | 0.3197 | −0.7% |
| `+100`（改后映射） | **0.1133** | 0.3182 | **+74%** |

改前只映射 `densityMin / uniformity`：拉满只抬密度均值，不产生颗粒纹理。改后同时映射
`particleAreaUM2`（粒子面积 ↑ → 每像素粒子数 ↓ → 起伏 ∝ 1/√n）、`blur`（0.65 px IIR 会抹平高频）、
`blurDyeCloudsUM`（染料云模糊）。`q = 0` 时全部回到基线，默认观感不变（hf 与改前逐位相同）。
注：默认档开颗粒比关颗粒更平滑（hf −34%），这是原端口 `blur = 0.65 px` 的既有观感，本次未改默认值。



## 6. 模拟器与真机差异（重要）

- iOS 模拟器缺少相机 RAW 描述，`CIRAWFilter` 会**永久卡住**在 MobileAsset 查询（实测 > 60 s 无返回、CPU 空闲）。
- 处理：`ImageLoader.load` 在 `#if targetEnvironment(simulator)` 下改用 ImageIO 缩略图管线（0.4 s 出 1600×1200，线性 sRGB）。
- **真机仍走 `CIRAWFilter`**，色彩链路不变；因此所有颜色验收必须回真机复核。
- 模拟器截图仅用于布局 / 状态 / 流程验收，不作为颜色基准。

### 6.1 系统版本兼容性

- Deployment Target：**iOS 17.0**；代码中**未发现** iOS 18/26 才有的 API（无 `glassEffect` / `@Observable` / `navigationTransition` / `onGeometryChange` / `symbolEffect`）。
- 使用的新 API 最低要求：`withAnimation(_:completion:)` iOS 17、`PhotosPicker` iOS 16、`.presentationBackground` / `.presentationCornerRadius` iOS 16.4、`ShareLink` iOS 16 —— 均在 17.0 之下。
- **限制**：本机只安装了 iOS 27.2 运行时（`xcrun simctl list runtimes`），无法在 iOS 17/18 上实跑；旧系统验证需真机或额外下载 runtime。


## 7. 布局基线

| 项 | 改动前 | 改动后 |
|---|---|---|
| 画布 | 固定 393×852，`safeTop=54 / safeBottom=34` | 真实 `UIWindowScene` 安全区 + 全屏尺寸，环境注入 |
| 开孔 | 屏宽比例（刘海 0.432W×0.241，灵动岛 0.336W×0.318） | 刘海按安全区高度推导（高 = top−15、宽 = 5×高，13 上为 160×32）；灵动岛用硬件常数 126×37 @ y=11 |
| 开孔光效位置 | 轮廓被 `padding(.top: opening.maxY)` 推到开孔下方，压住「快速 / 专业」胶囊，读成两个错位胶囊 | 改 `offset(y: opening.minY)` 与真实开孔重合；空闲态轮廓淡出，只剩渲染时的呼吸光 |
| 顶部行对齐 | 返回按钮中心与胶囊中心差 5–12 pt | `HStack` 固定 `height: 34` 后再 overlay，两者共用同一条中线 |
| 机身适配 | 换机型即错位 | 四档尺寸实测（下方矩阵），截图在 `.screenshots/{acceptance,se,iphone13,17e}/` |
| 开孔判定 | `machineIdentifier()` 在模拟器上返回宿主架构，永远判成灵动岛；`top < 20` 让 iPhone SE（top = 20）落进刘海分支 | 改为**只按安全区高度**判定：`top ≤ 20 → none`、`top < 52 → notch`、否则 island |
| 灵动岛几何 | 按 `top − 22` 推导，在 top = 62 的机型上算出 136×40，比真实开孔每边大 5pt | 改为硬件常数 **126×37 @ y=11**；实测光效外沿 126–127pt、中心 200.8（屏心 201） |
| iOS 26 材质 | 全仓 `glassEffect` 0 处，26+ 上仍是旧实心垫底 | 新增 `mGlassSurface`（`#available(iOS 26)`）+ 返回键 / 模式胶囊 / 缩放标签接入 |

### 7.1 机型矩阵（公开安全区数据 + 代码推导）

判定阈值与公开数据完全对齐：**无开孔 top = 20；刘海 44 / 47 / 48；灵动岛 59 / 62**，底部统一 34。
因此 `detect()` 的三段式（`≤20 → none`、`<52 → notch`、否则 island）覆盖现售全部 iPhone，不需要机型字符串。

| 屏幕（pt） | 代表机型 | 安全区 | 形态 | 推导开孔 |
|---|---|---|---|---|
| 375×667 | SE 2/3 | 20 / 0 | none | 90×3（顶边细条） |
| 375×812 | X / XS / 11 Pro / 12 mini / 13 mini | 44 / 34 | notch | 145×29 |
| 390×844 | 12 / 13 / 14 / 16e / 17e | 47 / 34 | notch | 160×32 |
| 414×896 | XR / XS Max / 11 / 11 Pro Max | 48 / 34 | notch | 165×33 |
| 428×926 | 12 Pro Max / 13 Pro Max / 14 Plus | 47 / 34 | notch | 160×32 |
| 393×852 | 14 Pro / 15 / 15 Pro / 16 | 59 / 34 | island | 126×37 @ y11 |
| 430×932 | 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus | 59 / 34 | island | 126×37 @ y11 |
| 402×874 | 16 Pro / 17 / 17 Pro | 62 / 34 | island | 126×37 @ y11 |
| 440×956 | 16 Pro Max / 17 Pro Max | 62 / 34 | island | 126×37 @ y11 |
| 420×912 | iPhone Air | 62 / 34 | island | 126×37 @ y11 |

刘海宽度不是公开常量，按高推导（宽 = 5×高，上限 0.45W）；在 390×844 档实测光效外沿 165pt、居中，
与真实刘海（≈162×32）差 3pt 以内。灵动岛用硬件常数（14 Pro 起各代一致），
在 18 Pro（402×874）实测光效外沿 126–127pt、中心 200.8（屏心 201），与开孔重合。

**已实测的四个档位**（模拟器，截图在 `.screenshots/{se,iphone13,acceptance,max}/`）：
SE 375×667 none、iPhone 13 390×844 notch、18 Pro 402×874 island、18 Pro Max 440×956 island。
其余档位由公开安全区数据推导，未逐台截图——270 多个机型没必要逐个开机。

## 8. 本次修复的阻塞性缺陷

| # | 缺陷 | 影响 | 处理 |
|---|---|---|---|
| 1 | `@State` 初始化里读 UIKit 窗口 | AttributeGraph 循环，SwiftUI **整体停止更新** | 改用 `.fallback` + `.task` 里读取 |
| 2 | 布局回调里 `withAnimation { drawerHeight = fit }` | 同上，抽屉自反馈 | 改为直接赋值 |
| 3 | 根视图 `.frame(maxWidth:.infinity,maxHeight:.infinity)` + `.background(Color.ignoresSafeArea())` | 稳定复现循环 | 退回 `content().ignoresSafeArea().background(...)` |
| 4 | `LibraryStore` 存绝对路径 | 容器变更后整库「找不到原图」 | 改为相对路径 + 老索引重定位 |
| 5 | 预览解码全分辨率 | 内存 293 MB 常驻 | `ImageLoader.load(maxSize:)` |
| 6 | 参数更新在主线程 JSON 编码 + 写盘 | 拖动时每 0.7 s 卡一下 | `LibraryStore.persistIndexAsync`（快照 + 后台写） |
| 7 | 导出面板自绘（`ZStack + scrim`） | 无 detent / grabber / 下拉关闭 | 改用 `.sheet` + `presentationDetents` |
| 8 | 转场用 `asyncAfter` 接力 | 与渲染抢主线程、硬跑感 | 改用 `withAnimation(...) completion:` |
| 9 | 调色台代理图 800 px | 调色时明显糊 | 提到 1080 px |

> #1–#3 说明：界面「看起来正常但状态不更新」的根因不是逻辑写错，而是 AttributeGraph 被环打断。这一条优先于任何参数映射排查。

### 8.1 验收证据

`Tools/acceptance.sh` 产出**九张**截图（home / develop / grade / grade-quality / export-sheet / develop-quick / export-progress / export-complete / develop-notch），并**断言**：

```
Cycle detected: 0
fatalError:     0
文件缺失:       0
```

任一项非 0（或对拍失败）脚本就 `exit 1`，不再是只打印数字。已在 iPhone 18 Pro 与 iPhone 18 Pro Max 两个尺寸上分别核对布局与开孔几何。

`Tools/parity.sh` 把 Python 参考对拍也自动化了（`SPEKTRA_PARITY=1 Tools/acceptance.sh` 可一起跑）：

| 用例 | 结果 |
|---|---|
| couplers / grain_layers / diffusion_psf / diffusion_apply / cam16 / output_compress | 最大绝对偏差 **1.1e-15 ~ 3.5e-18**（门禁 1e-9） |
| glare_stats | 均值偏差 0.1–0.8%，标准差 1.3–2.6%（门禁 5% / 25%） |
| jzazbz / resize / grain_stats | **不进硬门禁**，只打印：前两个是参考侧用例口径不同（亮度量程 / 重采样核），最后一个参考侧是并行 RNG，每次结果都不一样 |


## 9. 复现命令

```bash
cd SpektrafilmSwift-ios

# 引擎基线（颗粒开启 = 真实导出路径）
SPEKTRA_BENCH_IMAGE="$PWD/build/test-IMG_6459.DNG" \
SPEKTRA_BENCH_SIZES=960,1280,1600,2048,4032 SPEKTRA_BENCH_ROUNDS=2 Tools/bench.sh

# 预览模式（与 MobileDevelopSession.renderAccurate 同配置）
SPEKTRA_BENCH_PREVIEW=1 SPEKTRA_BENCH_IMAGE="$PWD/build/test-IMG_6459.DNG" \
SPEKTRA_BENCH_SIZES=960,1280 SPEKTRA_BENCH_LUT=0 ./build/bench

# 落盘对拍
SPEKTRA_BENCH_NO_STOCHASTIC=1 SPEKTRA_BENCH_DUMP=/tmp/parity \
  SPEKTRA_BENCH_IMAGE="$PWD/build/test-IMG_6459.DNG" SPEKTRA_BENCH_SIZES=1600 ./build/bench

# 装机 + 截图 + 日志门禁（门禁不过会 exit 1）
Tools/acceptance.sh "iPhone 18 Pro"

# 叠加 Python 参考对拍（确定性模块 ≤1e-9）
SPEKTRA_PARITY=1 Tools/acceptance.sh "iPhone 18 Pro"

# 只跑对拍
Tools/parity.sh
```

## 10. 片边功能与验收脚本加固（2026-11-10）

新增片边（胶片边缘）特性：`SpektraMobile/Sources/Design/FilmBorder.swift`。
按真实底片机械尺寸换算（135 / 半格 / 120 全系 / 4×5 / 110 / 16mm / 35mm 电影），
齿孔按 KS / BH / CS / 单孔规格绘制，含边字、DX 码、缺口码、划痕 / 灰尘 / 漏光，
预览与导出共用同一确定性种子纹理；导出侧片边先按 sRGB 栅格化再转到目标
色彩空间混合，ProPhoto / ACES 导出不串色。引擎侧 `MobileDevelopSession` 只在
片边参数变化时对当前无片边预览帧重新合成，不重跑显影；开启片边时导出「原始」
长边按内存余量钳位。

`Tools/acceptance.sh` 两处加固：

1. 重装 App 后立即 `simctl privacy grant photos` 预授权相册——重装不重置 TCC，
   但新装首启的权限框会挂在 SpringBoard 上挡住全部截图。
2. 截图前重启 SpringBoard（`launchctl stop com.apple.SpringBoard`），清除上一次
   运行残留的系统弹窗。

验收（iPhone 18 Pro，Release）：BUILD SUCCEEDED，九张截图全部干净，
`Cycle detected: 0 / fatalError: 0 / 文件缺失: 0`。

### 悬浮化返工（同日）

- 显影 / 调色参数面板脱离底部贴边：改为左右留 10pt、悬在 tab 玻璃胶囊上方
  64pt 处的浮窗，四角全部 `MRadius.sheet` 圆角；胶囊独立成底层元素。
  二档展开逻辑（chevron 变高）不变，预览照片从浮窗下方透出（玻璃层语义）。
- 导出弹窗从系统底部 sheet 改为居中浮卡（scrim + 卡片）：无 grabber，
  头部 X / 标题 / 黄铜 ✓ 确认圆钮，选项区对照 Lightroom 参考图改为
  「文件类型 / 尺寸」下拉行（原生 `Menu`）；导出中 scrim 不可点关闭，
  完成态标题「导出完成」+ 返回主页。水印与「更多选项」没有真实功能，未放占位。
