# Spektrafilm → macOS Swift 原生重写移植计划书

> 基线：当前工作树 `OltraFilm`，提交 `23bcd20`，版本 `0.3.4`
> 目标：用 Swift 原生应用 100% 复刻现有桌面版功能，UI 逐像素对齐，算法结果可对拍
> 约束：Swift 版在独立 Git 分支开发，禁止合并回 Python 分支
> 文档性质：实施计划，不是代码，不代替逐文件实现

---

## 0. 结论先行

1. **这不是一次普通 UI 重写。** 现有项目 41,447 行 Python（运行时 9,844、GUI 20,081、LUT 工厂 11,522），外加 14,462 行测试和 16.7 MB 出厂数据。真正的工作量约 60% 在数值算法、色彩科学、RAW/文件 I/O 和像素对拍，UI 约占 40%。
2. **可以做到“像素级”，但要分两层定义。** 确定性算法（曝光、显影、印相、扫描、光晕、扩散、锐化）可以做到 Float64 逐点对拍；随机颗粒/眩光和系统字体栅格化不可能位对位复刻，只能做统计等价和视觉等价。计划里给出了可验收的容差，而不是一句“完全一样”。
3. **现有“调色台”只是占位页。** 代码里没有真正的调色引擎，导出按钮是禁用状态。Swift 版按现状复刻占位页、交接图和返回路径，不应擅自开发调色引擎。
4. **LUT Creator 是独立 CLI，不是 GUI 功能。** GUI 代码没有调用 `spektrafilm_lut_creator`。桌面 App 的 100% 复刻不包含它；若要连 CLI 一起移植，作为可选阶段 P8。
5. **GUI 里有两套界面，只有一套真正运行。** 启动入口是 `app.create_app → WorkspaceWindow → LibraryPage / EditorPage / GradePage`；`napari_layout.build_main_window` 那套旧参数面板在当前入口中不可见。计划以实际运行的新壳层为准，死代码不纳入复刻范围（详见 §1.2）。
6. **法律是硬约束，不是技术细节。** 上游代码 GPLv3；profile 与 LUT 数据按 `SPEKTRAFILM_LICENSE.txt` 为 CC BY-SA 4.0（README 的“不可转售”摘要与许可正文不一致，以许可正文为准，另有禁止商业 AI 训练的说明）。直接移植属于衍生作品，分发时必须 GPLv3 开源；GPLv3 与 Mac App Store 的 DRM 条款通常冲突，应走独立签名/公证 DMG。详见 §1.6。
7. **推荐技术路线：SwiftUI/AppKit + C++20 数值核心 + Metal 预览加速。** 纯 Swift 也能做，但 RAW、EXR、TIFF、ICC、lensfun 这些 C/C++ 库绕不开；把数值核心放 C++ 可以逐函数对照 Python，Swift 只负责 UI、状态和调度。
8. **分支策略：同仓库 orphan 分支 + 独立 worktree，永不合并。** 分支没有 Python 历史，合并会变成 unrelated-histories；再加 CI 守卫和远端保护，防止误合并。详见 §8。

---

## 1. 基线审计

### 1.1 代码规模与组成

| 包 | 行数 | 职责 | 是否进入 Swift 复刻 |
|---|---:|---|---|
| `src/spektrafilm` | 9,844 | 光谱胶片模拟运行时：profile、色彩、曝光、显影、印相、扫描、颗粒、光晕、扩散、LUT | 是，核心 |
| `src/spektrafilm_gui` | 20,081 | Qt/napari 桌面壳、照片库、编辑页、快速/专业参数、导出、交接图 | 是，UI 与工作流 |
| `src/spektrafilm_lut_creator` | 11,522 | `.cube` / `.3dl` / Hald PNG / OCIO / Lumix LUT 打包与 QA CLI | 否，独立 CLI；可选 P8 |
| `tests` | 14,462 | 核心回归、GUI 测试、LUT 测试 | 作为参考与对拍来源，不直接移植 |

- 出厂数据 16.7 MB：28 个 profile（20 胶片 + 8 相纸，5.6 MB）、光谱上采样 LUT 9.7 MB、ICC 904 KB、滤镜 CSV 132 KB、水印 PNG 73 KB、许可文本 24 KB。
- GUI 测试 248 个 test 函数；全仓 687 个 test 函数；回归 baseline 5 个 `.npz`。
- 依赖：numpy、scipy、colour-science、scikit-image、matplotlib、opt-einsum、numba、OpenImageIO、pyfftw、rawpy、exiv2、lensfunpy、qtpy/PySide6、napari、Pillow、pyconify、markdown。

### 1.2 实际运行入口与“两套 UI”事实

启动链：

```
spektrafilm_gui.app.main
  → create_app()
    → _create_viewer()               # napari Viewer，仅作为画布内核
    → create_widget_bundle()         # 旧参数编辑器，作为状态源
    → initialize_controller()
    → build_workspace_window()       # 真正显示的窗口
      → LibraryPage
      → EditorPage (PresetRail + PreviewStage + ParameterDeck + Filmstrip)
      → GradePage（占位）
```

必须知道的差异：

| 现象 | 代码事实 | 对 Swift 复刻的含义 |
|---|---|---|
| 旧参数面板不可见 | `build_main_window` / `build_controls_panel` 只被测试或旧入口使用 | 不实现旧版 napari 侧栏、Old FilmLookCard、旧 Display/GuiConfig 面板 |
| “保存当前为默认 / 从文件载入 / 恢复出厂”在新壳层不可见 | `GuiConfigSection` 不在 `ParameterDeck` 中 | 不新增这些按钮；保留状态文件兼容即可 |
| “扫描 / 生成全尺寸”没有独立按钮 | `EditorTopBar.scan_requested` 信号存在但无发射点 | 全尺寸只由“渲染中排队的直接导出”和“调色交接”触发；空闲时直接导出使用当前输出层（可能是预览尺寸） |
| “导出设置”弹窗存在，但不直接触发导出 | 顶栏菜单只给“直接导出 / 导出设置 / 另存为” | 保留弹窗与持久化，不新增导出按钮 |
| “调色”按钮有，调色台是占位 | `GradePage` 左右是占位说明，导出按钮 `setEnabled(False)` | 复刻占位页和交接图，不实现调色引擎 |
| `preview_max_size` 不可见 | 在 `ParameterDeck` 的显示组中被 `_DISPLAY_SKIPPED` 跳过 | 保留字段兼容，不提供控件 |
| 重置按钮文案说“出厂值” | 实际调用 `load_default_gui_state()`，有已保存默认就用已保存默认 | 行为按代码，文案按现有 UI；作为验收注意项 |

### 1.3 依赖替换矩阵（摘要）

| Python 依赖 | 用途 | Swift 方案 | 风险 |
|---|---|---|---|
| numpy / numba | 数组、并行内核 | C++ Float64 缓冲 + Accelerate/vDSP + GCD；Metal 用于预览 | 中 |
| scipy.ndimage / scipy.interpolate / scipy.stats | 高斯、缩放、Akima、正态分布、FFT | 自写 C++（FIR/IIR、样条、Akima、erfc、Brent）；Accelerate FFT | 高 |
| scikit-image `rescale` | 预览缩放、升采样 | 复刻 `warp` + 三次样条 + 抗锯齿；不能随手换 vImage | 高 |
| colour-science | CMFS、光源、RGB↔XYZ、CAT、CAM16/Oklab/JzAzBz | 提取常数与矩阵，C++ 实现，Float64 对拍 | 高 |
| opt_einsum | 光谱积分 | 手写 GEMM（像素×波长×通道），`cblas_dgemm` | 低 |
| OpenImageIO | TIFF/EXR/PNG/JPEG 读写、ICC 嵌入 | ImageIO + libtiff + OpenEXR + LittleCMS | 中 |
| rawpy / LibRaw | RAW 解码 | vendored LibRaw，锁定版本，复刻 rawpy 参数 | 高 |
| exiv2 | EXIF/IPTC/XMP | vendored Exiv2 或 ImageIO + 自写 XMP/ICC | 中 |
| lensfunpy / lensfun | 镜头校正 | vendored lensfun + 数据库，锁定版本 | 中 |
| Pillow / ImageCms | 显示 ICC 变换 | ColorSync / LittleCMS | 低（屏幕相关，不可像素对拍） |
| Qt / PySide6 | UI | SwiftUI + AppKit | 中 |
| napari / vispy | 画布、图层、缩放、对比 | 自写 Metal 画布 | 高 |
| pyfftw | 扩散 FFT | Accelerate vDSP FFT（Float64） | 中 |
| matplotlib | 调试绘图 | 不进入 App；仅对拍工具 | 低 |

### 1.4 运行时管线与数据流

```
RGB 输入
  → preprocess（自动曝光、裁切、缩放、像素尺寸）
  → filming.expose（RGB→光谱响应、曝光、 高光 boost、扩散、镜头模糊、光晕、黑白场校正、log10）
  → filming.develop（密度曲线插值、DIR 成色剂、颗粒）
  → printing.expose（底片 CMY→相纸光谱响应、印相曝光、预闪、扩散、log10）
  → printing.develop（相纸密度曲线形态、显影液疲劳）
  → scanning.scan（CMY→XYZ 光谱积分、眩光、XYZ→RGB、色域压缩、模糊/USM、CCTF）
  → RGB 输出
```

Tap 边界：`rgb_in`、`rgb_pre`、`log_e_film`、`cmy_film`、`log_e_print`、`cmy_print`、`rgb_out`。所有 tap 都要能在 Swift 中导出，供对拍和可选 LUT 工厂使用。

### 1.5 性能基线事实

- README 记录：6 MP 约 10 秒（作者笔记本）；用户机器上 12 MP 全尺寸约 50–90 秒。
- 自动预览默认 1/2 长边，上限 1920 px；`preview_mode` 在 GUI 预览/扫描时被强制 `False`，即预览仍走完整物理，只是分辨率更低。工具提示里“预览关闭颗粒/光晕”的文字与实际行为不一致，属于待确认的历史文案。
- 显影器/扫描器 LUT 固定开启，分辨率 17；胶片 tc LUT 192×192×81；这些缓存必须原样复刻，否则性能与结果都会变。

### 1.6 法律与分发约束

| 内容 | 许可 | 对 Swift 版的要求 |
|---|---|---|
| Python 源码 | GPLv3 | 直接移植属于衍生作品，分发时必须以 GPLv3 提供完整对应源码 |
| `data/profiles/*.json` | CC BY-SA 4.0 | 保留署名、许可、修改说明；衍生数据同许可 |
| `data/luts/*` | CC BY-SA 4.0（SPEKTRAFILM_LICENSE.txt） | 与 profile 同许可：署名、链接、同许可分享、注明修改；随包附许可。README 的“不可转售”摘要与许可正文不一致，以许可正文为准；商业 AI 训练另有禁止性说明，需遵守 |
| `data/icc/*`、`data/filters/*` | 上游各自许可 | 保留原始许可与来源说明 |
| App Store | Apple 条款与 GPLv3 冲突 | 不走 Mac App Store；走 Developer ID 签名 + 公证 + DMG |

在 About / Licenses 页放：上游项目链接、作者署名、GPLv3 全文、profile/LUT 许可、“非官方 Swift 移植”声明。若未来要闭源商用，必须先与上游作者协商替代许可，这不是技术能绕过的。

---

## 2. 复刻范围与验收定义

### 2.1 纳入范围

| 类别 | 纳入内容 |
|---|---|
| 应用壳 | 窗口、暗色主题、页面栈（照片库/显影台/调色台）、状态栏、拖放、关闭保护 |
| 照片库 | 导入照片/文件夹、递归扫描、网格/列表、4:3 缩略图、文件夹卡、收藏、颜色标签、已调整筛选、搜索、排序、分页“显示更多”、移出库、Finder 定位、缺失文件状态 |
| 显影台 | 顶栏、预设台、预览画布、胶片条、快速/专业参数台、直方图、重置、收藏 |
| 预览画布 | 白边、虚拟相纸水印、缩放/平移、100/200/400%、适应窗口、旋转、对比滑杆、渲染档位、Polaroid 显影动画、交叉淡入 |
| 参数 | 5 个主 Tab + 高级页的全部可见参数；快速模式 12 轴；条件禁用；脏计数；双击复位 |
| 显影工作流 | 自动预览防抖、指纹去重、渲染档位、全尺寸扫描（导出/交接时）、进度阶段、并发保护、导出排队 |
| 文件 I/O | RAW 解码、白平衡、色调、镜头校正、RGB 图片导入、色彩空间自动识别、输入 CCTF |
| 输出 | 直接导出、导出设置、另存为、JPEG/PNG/TIFF/EXR、位深/压缩/长边/目录/文件名模板、元数据复制、ICC 嵌入 |
| 交接 | 16-bit ProPhoto 线性 TIFF、指纹、调色台占位、返回 |
| 持久化 | 默认状态、单张照片状态、快速模式状态、导出设置、照片库索引、缩略图缓存、对话框目录 |
| 数据 | 20 胶片 × 8 相纸、滤镜、ICC、光谱 LUT、水印 |

### 2.2 不纳入范围（当前版本不存在或不可达）

- 旧 napari 侧栏、旧 `FilmLookCard`、旧 Display/GuiConfig 面板。
- “保存当前为默认 / 保存到文件 / 从文件载入 / 恢复出厂”按钮（当前壳层不可见；状态文件兼容保留）。
- 独立“扫描”按钮（当前不存在）。
- 真正的调色引擎、LUT 预设栏、调色参数（当前是占位）。
- 外部 `.cube` LUT 导入（项目本身不支持）。
- LUT Creator CLI（除非追加 P8）。
- 多窗口、批量导出、导出队列 UI（当前没有）。
- 用户自定义主题、插件系统、脚本 API。

### 2.3 “像素级”验收标准

| 层 | 标准 | 说明 |
|---|---|---|
| UI 布局 | 关键框体位置/尺寸误差 ≤1 pt；颜色十六进制完全一致；字号/字重一致 | 系统字体栅格化允许亚像素差异 |
| UI 文案 | 字符串逐字一致（含标点、省略号、大小写） | 以 Python 资源为唯一来源 |
| UI 图标 | 归一化坐标与线宽一致；2x 渲染 | 抗锯齿边缘允许差异 |
| 确定性算法 tap | Float64 最大绝对误差 ≤1e-6（或相对 ≤1e-6），无 NaN/Inf 差异 | 关闭随机与空间效应后对拍 |
| 最终 8-bit 输出 | ≥99.9% 像素完全一致，最大通道差 ≤1 LSB | 确定性参数；随机效果另算 |
| 空间效果 | 与 Python 同参数结果最大差 ≤1e-4（Float64） | 光晕/扩散/高斯/USM |
| 随机效果 | 颗粒/眩光：均值、标准差、功率谱/自相关在 ±2% 内；无同图像素位对位要求 | numba 并行 RNG 本身不可跨机复现 |
| RAW | 同 LibRaw 版本同参数下，解码结果 ≤1 LSB；镜头校正几何误差 ≤1 px | 需锁定 LibRaw/lensfun 版本 |
| 元数据 | EXIF/IPTC/XMP 关键字段、ICC 嵌入存在性一致 | 编码器差异允许字节不同 |
| 显示变换 | 功能等价（开/关、找不到 profile 的回退） | 屏幕相关，无法对拍 |
| 性能 | 预览与全尺寸不慢于同机 Python 基线；内存不超过 Python 峰值 2 倍 | 具体见 §11 |

### 2.4 对拍语料

- **确定性全管线**：8 组代表胶片×相纸，1024×768 灰阶/色卡/肤色/高光，全部 tap。
- **全组合冒烟**：20×8=160 组合，256×256，确定性模式，验证无崩溃、profile 校验通过、输出有限。
- **参数边界**：每个滑块 min/max、每个开关开/关、每种枚举分支、裁切/升采样/scan_film。
- **空间效果**：光晕、散射、扩散、柔光镜、眩光、USM 各单独对拍。
- **随机统计**：颗粒 3 个 ISO/3 个密度、眩光 3 个强度，统计检验。
- **RAW**：至少 5 个品牌/机型样本（Canon/Nikon/Sony/Fuji/Panasonic），白平衡 4 模式，镜头校正开/关。
- **导出**：4 格式 × 位深/压缩组合，元数据与 ICC。
- **UI 截图**：照片库空/有内容/网格/列表/筛选、显影台各 Tab、快速/专业、导出弹窗、调色台、对比模式、缩放档位、Polaroid 关键帧。

### 2.5 不可妥协的行为

- 非 RAW 文件绝不进入 RAW 解码；错误必须友好弹窗，不得崩进程。
- 模拟进行中禁止切换照片/返回照片库；关闭窗口需提示。
- 自动预览只渲染最新状态；连续调整合并请求，不重复排队。
- 渲染中请求导出必须排队，当前完成后自动导出，不丢请求。
- 打开一张照片时，显示/预览偏好是全局的，不能被单张存档带跑。
- 换胶片/相纸只同步物理默认值，不重置通道互换、自动预览、保存偏好。
- 快速模式切换胶片/相纸必须先撤销旧意图、重捕基线、再套用，避免参数叠加漂移。
- 快速模式专业字段被改后显示 Custom 点；拖动快速轴会覆盖这些字段。
- 正片扫描模式（`scan_film=true`）下，印相专属快速轴置灰并给出原因。
- 每张照片的 `grade` / `quick` / 未知字段必须原样保留，不能被状态保存冲掉。
- 导出目录不可用时必须报错，不得静默失败。

---

## 3. 目标技术架构

### 3.1 技术选型

| 层 | 选择 | 理由 |
|---|---|---|
| UI | SwiftUI + AppKit 互操作 | 原生控件、动画、窗口；复杂自绘控件用 `Canvas`/`NSView` |
| 画布 | Metal (`MTKView`) | 缩放/平移/对比/动画/显示变换需要 GPU；避免 napari/vispy |
| 数值核心 | C++20，Float64 参考路径 | 逐函数对照 Python；`-ffp-contract=off` 保证可复现 |
| 加速 | Accelerate/vDSP/vForce + GCD + Metal | BLAS、卷积、FFT、逐像素 LUT |
| RAW | vendored LibRaw（锁定版本） | 与 rawpy 同源；CIRAWFilter 的 demosaic 不同，不能对拍 |
| 镜头 | vendored lensfun（锁定数据库） | 与 lensfunpy 同源 |
| 色彩管理 | LittleCMS + ColorSync | ICC 读写、显示变换；不依赖 Pillow |
| 浮点图像 | libtiff + OpenEXR | 16/32-bit TIFF、half/float EXR |
| 元数据 | vendored Exiv2 或 ImageIO + 自写 XMP | 与 exiv2 字段行为一致 |
| 构建 | Xcode workspace + 本地 Swift Package | App 打包、公证、资源拷贝 |
| 分发 | Developer ID + notarization + DMG | GPLv3 与 MAS 冲突 |

**运行时不包含 Python、Qt、napari、numpy。** Python 只在对拍工具链和参考仓库里使用；Swift App 不 spawn Python、不依赖本机 Python 环境。

### 3.2 模块树

```
SpektrafilmSwift/
├── Spektrafilm.xcworkspace
├── Apps/SpektrafilmApp/                 # @main, Info.plist, entitlements, assets
├── Packages/
│   ├── SpektraUI/                       # SwiftUI 页面、设计系统、组件
│   ├── SpektraApp/                      # NSWindow、菜单、文件面板、拖放、状态栏
│   ├── SpektraCore/                     # Swift 对外 API、状态、调度、缓存
│   ├── SpektraCoreCxx/                  # C++ 管线、模型、内核、profile
│   ├── SpektraColor/                    # CMFS、光源、RGB 空间、CAT、CAM16/Oklab/JzAzBz
│   ├── SpektraIO/                       # LibRaw、lensfun、ImageIO、libtiff、OpenEXR、Exiv2、lcms
│   └── SpektraParity/                   # 对拍工具、NPY/EXR 读写、报告
├── Resources/
│   ├── Profiles/                        # 28 个 JSON，字节级复制
│   ├── SpectralLUTs/                    # irradiance_xy_tc.npy 等
│   ├── Filters/                         # 二向色/吸热/镜头 CSV
│   ├── ICC/                             # 出厂 ICC
│   ├── Watermark/                       # virtual_paper_watermark.png
│   ├── UIManifest/                      # 从 Python 生成的 manifest/strings/defaults
│   └── Licenses/
├── Tests/
│   ├── SpektraCoreTests/
│   ├── SpektraParityTests/
│   ├── SpektraIOTests/
│   └── SpektraUITests/
├── Tools/
│   ├── parity_dump.py                   # 在 Python worktree 跑，导出 goldens
│   ├── manifest_export.py               # 导出 UI 规格/文案/默认值
│   └── compare.py                       # 对拍报告
└── docs/
    ├── PORTING_PLAN.md
    ├── PARITY_MATRIX.md
    └── DECISIONS.md
```

### 3.3 数据流与状态

- Swift 侧只保留一份 `GuiState`（与 Python 的 dataclass 结构一一对应），UI 控件绑定到路径，不做第二份镜像状态。
- 运行时参数由 `GuiState` 映射为 `RuntimePhotoParams`；映射规则逐条对应 `params_mapper.py`，包括：
  - 通道互换改 `profile.data.channel_density` 列顺序；
  - `camera.diffusion_filter` 与独立 `camera_diffusion` 的覆盖顺序；
  - `enlarger.diffusion_filter` 与独立 `enlarger_diffusion`；
  - `film_render.density_curve_gamma` 来自 `special.film_render`；
  - `io.output_cctf_encoding` 强制 `True`；
  - `settings.use_enlarger_lut/use_scanner_lut=True`、`lut_resolution=17`、`use_fast_stats=True`；
  - `digest_after_selection` 对正片自动 `scan_film=True`。
- `digest_params` 还会做这些“不可省略”的隐式处理：
  - 从 `data/filters/neutral_print_filters.json` 按 `print.stock / illuminant / film.stock` 应用印相中性 C/M/Y 滤镜；缺失时警告并使用默认值；
  - 正片/负片使用不同的 DIR coupler gamma 矩阵；
  - 按 `film.info.use`（still/cine）与 `antihalation`（strong/weak/no）套用光晕预设；
  - `fujifilm_velvia_100` / `fujifilm_provia_100f` 覆盖各自 DIR gamma；
  - `settings.preview_mode` 的降级分支（GUI 当前强制关闭，但核心 API 仍需保留）；
  - `debug.lut_mode` 的确定性分支（GUI 不暴露，但对拍/LUT 工厂需要）。
- 渲染调度：`SimulationActor` 串行执行；主线程只做 UI；预览任务可取消/最新优先；导出请求进入待办，当前任务完成后执行。

### 3.4 并发模型

| 任务 | 执行者 | 规则 |
|---|---|---|
| UI 状态/动画 | `@MainActor` | 不跑模拟 |
| 预览模拟 | `SimulationActor` | 同一时刻最多 1 个；新请求设置 pending |
| 全尺寸扫描/交接 | 同一 Actor，高优先级 | 不允许与预览并行 |
| 缩略图 | `ThumbnailActor` | 最多 3 并发；磁盘缓存 |
| 导出 | `ExportActor` | 模拟完成后执行；失败恢复 UI |
| RAW 解码 | `IOActor` | 文件级串行，避免 LibRaw 线程问题 |
| 金属内核 | `MTLCommandQueue` | 分块提交，避免看门狗超时 |

### 3.5 参考路径与加速路径

- **Reference（必须存在）**：C++ Float64 单线程/多线程 CPU 路径，作为验收基线；全尺寸导出默认走这条。
- **Fast（可选）**：Metal Float32 预览路径；用于交互预览，允许 ≤1 LSB 的 8-bit 差异；若启用，必须在设置里标明“预览加速”，并提供回退。
- 两条路径共用同一套参数、profile、LUT 和阶段顺序；禁止为了性能改动物理模型。

### 3.6 数据兼容

Swift 版启动后直接读取 Python 版数据目录，不迁移、不覆盖：

| 数据 | 路径 |
|---|---|
| 默认 GUI 状态 | `~/Library/Preferences/Spektrafilm/gui_default_state.json` |
| 导出设置 | `~/Library/Preferences/Spektrafilm/export_settings.json` |
| 照片库 | `~/Library/Application Support/Spektrafilm/library/library.json` |
| 缩略图 | `~/Library/Application Support/Spektrafilm/library/thumbs/<id>.jpg` |
| 交接图 | `~/Library/Application Support/Spektrafilm/library/projects/<id>/handoff.tif` |
| 对话框目录 | `QSettings('spektrafilm','spektrafilm')` 写入的 plist；只读兼容，失败回退默认 |

写入策略：先写 `.tmp` 再原子替换；保留未知字段；写前备份 `.bak`；绝不删除用户原文件。

### 3.7 分发

- 最低系统：macOS 14（Sonoma）；Universal（arm64 + x86_64）。
- 非沙盒（与 Python 版一致的任意文件访问），Developer ID 签名 + 公证 + DMG。
- 若未来要沙盒：文件夹导入必须改用 security-scoped bookmarks，`library.json` 增加 bookmark 字段；这会影响兼容性，建议一期不做。
- App 图标、About、许可页、版本号：`0.3.4-swift.N`，与 Python 基线版本绑定。

---

## 4. UI/UX 像素规格

### 4.1 设计令牌（唯一来源）

| 令牌 | 值 | 用途 |
|---|---|---|
| `SURFACE_0` | `#121315` | 页面底、画布默认底 |
| `SURFACE_1` | `#18191B` | 栏/状态栏/输入底 |
| `SURFACE_2` | `#202124` | 卡片、输入框 |
| `SURFACE_3` | `#282A2D` | 选中卡片、分段底 |
| `SURFACE_4` | `#34363A` | 18% 灰画布、滑轨 |
| `TEXT_1` | `#F4F4F2` | 主文字 |
| `TEXT_2` | `#B4B4B0` | 次文字 |
| `TEXT_3` | `#8A8A86` | 说明/读数 |
| `TEXT_4` | `#5E5E5A` | 禁用/占位 |
| `ACCENT` | `#C8A97E` | 黄铜强调 |
| `ACCENT_STRONG` | `#D9BD95` | 悬停 |
| `ACCENT_DIM` | `#8E7756` | 按下 |
| `ACCENT_ON` | `#14120E` | 强调底上的文字 |
| `DANGER` | `#C7705D` | 错误 |
| `HAIRLINE` | `#12FFFFFF` | 7% 白细线 |
| `HAIRLINE_STRONG` | `#22FFFFFF` | 13% 白细线 |
| 圆角 | 7 / 11 / 15 / 6 | 小/中/大/控件 |
| 间距 | 4 / 8 / 12 / 16 / 24 / 32 | 4 的倍数 |
| 字体 | 系统字体；数字 tabular | SF Pro / `.monospacedDigit()` |
| 字号 | 21 / 13 / 12 / 11 / 10 | 标题/区块/正文/说明/微字 |

### 4.2 窗口与页面栈

- 窗口标题 `Spektrafilm`；初始 1460×940；最小 1180×760；启动后最大化。
- 页面栈：照片库（index 0）→ 显影台（1）→ 调色台（2）。
- 底部状态栏：`SURFACE_1`，顶部 1 px 细线，11 px 文字，无 size grip。
- 关闭保护：模拟中弹窗“显影计算还没有结束，完成后再关闭窗口。”，忽略关闭。
- 启动进入照片库，状态栏“照片库已就绪”3 秒。

### 4.3 照片库页

| 区块 | 规格 |
|---|---|
| 页头 | 左右 28，上 16，下 13；标题 21px/500；副标题 11px；右侧“导入文件夹”文字按钮 +“导入照片”黄铜按钮，高 30 |
| 筛选行 | 胶囊高 26：全部/收藏/已调整，分隔 1×18，再红/黄/绿/蓝；右侧搜索 240×30、排序 112×30、视图切换 58×30 |
| 区块标题 | “全部照片”13px/600；计数 11px；间距 8 |
| 网格 | 卡宽 260–340，间距 20/22；缩略 4:3；名称行高 18（字号 12）；元信息行高 15（字号 11）；文字间隔 9+3 |
| 列表 | 行高 76；缩略 96×72；名称/元信息；操作常显 |
| 文件夹卡 | 与照片卡同一 4:3 语言；中心 folder 图标 30–56；不显示深色分界框 |
| 空态 | 76×76 图标座；“照片库还是空的”；“把照片拖到这里，或点右上角导入。”；格式行；两个导入按钮 |
| 筛选空态 | “没有匹配的照片”；“换个关键词，或点“全部”清除筛选。” |
| 分页 | 每次 +240；“显示更多（还有 N 张）” |
| 卡片操作 | 颜色点/收藏/更多 22×22，悬停淡入 140ms，移出 110ms；选中 1.6px 黄铜边 |
| 状态 | 缺失“文件已移动”；解码失败“无法预览”；RAW 占位标“RAW”；已有调色配方左上“已调色” |
| 缩略图 | 512 px 长边 JPEG q88；磁盘缓存；3 线程；横图居中裁切，竖图 24×24 模糊铺底 + 完整居中 |
| 拖放 | 整窗覆盖层：“松开以导入图片”；“RAW · TIFF · PNG · JPEG · EXR” |

### 4.4 显影台

| 区块 | 规格 |
|---|---|
| 顶栏 | 高 54；左右 16/间距 10；“照片库”返回 28 高；标题 14/500；元信息 11；忙碌文字宽 168；收藏 28×30；调色按钮 28 高；导出箭头 22×28；底部 2px 进度条 |
| 分栏 | 左预设 300 / 中自适应 / 右参数 ≥300；分隔 1px；分栏初始 [300, 900, 300] |
| 预览 | 画布占满；左上 chip“照片/底片”；左下信息纯文字；右下浮动工具条 |
| 工具条 | 高 26；档位（完整/1/2/1/4）、对比、渲染、逆时针/顺时针、适应、缩放 100/200/400；底 14 右 14；圆角 12 |
| 胶片条 | 高 96；缩略 92×69，间距 6；内边距 10/9；末尾 + 卡 92×69；横向滚轮 |
| 参数台 | 宽 ≥300；头 48；快速/专业分段 176×30；重置 30；直方图卡 50 + 标题；正文 14/10 |
| 页面 Tab | 光影 / 色彩 / 胶片 / 画面 / 输入 / 高级；下划线 2px 黄铜；高 30 |
| 参数卡 | `SURFACE_2`，1px 细线，圆角 12；内边距 12/10/11；行高 44，开关/枚举 44，向量 52，组标题 26 |
| 滑块行 | 标签 12；读数 12 tabular 右对齐最小 52；滑轨 3px，把手 11px，脏值黄铜；双击标签复位 |
| 开关 | 32×18；关 `#3D3D3B`，开黄铜；白色圆钮；跟随动画 rate 26 |
| 进度文案 | 输入准备 / 胶片曝光 / 胶片显影 / 放大曝光 / 相纸显影 / 扫描相纸 / 扫描底片，显示“阶段 n/N” |
| 直方图 | 128 bin/通道；色 `#B46B5C`/`#8A9B78`/`#7C8DA0`；填充 α46；0.55 幂归一；空态“等待预览” |

### 4.5 画布行为

- 背景默认 `#121315`；18% 灰模式 `#34363A`。
- 白边：`white_padding` 为长边比例，白色矩形在图像外围。
- 虚拟相纸：`virtual_paper_watermark.png`，1024 长边，菱形点阵 72°、整体旋转 16°、背景 `#242426`、logo `#3E3E40`、眩光 0.25；相纸纹理只出现在图像区域，白边仍为白色。
- **输入预览层默认隐藏**：它是模拟源和对比源，不直接显示。输出层未生成时，画布显示虚拟相纸背景 + 白边；输出层生成后覆盖图像区域。对比模式隐藏白边/水印，左原片右显影。该隐藏行为来自 `set_or_add_input_preview_layer`，是现有产品的“暗房相纸”观感，不是 bug。
- 缩放：滚轮 `exp(angleY / 700)`；范围 4%–3200%；指数跟随 rate 10；100% = 1 屏幕点对应 1 图像像素（按 DPR）；按钮 100/200/400；适应窗口 `reset_view`。
- 对比：左原片 / 右显影；36px 拖动条，黄铜 1.2px 线 + 13px 圆形把手 + 左右三角；边距 3%；随缩放/平移实时投影。
- 渲染档位：完整、1/2、1/4；实际长边上限 1920；变更后触发自动预览。
- 显示预览源：载入/旋转时用于对比原片的显示图长边上限 1600；模拟预览源上限 1920。
- 旋转：输入图 90° 步进；重算预览缓存并自动预览。
- 显示：输出插值支持 nearest/linear/cubic/spline16/spline36/lanczos/blackman；默认 spline36。
- 显影动画：输出层首次出现或从隐藏变可见时，1600ms、32ms 帧、最多 1.5 MP；9 层 Polaroid 密度堆叠；同形状已可见时 10 帧交叉淡入。
- 启动/未出图：显示虚拟相纸背景 + 白边；输入预览层不显示。实际启动停在照片库页，通常看不到该状态。

### 4.6 预设台

- 宽 300；顶部“胶片 N / 相纸 N”分段，高 26；搜索框 32；品牌胶囊“全部/柯达/富士”高 26；卡片高 54，色块 38×38，选中黄铜边、名称 `ACCENT_STRONG`；滚动阻尼（notch 62px、rate 13）；选中卡自动滚入视野。

### 4.7 参数台（快速模式）

- 12 轴分 3 组：光调（拍摄曝光、印相明暗、影调反差）、色彩（二维色盘 + 色彩浓度）、质感（颗粒强度、颗粒尺寸、光晕强度、光晕范围、光学柔化、扫描清晰度）。
- 行高 46；读数右对齐；Custom 点 10×8 黄铜；色盘 168×112，中心十字、圆点、四方向“暖/冷/品红/绿”；读数显示 `±CC`（满量程 ±100 对应 ±60 CC）。
- 拖动 150ms 后提交；双击标签回 0；重置快速按钮 28 高。
- 正片扫描模式下，印相专属四轴与色盘置灰，原因：“正片扫描模式：管线跳过印相阶段，本项不参与成像”。
- **滚轮行为现状**：`WheelSafeSlider` 显式忽略滚轮，滚轮滚页面、不调值。若要在 Swift 版改成“滚轮调值”，属于交互变更而非复刻，需单独拍板（见 D11）。

### 4.8 调色台（占位）

- 顶栏 54：返回“显影台”、标题、元信息（W×H · 胶片 · 相纸 · “16-bit ProPhoto 线性交接图”）、黄铜“调色台”徽章、禁用“导出”（提示“调色台导出将在第三步接入”）。
- 左 240“LUT / 预设”占位；右 300“调色参数”占位；中间等比预览，空态“正在读取交接图…”；无图时“交接图已生成，预览将在第三步接入”。
- 返回显影台；不实现调色服务。

### 4.9 导出设置弹窗

- 宽 452；无边框模态；外卡 `SURFACE_1`，1px 强线，圆角 15；36px 模糊阴影；
- 字段：格式（JPEG/PNG/TIFF/EXR）、画质 1–100、PNG 压缩 0–9、TIFF 压缩 无/ZIP/LZW、EXR 压缩 ZIP/PIZ/RLE、位深（TIFF 8/16/32，EXR 16/32）、长边 0–20000（0=原始尺寸）、导出目录 + 选择、文件名模板（`{name}`/`{film}`/`{paper}`）；
- 底部取消/保存；保存按钮黄铜 + 勾图标；居中于父窗口。

### 4.10 动画与手感

| 场景 | 参数 |
|---|---|
| 通用淡入 | 170 / 260 / 340 ms，OutExpo |
| 页面切换 | 200 ms，start 0.6 |
| 检查器/预设台淡入 | 180 ms，start 0.5 |
| 读数变化 | 140 ms，start 0.3 |
| 开关跟随 | 指数 follow rate 26 |
| 分段 Tab | rate 22 |
| 缩放 | rate 10 |
| 滚动 | rate 13 |
| 卡片操作淡入/淡出 | 140 / 110 ms，OutCubic |
| 输出首次显影 | 1600 ms，32 ms/帧 |
| 同形状交叉淡入 | 10 帧，32 ms/帧 |
| 滑条拖动 | 直接跟手，释放时提交 |

### 4.11 图标与文字

- 图标全部矢量自绘：back、import、export、folder、grid、list、star、star_filled、search、plus、check、chevron_down、close、rotate_ccw、rotate_cw、fit、compare、dots、grade、film_frame。
- 线宽默认 1.6；小图标 1.2；圆头圆角；2x 渲染。
- 文案全部沿用现有中文；枚举显示名沿用 `ENUM_LABELS`；参数技术名与基础名分别沿用 `TECHNICAL_LABELS` / `PARAM_LABELS`。
- 参数 tooltip 由 `tip_for` + 原生值摘要组成；快速轴 tooltip 含“当前原生值：...”与 Custom 原因。

### 4.12 字体与尺寸换算

- Qt 逻辑像素按 1x 对应 Swift point；Retina 由系统按 2x 渲染，不做额外缩放。
- 系统字体用 `.system(size:weight:design:)`；数字用 `.monospacedDigit()`。
- QSS 的 px 字号直接映射为 pt；字距（letter-spacing 0.3/1.0）用 `.tracking()` 复刻。
- 不承诺文字像素位对位；以布局、字号、颜色、字符串为准。

---

## 5. 功能清单（100% 对照）

> 用法：实现时逐条勾选；每条都要有 Swift 实现位置与验收证据。ID 仅用于计划跟踪。

### A. 应用壳

| ID | 功能 | 验收 |
|---|---|---|
| A01 | 启动进入照片库，最大化 | 窗口尺寸/页面正确 |
| A02 | 暗色外观、系统标题栏 | 与 Python 版视觉一致 |
| A03 | 页面栈库/显影/调色 | 返回路径正确 |
| A04 | 底部状态栏消息 | 文案与超时一致 |
| A05 | 关闭时模拟中拦截 | 弹窗并保持窗口 |
| A06 | 全局拖放导入 | 文件/文件夹均可 |
| A07 | 等待光标 | 打开/导入期间显示 |
| A08 | 启动预热（LUT/色彩/管线） | 首次预览无明显卡顿 |

### B. 照片库

| ID | 功能 |
|---|---|
| B01 | 导入多张照片（RAW + RGB） |
| B02 | 导入文件夹（递归，忽略隐藏文件） |
| B03 | 空文件夹不建卡 |
| B04 | 网格视图（文件夹+照片混排） |
| B05 | 列表视图 |
| B06 | 4:3 缩略图：横裁切、竖模糊延展 |
| B07 | 文件夹卡与“全部照片”返回卡 |
| B08 | 收藏/取消收藏 |
| B09 | 颜色标签（红/黄/绿/蓝/无） |
| B10 | 筛选：全部/收藏/已调整/颜色 |
| B11 | 搜索：文件名/胶片/相纸/路径 |
| B12 | 排序：最近导入/文件名/收藏优先 |
| B13 | 分页 240 + 显示更多 |
| B14 | 从库中移出（不删磁盘） |
| B15 | Finder 中显示 |
| B16 | 文件缺失状态 |
| B17 | 缩略图失败状态 |
| B18 | 缩略图磁盘缓存 + 内存 LRU 160 |
| B19 | 元数据宽高回写（防抖 1.2s） |
| B20 | RAW 内嵌 JPEG 优先，否则半尺寸解码 |
| B21 | 选中态黄铜边 |
| B22 | 悬浮操作淡入 |
| B23 | 右键菜单（打开/收藏/颜色/定位/移出） |
| B24 | 空态与筛选空态 |
| B25 | 导入后回到全部并清空搜索 |
| B26 | 导入数量状态提示 |
| B27 | 打开照片失败回库并提示 |
| B28 | 磁盘后缀修正历史 `is_raw` 标记 |

### C. 显影台顶栏与胶片条

| ID | 功能 |
|---|---|
| C01 | 返回照片库 |
| C02 | 标题/元信息（尺寸/RAW/胶片/相纸） |
| C03 | 收藏切换 |
| C04 | 调色按钮 + 就绪/忙碌禁用 + 配方点 |
| C05 | 导出菜单：直接导出/导出设置/另存为 |
| C06 | 忙碌文案 + 2px 进度条 |
| C07 | 胶片条当前文件夹或全部照片 |
| C08 | 胶片条缩略图缓存与选中 |
| C09 | 胶片条 + 导入照片 |
| C10 | 胶片条横向滚轮 |

### D. 预设台

| ID | 功能 |
|---|---|
| D01 | 胶片/相纸 Tab + 数量 |
| D02 | 搜索名称/raw/meta/品牌 |
| D03 | 品牌筛选 |
| D04 | 卡片色块/名称/副标题 |
| D05 | 选中态 |
| D06 | 点击套用 profile 默认值 |
| D07 | 自动滚入视野 |
| D08 | 阻尼滚动 |

### E. 预览画布

| ID | 功能 |
|---|---|
| E01 | 输入预览/输出图层切换；未出图时显示相纸背景，输入预览默认隐藏 |
| E02 | 白边 |
| E03 | 虚拟相纸水印 |
| E04 | 照片/底片 chip |
| E05 | 左下信息 |
| E06 | 浮动工具条 |
| E07 | 渲染档位 完整/1/2/1/4 |
| E08 | 渲染按钮触发预览 |
| E09 | 对比滑杆 + 原片/显影 chip |
| E10 | 逆时针/顺时针旋转 |
| E11 | 适应窗口 |
| E12 | 100/200/400% 缩放 |
| E13 | 滚轮阻尼缩放 |
| E14 | 18% 灰背景开关 |
| E15 | 输出插值切换 |
| E16 | Polaroid 首次显影动画 |
| E17 | 同形状交叉淡入 |
| E18 | 显示变换开/关 |
| E19 | 输出色彩空间预览 |

### F. 参数台

| ID | 功能 |
|---|---|
| F01 | 快速/专业分段 |
| F02 | 直方图卡 |
| F03 | 光影页 |
| F04 | 色彩页 |
| F05 | 胶片页 |
| F06 | 画面页 |
| F07 | 输入页 |
| F08 | 高级页（剩余参数） |
| F09 | 滑块 + 读数 + 脏值 |
| F10 | 档位模式（印相曝光） |
| F11 | 双击标签复位 |
| F12 | 开关控件 |
| F13 | 枚举下拉 + 中文显示 |
| F14 | 向量输入 |
| F15 | 精确数值输入 |
| F16 | 条件禁用（颗粒/光晕/成色剂/化学/眩光/柔光/白黑场/自动曝光/裁切） |
| F17 | 脏参数计数徽章 |
| F18 | 重置 |
| F19 | RAW 重解码可用性 |
| F20 | 滚动条与阻尼滚动 |

### G. 快速模式

| ID | 功能 |
|---|---|
| G01 | 12 轴布局 |
| G02 | 二维色盘 |
| G03 | ±CC 读数 |
| G04 | Custom 点 |
| G05 | 原生值 tooltip |
| G06 | 基线捕获 |
| G07 | 意图写入 |
| G08 | 0 点逐位恢复 |
| G09 | 换 profile rebase |
| G10 | 专业改字段后 Custom |
| G11 | 正片扫描置灰 |
| G12 | 重置快速 |
| G13 | 快速状态持久化 |
| G14 | 拖动 150ms 提交 |
| G15 | 色盘双击回中 |

### H. 显影工作流

| ID | 功能 |
|---|---|
| H01 | 自动预览防抖 120ms |
| H02 | 状态指纹去重 |
| H03 | 渲染中挂起，完成后重放 |
| H04 | 预览档位缓存 |
| H05 | 全尺寸扫描（导出/交接） |
| H06 | 阶段进度回调 |
| H07 | 单任务串行锁 |
| H08 | 结果图层替换/交叉淡入 |
| H09 | 直方图更新 |
| H10 | 失败弹窗与状态恢复 |

### I. 导出

| ID | 功能 |
|---|---|
| I01 | 直接导出 PNG / 90% 长边 / 压缩 9 |
| I02 | 导出设置持久化 |
| I03 | 设置弹窗（格式/质量/压缩/位深/长边/目录/模板） |
| I04 | 另存为对话框 |
| I05 | 文件名模板与非法字符清洗 |
| I06 | 重名自动 -1…-999 |
| I07 | 渲染中排队，完成后自动导出 |
| I08 | 保存色彩空间/CCTF 转换 |
| I09 | 元数据复制 |
| I10 | ICC 嵌入 |
| I11 | 8/16/32-bit TIFF |
| I12 | half/float EXR |
| I13 | PNG 压缩级别 |
| I14 | JPEG 质量 |
| I15 | 失败提示 |

### J. 交接与调色台

| ID | 功能 |
|---|---|
| J01 | 调色按钮触发全尺寸显影 |
| J02 | 16-bit ProPhoto 线性 TIFF |
| J03 | 指纹校验 |
| J04 | 交接信息写入 `state['grade']` |
| J05 | 保留已有 recipe |
| J06 | 调色台占位 |
| J07 | 返回显影台 |
| J08 | 交接失败提示 |

### K. 持久化

| ID | 功能 |
|---|---|
| K01 | 默认 GUI 状态 JSON |
| K02 | 单张照片状态 JSON |
| K03 | 快速模式 schema v1 |
| K04 | 导出设置 JSON |
| K05 | 照片库 JSON |
| K06 | 缩略图缓存 |
| K07 | 对话框目录记忆 |
| K08 | 保存防抖 1.5s |
| K09 | 关闭时保存 |
| K10 | 未知字段保留 |
| K11 | 原子写入 |
| K12 | 损坏索引隔离 |

### L. 输入与 RAW

| ID | 功能 |
|---|---|
| L01 | RAW 后缀白名单 |
| L02 | 白平衡 as_shot/daylight/tungsten/custom |
| L03 | 色温/色调 |
| L04 | 镜头校正 |
| L05 | 线性 ACES 解码 |
| L06 | 输出色彩空间/CCTF |
| L07 | RGB 图片载入 |
| L08 | ICC 自动识别色彩空间 |
| L09 | EXR/HDR 视为线性 ACES |
| L10 | 非 RAW 误入 RAW 的拦截 |
| L11 | RAW 解码异常友好提示 |
| L12 | 重新解码 RAW |

### M. 健壮性

| ID | 功能 |
|---|---|
| M01 | 载入/解码/模拟异常不崩溃 |
| M02 | 大图内存保护 |
| M03 | 模拟中切换/返回拦截 |
| M04 | 关闭中拦截 |
| M05 | 导出目录不可用提示 |
| M06 | 文件移动/缺失提示 |
| M07 | 状态文件损坏回退 |
| M08 | 库索引损坏隔离 |
| M09 | 空数据/空目录 |
| M10 | 正片/负片切换 |

---

## 6. 运行时算法移植

### 6.1 管线与阶段

| 阶段 | Python 入口 | 主要工作 | Swift 策略 |
|---|---|---|---|
| preprocess | `SimulationPipeline._preprocess` | `np.double`、自动曝光、裁切、缩放、`pixel_size_um` | C++ Float64；自动曝光 7 种测光；复刻 skimage rescale |
| filming.expose | `FilmingStage.expose` | 光谱上采样、曝光补偿、高光 boost、相机扩散、镜头模糊、光晕、黑白场校正、log10 | GEMM + 高斯/指数滤波 + boost 内核 |
| filming.develop | `FilmingStage.develop` | 曲线插值、DIR 成色剂、颗粒、微结构 | LUT/插值 + 3×3 DIR + 随机内核 |
| printing.expose | `PrintingStage.expose` | 底片 CMY→相纸光谱、曝光因子、预闪、扩散、log10 | 3D LUT（17³ PCHIP）+ 预闪 + 扩散 |
| printing.develop | `PrintingStage.develop` | 相纸曲线形态、显影液疲劳 | CDF/Gumbel + Brent 偏移 + 插值 |
| scanning.scan | `ScanningStage.scan` | CMY→XYZ、黑白场、眩光、XYZ→RGB、色域压缩、模糊/USM、CCTF | 3D LUT + 色域压缩 + vDSP |

### 6.2 基础设施

| 模块 | 必须复刻的细节 |
|---|---|
| `profiles/io.py` | profile JSON 结构；`null`→NaN；density_curves_model；28 个 profile 校验 |
| `config.py` | 380–780 nm，5 nm，81 点；CIE 1931 2° CMFS；Stockman & Sharpe 2° LMS |
| `model/illuminants.py` | BB 黑体、T、K75P、TH-KG3、D 系列；归一化 `sum/81` |
| `model/color_filters.py` | 二向色滤镜 Akima 插值；KG1/KG3/KG5；Canon 镜头透射；带通 erf |
| `utils/spectral_upsampling.py` | 192×192×81 Float16 LUT；tri↔quad 坐标；Mitchell 2D 三次；Hanatos 窗/面；Mallett 基 |
| `utils/gamut_compression.py` | Reinhard knee；可见光 locus 多边形；OkLch/OkLrab/JzAzBz/CAM16-UCS；C_max 表；输入 LUT 重映射 |
| `utils/lut.py` + `fast_interp_lut.py` | 17³ PCHIP 3D；2D Mitchell；反射边界；端点钳位 |
| `utils/fast_gaussian_filter.py` | sigma<3 FIR（truncate=3，reflect）；sigma≥3 Young–van Vliet IIR；指数滤波 3 高斯混合 |
| `utils/fast_interp.py` | 1D 线性插值，端点返回首尾值，重复 x 右偏 |
| `utils/morph_curves.py` | 三子层按 centers 排序；有效 gamma 乘性组合；Gumbel 混合；Brent 求中灰偏移 |
| `model/grain.py` | 3 通道 × 3 子层；poisson/beta 近似；粒子面积；密度地板；微结构；模糊 |
| `model/couplers.py` | 3×3 DIR 矩阵；显影前曲线校正；空间扩散 + 指数尾 |
| `model/diffusion.py` | 光晕 boost→scatter→halation；柔光镜 9 组件 PSF；FFT 扩散；USM |
| `model/density_curves.py` | 曝光→密度插值；正片反向；子层插值 |
| `model/glare.py` | 对数正态随机 + 高斯模糊 + 1/100 |
| `utils/autoexposure.py` | 7 种测光；中心加权 sigma .2；5×5 矩阵；三环；高光加权；0.184 中灰 |

### 6.3 数值实现映射

| Python | Swift/C++ |
|---|---|
| `np.double` HWC 数组 | `ImageBuffer<Double>`（H×W×3，行主序，连续） |
| `np.log10(np.fmax(x,0)+1e-10)` | `vvlog10` + max + eps；NaN 传播规则显式实现 |
| `opt_einsum` 光谱积分 | 像素×81 × 81×3 GEMM（`cblas_dgemm`，行主序） |
| `np.interp` | 二分/线性扫描；端点/重复 x 语义照搬 |
| `scipy.ndimage.gaussian_filter`（1D 光谱） | 自写 reflect FIR；或 vDSP 卷积 + 边界复制 |
| `scipy.ndimage.zoom/rotate`（水印） | 自写双线性/三次缩放与旋转；固定种子 |
| `skimage.transform.rescale` | 自写 SciPy `warp` 语义：spline order 3 + 抗锯齿 + 边界 |
| `np.fft.fft2` / `fourier_gaussian` | Accelerate vDSP FFT Float64；反射填充 + 频域高斯 |
| `numba` 并行 RNG | C++ counter-based RNG（Philox/PCG）；统计验收，不追求位对位 |
| `colour.RGB_to_XYZ` / `XYZ_to_RGB` | 3×3 矩阵 + 白点/CAT16；Float64 |
| `colour.CCT_to_xy` | CIE D 系列 / Kang 2002 公式；常数表 |
| `scipy.stats.norm.cdf` | `erfc` 高精度实现 |
| `scipy.optimize.brentq` | Brent 求根，xtol 1e-10 |
| `PIL.ImageCms` | LittleCMS / ColorSync |
| `OpenImageIO` | ImageIO + libtiff + OpenEXR；ICC 嵌入用 CGImageDestination/lcms |

### 6.4 移植风险点（按难度）

1. **skimage `rescale` 像素语义**：三次样条预滤波 + 抗锯齿 + 边界模式，直接换 vImage 会偏。必须自写并用 Python golden 对拍。
2. **随机颗粒**：numba `prange` 的 `np.random` 本身跨线程不确定，无法位对位；只能统计等价。若产品要求“同一输入每次颗粒完全一样”，需要新增固定种子 + 单线程/确定性 RNG 模式，但这会改变现有行为，需单独决策。
3. **CAM16-UCS / JzAzBz**：公式与常数多，任何一处白点/适应条件错都会造成可见色偏；必须逐公式对拍。
4. **RAW demosaic**：必须锁定 LibRaw 版本与参数；CIRAWFilter 不能替代。
5. **PCHIP 3D LUT**：边界反射、cell min/max、斜率预计算顺序都要照搬；否则 17³ 插值误差会被放大。
6. **Float32 GPU 漂移**：只能用于预览；全尺寸导出走 Float64 参考路径。
7. **大图内存**：12 MP × 3 × Float64 约 288 MB，多份中间结果会爆；需要分块/原地缓冲/复用。
8. **FFT 扩散**：`fourier_gaussian` 的频域核与填充方式需逐行对照。
9. **profile JSON 的 null/NaN**：Swift `JSONDecoder` 默认不能解 NaN；需自定义解析。
10. **色彩空间注册表**：输入 ICC 识别、输出 CCTF、ProPhoto/ACES 白点都要与 colour-science 一致。

### 6.5 LUT Creator（可选 P8）

- 现有 CLI：`spektrafilm-lut build/list`；拓扑 1/2/3/4 LUT；格式 `.cube`、`.3dl`、Hald PNG、Lumix；分辨率默认 33，常用 17/33/65；可选 OCIO 2 配置与 QA 报告。
- 依赖运行时、taps、色彩空间注册表、gamut compression、shapers、naming、metadata。
- 与桌面 App 无 UI 关系；如果只做 App，不移植。若要做，建议单独 `spektrafilmlut` Swift CLI + C++ 核心复用，QA 报告可简化为 HTML/JSON。

---

## 7. 参数、状态与文件兼容

### 7.1 运行时参数树（必须 1:1）

`RuntimePhotoParams`：

```
film / print: Profile
film_render:
  density_curve_gamma
  grain: active, sublayers_active, particle_area_um2, particle_scale,
         particle_scale_layers, density_min, uniformity, blur,
         blur_dye_clouds_um, micro_structure, n_sub_layers
  halation: active, scatter_amount, scatter_spatial_scale, halation_amount,
            halation_spatial_scale, scatter_core_um, scatter_tail_um,
            scatter_tail_weight, boost_ev, boost_range, protect_ev,
            halation_strength, halation_first_sigma_um, halation_n_bounces,
            halation_bounce_decay, halation_renormalize
  dir_couplers: active, amount, inhibition_samelayer, inhibition_interlayer,
                gamma_samelayer_rgb, gamma_interlayer_r_to_gb,
                gamma_interlayer_g_to_rb, gamma_interlayer_b_to_rg,
                diffusion_size_um, diffusion_tail_um, diffusion_tail_weight
  glare: active, percent, roughness, blur
print_render:
  glare
  density_curves_morph: active, gamma_factor, gamma_factor_fast, gamma_factor_slow,
    gamma_factor_red/green/blue, developer_exhaustion
camera: exposure_compensation_ev, auto_exposure, auto_exposure_method,
        lens_blur_um, film_format_mm, filter_uv, filter_ir, diffusion_filter
enlarger: illuminant, print_exposure, print_exposure_compensation,
          normalize_print_exposure, y/m/c_filter_neutral, y/m_filter_shift,
          lens_blur, diffusion_filter, preflash_exposure,
          preflash_y_filter_shift, preflash_m_filter_shift
scanner: lens_blur, white_correction, black_correction, white_level,
         black_level, unsharp_mask
io: input_color_space, input_cctf_decoding, output_color_space,
    output_cctf_encoding, input_gamut_compress, output_gamut_compress,
    crop, crop_center, crop_size, upscale_factor, scan_film
debug: deactivate_spatial_effects, deactivate_stochastic_effects,
       print_timings, lut_mode
settings: rgb_to_raw_method, apply_hanatos2025_adaptation_window,
          apply_hanatos2025_adaptation_surface, spectral_gaussian_blur,
          use_enlarger_lut, use_scanner_lut, lut_resolution, use_fast_stats,
          preview_max_size, preview_mode, neutral_print_filters_from_database
taps: inject, collect
```

关键固定值：GUI 强制 `output_cctf_encoding=True`、`use_enlarger_lut=True`、`use_scanner_lut=True`、`lut_resolution=17`、`use_fast_stats=True`；`preview_mode=False`。

### 7.2 GUI 状态 JSON

- 顶层：`input_image`、`grain`、`preflashing`、`halation`、`couplers`、`chemistry`、`camera`、`enlarger_diffusion`、`camera_diffusion`、`glare`、`scanner`、`input_gamut_compress`、`output_gamut_compress`、`special`、`simulation`、`load_raw`、`display`；不含 `gui_only` / `selection` 顶层键。
- `input_image` 可嵌套 `{io, settings}`，也兼容旧扁平键；旧别名 `apply_cctf_decoding`→`input_cctf_decoding`、`spectral_upsampling_method`→`rgb_to_raw_method`。
- `simulation` 旧键兼容：`film_stock`/`print_paper`/`print_illuminant`/`print_exposure`/`print_exposure_compensation`/`print_y_filter_shift`/`print_m_filter_shift`/`output_color_space`/`scan_film`/`saving_color_space`/`saving_cctf_encoding`/`auto_preview`。
- `display` 旧键兼容：`use_display_transform`/`gray_18_canvas`/`white_padding`/`output_interpolation`/`preview_max_size`。
- 合并语义：以默认状态为底，深合并；元组按数组处理；未知键丢弃（Python 行为）。Swift 写回时应保留未知键，避免数据丢失。
- 默认 profile：`kodak_gold_200` + `kodak_supra_endura`。
- 正片选择自动 `scan_film=true`。

### 7.3 快速模式映射（12 轴）

| 轴 | 中文 | 范围 | 拥有的原生字段 | 规则摘要 |
|---|---|---|---|---|
| `camera_exposure` | 拍摄曝光 | -3..3 EV | `camera.exposure_compensation_ev`、`simulation.enlarger.print_exposure_compensation` | q≠0 时关闭印相自动补偿；相机 EV 夹 -5..5 |
| `print_brightness` | 印相明暗 | -2..2 EV | `simulation.enlarger.print_exposure` | `base * 2^-q`，夹 0.25..4 |
| `tonal_contrast` | 影调反差 | -100..100 | `chemistry.gamma_factor`、`chemistry.active` | `base*(1+0.35q/100)`，夹 0.5..2；非 0 时启用 |
| `print_balance_y` | 暖冷 | -100..100 | `simulation.enlarger.y_filter_shift` | `base + 60q/100`，夹 ±60 |
| `print_balance_m` | 品红/绿 | -100..100 | `simulation.enlarger.m_filter_shift` | `base + 60q/100`，夹 ±60 |
| `color_density` | 色彩浓度 | -100..100 | `couplers.inhibition_interlayer`、`couplers.active` | `base*(1+0.5q/100)`，夹 0..1.5 |
| `grain_amount` | 颗粒强度 | -100..100 | `grain.active`、`density_min`、`uniformity` | 密度 ×(1+0.9q/100) 夹 .005...08；均匀度 -0.06q/100 夹 .90...995；q≤-99 关闭 |
| `grain_size` | 颗粒尺寸 | -100..100 | `grain.particle_area_um2`、`grain.blur` | 面积 ×2^(0.9q/100) 夹 .02..0.8；blur ×(1+0.25q/100) 夹 0..1.5 |
| `halation_amount` | 光晕强度 | -100..100 | `halation.active`、`halation.halation_amount` | ×(1+1.2q/100) 夹 0..2；q≤-99 关闭 |
| `halation_scale` | 光晕范围 | -100..100 | `halation.halation_spatial_scale` | ×2^(0.6q/100) 夹 0.5..2.5 |
| `diffusion` | 光学柔化 | -100..100 | `camera_diffusion.active`、`strength` | 正半轴 strength→2；负半轴按比例减；q≤-99 关闭 |
| `scanner_clarity` | 扫描清晰度 | -100..100 | `scanner.unsharp_mask`、`scanner.lens_blur` | 正半轴 USM amount→1.8；负半轴 lens_blur +0.6×；blur 夹 0..0.8 |

快速模式状态：`schema=1`，`baseline` 为进入工程时的原生值（含 bool/tuple），`intent` 为 q 值；0 必须逐位恢复基线。换 profile 时 `rebase`：先回滚旧意图，再重捕基线，再套回。专业字段被改后 `status=custom`。

### 7.4 导出设置

`export_settings.json`：

```
format: JPEG | PNG | TIFF | EXR
jpeg_quality: 1..100 (default 92)
png_compression: 0..9 (default 6)
tiff_compression: none | zip | lzw (default zip)
exr_compression: zip | piz | rle (default zip)
bit_depth: 8 | 16 | 32 (default 16)
long_edge: 0..20000 (0 = 原始)
directory: "" (原图目录)
filename_template: "{name}_spektrafilm"
```

直接导出固定：PNG、压缩 9、位深 8、长边 = 当前输出长边 ×0.9、模板 `{name}_spektrafilm`、目录 = 源图目录；不读取上述导出设置。

### 7.5 库与交接

- `library.json`：`version=1`，`folders[]`，`items[]`；item id = `sha1(path)[:16]`。
- item 字段：`id,path,name,folder_id,added_at,favorite,color,adjusted,film_stock,print_paper,width,height,is_raw,file_size,mtime,state`。
- 缩略图：`thumbs/<id>.jpg`，512 长边，q88。
- 交接图：`projects/<id>/handoff.tif`，16-bit TIFF，ProPhoto RGB，线性，内嵌 ICC；`state['grade']['handoff']` 记录 path/fingerprint/width/height/format。
- 指纹忽略：`display,quick,grade,auto_preview,saving_color_space,saving_cctf_encoding`。
- `grade.recipe` 当前不会产生；未来若接入调色，字段已预留。

### 7.6 UI 规格生成（强烈建议）

不要手抄 107 条 ParamSpec、69 条主页面控件、中文文案和默认值。P0 用 Python 脚本生成：

- `UIManifest.json`：每个参数的 path/label/tooltip/tier/min/max/step/decimals/enum 及中文枚举名。
- `Pages.json`：五个主 Tab + 高级页的条目顺序、控件类型、条件依赖。
- `QuickAxes.json`：12 轴的范围、标签、owned paths、公式标识。
- `Defaults.json`：`PROJECT_DEFAULT_GUI_STATE`、导出设置、窗口尺寸/颜色/间距/字号。
- `Strings.json`：按钮、状态、空态、错误、枚举显示名。

Swift 端只读取这些生成物；CI 比对生成物哈希。这样 UI 文案和范围不会因手抄漂移。

---

## 8. Git 分支与工程管理

### 8.1 分支创建（P0 执行）

当前仓库 `origin` 指向上游 `andreavolpato/spektrafilm`，且当前分支 `OltraFilm` 比 `main` 多 3 个提交。Swift 分支不能基于 Python 历史，否则未来可能误合并。

推荐步骤（不要在主 worktree 里直接切 orphan）：

```bash
# 1) 为 Swift 版建一个独立的 worktree（detached，暂不建分支）
git worktree add --detach ../SpektrafilmSwift

# 2) 只在这个新 worktree 里创建 orphan 分支
cd ../SpektrafilmSwift
git checkout --orphan swift-native

# 3) 在这个新 worktree 里清空从 Python 带来的文件
#    只影响 ../SpektrafilmSwift，不影响原仓库工作区
git rm -rf .

# 4) 放入 Swift 工程、资源、生成物、计划文档，提交首个提交
git add .
git commit -m "swift: initial native port scaffold"
```

主 worktree 始终留在 `OltraFilm`/`main`，Swift worktree 独立打开 Xcode。若不想共用对象库，改用下面的克隆方案更稳：

```bash
git clone --no-hardlinks . ../SpektrafilmSwift
cd ../SpektrafilmSwift
git checkout --orphan swift-native
git rm -rf .
```

### 8.2 禁止合并的硬性措施

1. **orphan 分支无共同祖先**：普通 `git merge` 会报 unrelated histories；不要使用 `--allow-unrelated-histories`。
2. **分支保护**：在托管端把 `swift-native` 与 Python 分支都设为受保护；禁止跨分支合并 PR。
3. **CI 守卫**：在 Python 分支的 CI 加一步：若工作区出现 `*.swift`、`*.xcodeproj`、`Package.swift`、`.swift-port`，直接失败。
4. **本地 hook**：`pre-push` 拒绝把 `swift-native` 推到 `origin`（上游）；只允许推到用户自己的远端。
5. **标记文件**：Swift 分支根放 `.swift-port`，内容为 `reference=23bcd20 / version=0.3.4 / do-not-merge`。Python 分支 CI 检测该文件即失败。
6. **禁止 cherry-pick**：Swift 分支的提交信息前缀统一 `swift:`，Python 分支 CI 检测该前缀即失败。
7. **文档**：`docs/MERGE_POLICY.md` 写明“此分支永不合并回 Python 分支；如需共享数据，只允许复制生成物/资源，不允许合并历史”。

### 8.3 版本与发布

- `CFBundleShortVersionString = 0.3.4`（与 Python 基线绑定）。
- `CFBundleVersion` / 内部 `SwiftPortVersion = 0.3.4-swift.N`，每个里程碑递增 N。
- About 页显示“Reference: spektrafilm 0.3.4 @ 23bcd20 / Swift port 0.3.4-swift.N”。
- Swift 分支打 tag：`swift-v0.3.4-swift.1` 等；Python 分支不接受该 tag。

### 8.4 提交规范

- `swift: scaffold ...`
- `swift(core): ...`
- `swift(ui): ...`
- `swift(parity): ...`
- `swift(io): ...`
- 每个提交只做一件事；数值改动必须附对拍报告或 golden 更新说明。

---

## 9. 实施阶段与退出条件

> 不写日历工期；以“可验证的退出条件”推进。Track A（核心）与 Track B（UI 壳）可并行。

| 阶段 | 目标 | 交付物 | 退出条件 |
|---|---|---|---|
| P0 参考冻结与对拍 | 冻结 Python 基线，建立 Swift 分支/worktree，生成 manifest/goldens | `.swift-port`、分支、`UIManifest/`、20+ goldens、资源校验和 | Swift 空工程可编译；goldens 可由脚本重建；分支隔离检查通过 |
| P1 App 壳 + 照片库 | 窗口、设计系统、库数据层、缩略图、导入/筛选/搜索/排序 | `SpektraUI` 库页、`SpektraApp` 窗口、`LibraryStore` | B01–B28 全通过；用户目视验收库页 |
| P2 确定性核心 | profile、色彩、光谱上采样、预处理、三阶段（无空间/随机） | `SpektraCoreCxx`、`SpektraColor`、tap 导出 | 8 组 tap 最大误差 ≤1e-6；160 组合无崩溃；8-bit 输出 ≤1 LSB |
| P3 空间/随机/效果 | 高斯、IIR、FFT 扩散、光晕、成色剂扩散、颗粒、眩光、微结构、boost | 内核库 + 统计测试 | 空间效果 ≤1e-4；颗粒统计 ±2%；预览性能达标 |
| P4 I/O/RAW/导出/色彩管理 | LibRaw、lensfun、TIFF/EXR/PNG/JPEG、ICC、EXIF/XMP、导出弹窗、交接 TIFF | `SpektraIO`、导出 UI、元数据测试 | RAW 对拍 ≤1 LSB；4 格式导出成功；元数据字段一致 |
| P5 显影台 UI | 预设台、参数台、快速/专业、直方图、胶片条、画布交互、动画、调色台占位 | 全部编辑页 | F/G/E/J 清单全通过；条件禁用/脏计数/快速 rebase 正确 |
| P6 工作流与对拍硬化 | 预览调度、缓存、导出排队、持久化、错误处理、大图/内存 | 完整 App | A–M 全清单 100%；无数据丢失；崩溃注入测试通过 |
| P7 打包发布 | Universal、签名、公证、DMG、About/Licenses、版本 | 可分发 DMG | Gatekeeper 通过；许可页完整；干净机器安装运行 |
| P8（可选）LUT CLI | `.cube`/`.3dl`/Hald/Lumix/OCIO/QA | `spektrafilmlut` CLI | 与 Python 输出逐字节/逐值对拍；QA 报告可读 |

### 9.1 每个阶段的“完成”定义

- 代码合并到 `swift-native`，不是合并到 Python 分支。
- 单元测试 + 对拍测试通过；性能未回退。
- 用户可见部分由用户做最终 UI/交互验收；助手只交付构建产物、测试报告和验收要点。
- 更新 `PARITY_MATRIX.md`：每条功能有状态（未开始/实现/对拍/验收）。

---

## 10. 测试与对拍

### 10.1 Python 参考侧

在 Python worktree（不是 Swift 分支）运行 `Tools/parity_dump.py`：

- 输入：profile、参数 JSON、输入图（灰阶/色卡/肤色/高光/噪声）、tap 列表、是否关闭空间/随机。
- 输出：`.npy`（Float64 HWC）+ `meta.json`（参数、版本、LibRaw 版本、时间、哈希）。
- 对随机模式：关闭随机做确定性；另存固定 RNG 统计样本（均值/标准差/直方图/ACF）。
- 对 RAW：保存 rawpy 解码结果、镜头校正结果、EXIF 字段。
- 对导出：保存各格式文件与解码后的像素、元数据。
- 对 UI：保存关键界面截图与字符串表。

### 10.2 Swift 侧

| 测试 | 内容 |
|---|---|
| `SpektraCoreTests` | profile 解析、颜色矩阵、LUT、滤镜、插值、曲线、阶段 smoke |
| `SpektraParityTests` | tap 对拍；逐像素 diff；阈值报告；160 组合冒烟 |
| `SpektraIOTests` | RAW、TIFF/EXR/PNG/JPEG、ICC、EXIF/XMP、文件名/重名 |
| `SpektraUITests` | 布局快照、字符串、控件状态、条件禁用、快速/专业切换（快照测试为可选项，由用户运行；助手不自动启动 App 做点击验收） |
| `PerformanceTests` | 预览、全尺寸、内存峰值、缩略图吞吐 |
| `CrashSafetyTests` | 非 RAW 入 RAW、损坏文件、缺目录、损坏 JSON、超大图 |

### 10.3 对拍报告

- 每次数值提交生成 `ParityReport.md`：语料、最大误差、P99、失败像素坐标、可视化 diff 图。
- 阈值失败即阻断合并；阈值放宽必须写决策记录。

### 10.4 CI

- macOS runner：`swift test`、Xcode build、对拍 fixtures（离线）。
- Python 参考侧不在 Swift CI 中运行；goldens 提交为 fixtures，避免双语言 CI 耦合。
- 分支守卫 job：检测 Swift 文件/标记进入 Python 分支。

### 10.5 手动验收

- 按用户偏好：助手不自动启动 App 做点击验收；只提供构建产物、测试结果、逐条验收清单。
- 用户验收项：库页视觉、显影台布局、快速/专业切换、滑动手感、动画、导出弹窗、调色台占位。UI 快照测试只作为可选回归工具，由用户运行；助手不自动启动 App 去点击页面。

---

## 11. 性能预算

| 指标 | 目标 |
|---|---|
| App 启动到照片库 | ≤2 s（冷启动，不含缩略图） |
| 缩略图首屏 | 1 s 内出现占位/低清，后台补齐 |
| 预览（1920 长边，缓存热） | 不慢于同机 Python 基线；目标 ≤ 基线的 0.5× |
| 预览防抖到出图 | 交互停止后 ≤1.5 s（M1 Pro 级别） |
| 拖动预测帧（D0，LUT 命中，800×600） | ≤50 ms（实测 18–32 ms） |
| LUT 烘焙 65³（冷启动一次） | ≤1.5 s（实测 0.8–1.3 s） |
| 预测→精算渐变 | 180 ms |
| 全尺寸 12 MP | 不慢于同机 Python 基线；目标 ≤ 基线 |
| 导出 12 MP TIFF | 扫描完成后 ≤3 s |
| 缩放/平移/对比 | 60 fps，主线程无阻塞 |
| 内存峰值 | ≤ Python 峰值 2×；12 MP 全尺寸 ≤1.5 GB |
| 缩略图并发 | 3；不抢占模拟线程 |
| 冷缓存 tc LUT | 可接受一次性构建；构建时显示进度/忙碌 |

---

## 12. 风险与决策点

| ID | 风险 | 等级 | 处置 |
|---|---|---|---|
| R1 | GPLv3 / CC BY-SA / LUT 许可 | 阻断 | 分发前定许可；GPLv3 开源；非 MAS；保留许可文件与署名；确认商业 AI 训练限制 |
| R2 | 随机颗粒/眩光无法位对位 | 高 | 统计验收；如需确定性，另立“固定种子模式”决策 |
| R3 | skimage 缩放语义 | 高 | 自写 warp；golden 对拍；禁止直接 vImage 替代 |
| R4 | RAW demosaic 差异 | 高 | 锁定 LibRaw 版本/参数；样本对拍；不用 CIRAWFilter |
| R5 | CAM16/JzAzBz/OkLab 常数 | 高 | Float64 公式对拍；逐分支测试 |
| R6 | GPU Float32 漂移 | 中 | CPU Float64 为导出权威；GPU 仅预览；误差预算 |
| R7 | 字体/抗锯齿差异 | 中 | 字符串/布局/颜色严格；像素允许亚像素差 |
| R8 | 大图内存/看门狗 | 中 | 分块、复用缓冲、Metal 分块提交 |
| R9 | 状态兼容/数据丢失 | 中 | 保留未知键、原子写、备份、迁移测试 |
| R10 | 误合并 Python 分支 | 高 | orphan + 保护 + CI + hook + 标记文件 |
| R11 | 范围蔓延（调色引擎/LUT CLI） | 中 | 明确不纳入；P8 可选 |
| R12 | Intel/Apple Silicon GPU 差异 | 中 | 两平台跑对拍；Metal 特性检测 |
| R13 | EXIF/XMP/ICC 细节 | 中 | vendored Exiv2/lcms；字段级测试 |
| R14 | 显示变换屏幕相关 | 低 | 功能验收，不逐像素 |
| R15 | 旧文案与实际行为不一致 | 低 | 以代码行为为准，文案照旧；记入验收注意项 |

### 待拍板决策

| 决策 | 推荐 | 备选 |
|---|---|---|
| D1 核心语言 | C++20 + Swift 桥接 | 纯 Swift（IO/RAW 仍需 C 库） |
| D2 RAW 引擎 | LibRaw 锁定版 | CIRAWFilter（不可对拍） |
| D3 导出精度 | CPU Float64 权威 | GPU Float32 全流程（不推荐） |
| D4 分发 | 非沙盒 + Developer ID + DMG | 沙盒 + bookmarks（兼容性成本高） |
| D5 许可 | GPLv3 开源；profile/LUT 按 CC BY-SA 4.0 | 与上游协商替代许可 |
| D6 调色台 | 复刻占位 | 另立项目做调色引擎 |
| D7 LUT CLI | 不纳入，P8 可选 | 同步移植 |
| D8 死代码 | 不移植 | 全部移植（无意义） |
| D9 随机效果 | 统计等价 | 固定种子确定性（改变现有行为） |
| D10 UI 规格 | Python 生成 JSON | 手抄（易漂移） |
| D11 滚轮调值 | 保持现状（滚轮滚页面） | 改成滚轮调值（交互变更，需用户确认） |

> 双层渲染的 7 项待拍板（LUT 格式、连续轴近似、精度红线、默认档位、防抖/渐变、设置入口、1/1 上限）见 §14.10。

---

## 13. 开工步骤（第一批 10 个提交）

1. `swift: create orphan swift-native branch/worktree and port marker`
2. `swift(core): add Swift package skeleton and RuntimePhotoParams Codable`
3. `swift(assets): vendor profiles, spectral LUTs, filters, ICC, watermark with checksums`
4. `swift(parity): add Python tap-dump harness and first golden fixtures`
5. `swift(ui): add design tokens, window shell, status bar`
6. `swift(ui): add library store, import, grid/list, thumbnails`
7. `swift(color): implement CMFS, illuminants, RGB spaces, CAT`
8. `swift(core): implement topology, preprocess, filming deterministic`
9. `swift(core): implement printing/scanner deterministic`
10. `swift(parity): pass tap parity on 8 representative combos`

---

## 14. 双层渲染（LUT 预测 + 物理精算）——已实现（P0–P3），待 UI 验收

> 来源：Python 侧《Spektrafilm 双层渲染（LUT 预测 + 物理精算）计划书》（2026-11-04）；
> 参考实现为 electron `d17128d` 的 `src/spektrafilm_service/lut_preview.py`。
> Swift 已完成四段烘焙、预测查表、停手真算替换与导出预检；物理模型未改。
> 与 electron 的差异：默认 65³（45³ 在真实 RAW 上 p99 超 1.0）、Float32 四面体插值、
> 预测帧在真算进行中也能上屏（消除冷烘焙晚于 1 s 防抖时的竞态）。

### 14.1 目标与边界

- 已实现：参数变化 → 150 ms 出 D0 LUT 预测帧（实测 18–32 ms/800×600）；停手 1 s 后 D1 真算并按 180 ms 渐变替换；进入调色台/导出走 D2 全尺寸真算，仍是唯一交付源。
- 换片后后台预烘 LUT，首次拖滑杆通常直接命中缓存。
- 调色台不在本链路上：它读交接图（线性 ProPhoto → `GradeEngine.prepareSource` 转线性 sRGB），配方与分辨率无关；LUT 预测只服务显影台预览。
- LUT 只承载“胶片 + 相纸”的确定性逐像素映射；空间/随机/图像自适应效果一律不进 LUT，由 `debug.lutMode` 关闭（`Pipeline.swift` 已复刻该分支）。

### 14.2 三档数据流

```
参数变化（拖动中）
  ├─ D0 预测：命中/烘焙 LUT → 查表 → 按当前输出配置上屏          目标 <50 ms
  └─ 停手 1 s
        └─ D1 准算：现有 PreviewRenderer 按预览比例真算 → 180 ms 渐变替换
进调色台 / 导出
  └─ D2 终算：全尺寸真算 → 交接图 / 导出（现有路径，唯一交付源）
```

- D0 按帧合并：连续滑杆事件只保留最新一次查表，旧帧按 generation 丢弃；不阻塞主线程。
- D1 未到达前保持 D0，不清空、不转圈；D1 到达后做 alpha 过渡。
- D1 已在渲染时到达的预测帧仍可上屏；D1 完成后同代际迟到的预测帧丢弃。
- 连续拖动只保留最新 D1，旧任务取消（复用 `PreviewRenderer` 代际取消）。
- 若 D1 与 D0 差异超阈值（平均 ΔE₀₀ > 1 或 max > 3），状态栏标“精算已更新”，提供差异视图入口，禁止静默替换。

### 14.3 现有 Swift 零件

| 零件 | 位置 | 复用方式 |
|---|---|---|
| 确定性开关 | `Sources/SpektraCore/Runtime/Params.swift` `DebugParams.lutMode`；`Pipeline.swift` 的 lutMode 分支 | 与 Python `params_builder.py` 同义：关空间/随机、自动曝光、曝光补偿、印相曝光补偿与印相曝光、halation boost、黑白场、USM；预闪不在该分支，需按连续轴处理 |
| 3D LUT 容器 | `Sources/SpektraCore/Utils/Interpolation.swift` `LUT3D` / `PreparedPCHIP3D` | 印相/扫描 17³ 现用 PCHIP；预览档另加 Float32 四面体，不替换现有路径 |
| 烘焙骨架 | `Sources/SpektraCore/Runtime/SpectralLUTService.swift` `compute3D` | 逐样本 1×1 调用，适合 17³；预览档改为一次 grid 管线（见 14.4） |
| 预览渲染器 | `Sources/SpektraCore/Services/PreviewRenderer.swift` | 串行队列、代际取消、共享谱 LUT、降采样、阶段进度回调，直接作为 D1 |
| 预览调度 | `SpektraSkin/Engine/EngineHost.swift` `schedulePreviewRender` | 现有 1 s 防抖/中断/`RenderPhase`；扩展为 D0 + D1 双阶段 |
| 预览 UI | `SpektraSkin/Screens/Editor/PreviewStage.swift` | 现在单图显示；扩展为 D0/D1 双层 + 渐变 + 模式角标 |
| 降采样 | `Sources/SpektraCore/Utils/AutoExposure.swift` `Resize.longEdge` | D0/D1 同尺寸对齐 |

### 14.4 烘焙设计（Swift）

- **输入/输出**：输入是 RAW 解码后的线性 ProPhoto，可能 >1；用 log2 shaper 把约 -8…+4 EV（12 档，可配）装进立方体，查表后反解。输出与当前预览一致：`io.outputColorSpace`（默认 sRGB）+ `io.outputCCTFEncoding`（默认 true）。
- **网格**：65³（唯一档位）；内部 Float32；查表用四面体插值。45³ 在真实 DNG 上 p99 1.45（不达标），故默认提高。第一版不导出 `.cube`。
- **一次 grid 烘焙**：把 `size³` 个样本摊成一张 `size² × size` 的图（65³ → 4225×65），用 `SimulationPipeline.processSegment` 四次进入/退出，而不是逐样本 `compute3D`。要求 `crop=false`、`upscaleFactor=1`、输入色彩空间/CCTF 与当前加载一致；`lutMode` 已关闭全部空间效果，`preprocess` 按 longEdge 算出的 `pixelSizeUM` 不影响结果。
- **连续轴**：曝光补偿、印相曝光、滤色、预闪不进立方体，在 LUT 前后按标量或通道增益近似施加。这些是近似项，必须进 14.7 的精度门禁（尤其中间印相曝光的非线性）。
- **缓存键**：`(inputColorSpace, inputCCTF, film, paper, scanFilm, 密度/曲线相关参数, outputColorSpace, outputCCTF, shaper, grid, 印相曝光补偿开关)`；曝光/自动曝光/印相曝光等连续轴从键中剔除。补偿开关决定是否需要补偿管线，保留在键内。
- **缓存**：内存 LRU 3 组（65³ Float32 单份约 13 MB，3 组约 40 MB）；磁盘缓存不做。
- **耗时**：65³ 冷启动烘焙 0.8–1.3 s（含谱 LUT/印相 LUT 首次构建），热缓存后同类换片约 0.6 s；800×600 预测查表 18–32 ms。换片后后台预烘，避免首次拖动等冷启动。

### 14.5 文件落点

| 层 | 文件 | 动作 |
|---|---|---|
| 新增 | `Sources/SpektraCore/Services/PreviewLUTService.swift` | shaper 编解码、grid 烘焙、LRU、Float32 四面体查表、延迟预烘 |
| 新增 | `Sources/SpektraCore/Services/PreviewPreflight.swift` | 预测 vs 精算、确定性 vs 完整效果的 ΔE₀₀ 统计与提示语 |
| 新增 | `Sources/SpektraCore/Color/CIEDE2000.swift` | ProPhoto Lab + Sharma CIEDE2000 |
| 核心 | `Sources/SpektraCore/Runtime/Pipeline.swift` | `PipelineTap`、`processSegment`、印相补偿因子接口；物理阶段不变 |
| 核心 | `Sources/SpektraCore/Stages/FilmingStage.swift`／`PrintingStage.swift` | 中灰补偿密度更新、中灰曝光因子 |
| 引擎 | `SpektraSkin/Engine/EngineHost.swift` | D0 150 ms、D1 1 s、180 ms 渐变、过期帧丢弃、换片预烘、导出预检 |
| 模型 | `SpektraSkin/Models/SkinModels.swift` | `previewIsPredicted`、`previewRevision`、`preflightNotice` |
| UI | `SpektraSkin/Screens/Editor/PreviewStage.swift` | D0/D1 双层交叉淡入（180 ms） |
| UI | `SpektraSkin/Screens/Editor/ExportSettingsSheet.swift` | 预检提示行 |
| 设置 | — | 未做三档；预测常开（与 electron 一致），如需开关再补 |
| 验收 | `Tools/HostSmoke/main.swift` | 烘焙/查表耗时、预测 vs 精算 ΔE₀₀、真实 DNG 预检、快速帧可见 |

### 14.6 效果取舍

- 自动曝光、按全图最大值的提升、黑白场校正：在 D0 的降采样图上先算统计量，再在 LUT 外统一施加（与 Python 计划一致）。
- 颗粒/眩光/光晕/扩散/USM：D0 不表现，D1 出现；状态角标可提示“精算后出现”。
- 高质量档只增大网格，不试图表达空间效果。

### 14.7 精度门禁（沿用 Python QA，不另造标准）

| 指标 | 阈值 | 实测 |
|---|---|---|
| ΔE₀₀ 全集 max | ≤ 2.0 | 合成 0.70；真实 DNG 1.60（45³ 为 2.65） |
| ΔE₀₀ p99 | ≤ 1.0 | 合成 0.43；真实 DNG 0.83（45³ 为 1.45） |
| 中性灰阶 0→100% | 每级 ≤ 1.0，无断阶 | 合成梯度覆盖，未出现断阶 |
| 高光专项（输入 +4 EV） | 不出现“LUT 先剪、精算不剪”的差异 | 真实 DNG 高光未见裁切差异 |
| 实拍样张 ≥5 张（天空/肤色/霓虹） | p99 ≤ 2.0 | 当前只验 1 张 DNG；待补 |
| CIEDE2000 公式 | — | Sharma 6 组参考对，最大误差 4.0e-5 |

确定性管线已有 Python 对拍（≤5e-13），D0/D1 的差异只来自 LUT 近似，不引入新的物理偏差。
门禁工具已实现：`CIEDE2000` + `PreviewPreflight`，导出面板打开时自动跑。

### 14.8 分阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 测量烘焙/查表耗时 | 完成：65³ 冷启动 0.8–1.3 s，查表 18–32 ms |
| P1 | `PreviewLUTService` + HostSmoke 预测图 | 完成：预测 vs 精算 δE₀₀ 达标 |
| P2 | 接显影台：D0 150 ms + D1 1 s + 180 ms 渐变 + 预烘 | 完成：快速帧可见，过期帧丢弃 |
| P3 | 导出预检与提示 | 完成：导出面板显示模型/效果提示 |
| P4（可选） | D0 基图进调色配方（单屏调胶片+调色） | 未做，维持三步 |
| P5（可选） | 查表/调色 GPU 化 | 未做，CPU 查表已 <50 ms |

### 14.9 风险与回滚

| # | 风险 | 对策 |
|---|---|---|
| 1 | 65³ 冷启动烘焙 0.8–1.3 s | 换片后台预烘；拖动时先显示旧图，D1 接管；预测常开 |
| 2 | 颗粒/光晕在 D0 缺失 | D0 明确为预测档；D1 立即补齐；导出预检提示效果差异 |
| 3 | 滤色/印相曝光近似误差 | 进 14.7 门禁；误差大则改 3×3×3 小网格或重新烘焙 |
| 4 | 高光被 LUT 切掉 | log shaper + 高光专项 QA |
| 5 | 缓存组合爆炸 | LRU 3 组 + 补偿开关入键；后续因子化 |
| 6 | 用户不信任近似 | 导出预检提示，交付一律按精算；不做强制精算开关 |
| 7 | 渐变叠化卡顿 | 只在 D1 成功返回时触发；180 ms 固定淡入 |

回滚：去掉 `EngineHost` 的 D0 调度即可完全回到现状；D2 导出链路不受影响。

### 14.10 决策记录

已拍板（2026-11-04 实现时确定）：

1. LUT 内部格式：Float32 线性，不导出 `.cube`。
2. 连续轴：曝光/自动曝光/印相曝光/滤色/预闪按标量或对数偏移近似，不做 3×3×3 小网格。
3. 精度门禁：ΔE₀₀ max ≤2.0 / p99 ≤1.0；65³ 已通过真实 DNG，45³ 不通过。
4. 档位：预测常开，不新增三档设置（与 electron 一致）。
5. 调度：D0 150 ms、D1 1 s、渐变 180 ms；换片后台预烘。
6. 设置入口：不新增。
7. 1/1 预览：维持现状，不补 1920 上限。

仍待确认：

- UI 验收（渐变手感、预测帧上屏时机、导出面板提示位置）由用户完成。
- 是否要补“关闭预测 / 高质量 81³”开关，等用户实际使用后再定。

---

## 附录 A：五个主 Tab 的可见控件

> 路径为 Python 参数路径；范围/步长/模式用于 Swift 控件；`—` 表示开关/枚举/动作。

### 光影

| 标签 | 路径 | 范围/步长 | 模式 |
|---|---|---|---|
| 亮度 | `simulation.enlarger.print_exposure` | 0.25–4.0 / .01 | brightness_stops |
| 自动亮度补偿 | `simulation.enlarger.print_exposure_compensation` | — | toggle |
| 明暗对比 | `special.film_render.density_curve_gamma` | .5–1.8 / .01 | slider |
| 高光柔和度 | `chemistry.developer_exhaustion` | 0–1 / .01 | slider |
| 曝光补偿 | `camera.exposure_compensation_ev` | -5–5 / .25 | slider |
| 自动测光 | `camera.auto_exposure` | — | toggle |
| 测光方式 | `camera.auto_exposure_method` | — | enum |
| 白场校正 | `scanner.white_correction` | — | toggle |
| 白场 | `scanner.white_level` | .75–1 / .005 | slider |
| 黑场校正 | `scanner.black_correction` | — | toggle |
| 黑场 | `scanner.black_level` | .001–.08 / .001 | slider |
| 启用眩光 | `glare.active` | — | toggle |
| 眩光 | `glare.percent` | 0–1 / .01 | slider |
| 眩光粗糙度 | `glare.roughness` | 0–1 / .01 | slider |
| 预闪曝光 | `preflashing.preflash_exposure` | 0–.3 / .005 | slider |

### 色彩

| 标签 | 路径 | 范围/步长 | 模式 |
|---|---|---|---|
| 冷暖 | `simulation.enlarger.y_filter_shift` | -60–60 / 1 | slider |
| 绿与品红 | `simulation.enlarger.m_filter_shift` | -60–60 / 1 | slider |
| 印相光源 | `simulation.enlarger.illuminant` | — | enum |
| 启用成色剂 | `couplers.active` | — | toggle |
| 颜色浓度 | `couplers.inhibition_interlayer` | 0–1.5 / .01 | slider |
| 层次反差 | `couplers.inhibition_samelayer` | 0–1.5 / .01 | slider |
| 成色剂强度 | `couplers.amount` | 0–1.5 / .01 | slider |
| 染色扩散 | `couplers.diffusion_size_um` | 0–30 / 1 | slider |
| 红色反差 | `chemistry.gamma_factor_red` | .5–2 / .01 | slider |
| 绿色反差 | `chemistry.gamma_factor_green` | .5–2 / .01 | slider |
| 蓝色反差 | `chemistry.gamma_factor_blue` | .5–2 / .01 | slider |
| 预闪冷暖 | `preflashing.preflash_y_filter_shift` | -40–40 / 1 | slider |
| 预闪品红 | `preflashing.preflash_m_filter_shift` | -40–40 / 1 | slider |

### 胶片

| 标签 | 路径 | 范围/步长 | 模式 |
|---|---|---|---|
| 胶片 | `simulation.selection.film_stock` | — | profile enum |
| 相纸 | `simulation.selection.print_paper` | — | profile enum |
| 启用颗粒 | `grain.active` | — | toggle |
| 颗粒粗细 | `grain.particle_area_um2` | .02–.8 / .01 | slider |
| 颗粒柔和 | `grain.blur` | 0–1.5 / .01 | slider |
| 染料云 | `grain.blur_dye_clouds_um` | 0–2 / .05 | slider |
| 启用光晕 | `halation.active` | — | toggle |
| 高光红晕 | `halation.halation_amount` | 0–2 / .01 | slider |
| 高光辉光 | `halation.scatter_amount` | 0–2 / .01 | slider |
| 红晕扩散 | `halation.halation_spatial_scale` | 0–3 / .05 | slider |
| 高光提亮 | `halation.boost_ev` | 0–4 / .1 | slider |
| 高光保护 | `halation.protect_ev` | 0–6 / .1 | slider |
| 启用显影曲线 | `chemistry.active` | — | toggle |
| 显影反差 | `chemistry.gamma_factor` | .5–2 / .01 | slider |
| 快层反差 | `chemistry.gamma_factor_fast` | .5–2 / .01 | slider |
| 慢层反差 | `chemistry.gamma_factor_slow` | .5–2 / .01 | slider |

### 画面

| 标签 | 路径 | 范围/步长 | 模式 |
|---|---|---|---|
| 镜头柔化 | `scanner.lens_blur` | 0–2 / .01 | slider |
| 拍摄柔化 | `camera.lens_blur_um` | 0–10 / .1 | slider |
| 启用柔光 | `camera_diffusion.active` | — | toggle |
| 柔光强度 | `camera_diffusion.strength` | 0–2 / .01 | slider |
| 柔光类型 | `camera_diffusion.filter_family` | — | enum |
| 画幅 | `camera.film_format_mm` | 8–120 / 1 | slider |
| 白边 | `display.white_padding` | 0–1 / .002 | slider |
| 输出色彩空间 | `simulation.io.output_color_space` | — | enum |
| 保存色彩空间 | `simulation.workflow.saving_color_space` | — | enum |
| 保存时写入亮度编码 | `simulation.workflow.saving_cctf_encoding` | — | toggle |

### 输入

| 标签 | 路径 | 范围/步长 | 模式 |
|---|---|---|---|
| 白平衡 | `load_raw.white_balance` | — | enum |
| 色温 | `load_raw.temperature` | 1000–10000 / 100 | slider |
| 色调 | `load_raw.tint` | .5–2 / .01 | slider |
| 镜头校正 | `load_raw.lens_correction` | — | toggle |
| 重新解码 RAW | action | — | button |
| 色彩空间 | `input_image.io.input_color_space` | — | enum |
| CCTF 解码 | `input_image.io.input_cctf_decoding` | — | toggle |
| 裁切 | `input_image.io.crop` | — | toggle |
| 裁切中心 | `input_image.io.crop_center` | 0–1 / .01 | vec2 |
| 裁切大小 | `input_image.io.crop_size` | 0–1 / .01 | vec2 |
| 放大 | `input_image.io.upscale_factor` | 1–4 / .05 | slider |
| 上采样方法 | `input_image.settings.rgb_to_raw_method` | — | enum |
| 适应窗口 | `input_image.settings.apply_hanatos2025_adaptation_window` | — | toggle |
| 适应表面 | `input_image.settings.apply_hanatos2025_adaptation_surface` | — | toggle |
| 光谱模糊 | `input_image.settings.spectral_gaussian_blur` | 0–2 / .1 | slider |

### 高级（剩余）

- 颗粒高级：子层开关、三层比例、子层比例、最小密度、均匀度、微观结构。
- 光晕高级：散射范围/核心/拖尾/权重、光晕强度/首跳/次数/衰减/归一、提升范围。
- 成色剂高级：同层伽马、三组层间伽马。
- 眩光高级：blur。
- 扫描高级：USM。
- 相机柔光高级：空间尺度、光晕暖度、核心/光晕/泛光强度与尺寸。
- 放大机扩散：11 个字段。
- 输入色域压缩：active/algorithm/knee。
- 输出色域压缩：algorithm/knee。
- 显示：显示变换、18% 灰、输出插值。
- 实验：胶片/印相通道互换。
- 流程：自动预览、查看底片。

---

## 附录 B：启动与路径检查清单

- `~/Library/Preferences/Spektrafilm/gui_default_state.json` 不存在 → 使用出厂默认（Gold 200 + Supra Endura）。
- 存在但损坏 → 回退默认，不崩溃。
- `library.json` 不存在 → 空库；存在但损坏 → 隔离为 `.corrupt-<time>.json`，空库启动。
- `thumbs/` 不存在 → 自动创建。
- `projects/` 不存在 → 进入调色时创建。
- 导出目录不存在 → 自动创建；失败提示。
- 原图被移动/删除 → 卡片“文件已移动”；打开时提示。
- 权限不足 → 捕获并提示，不崩溃。

---

## 附录 C：关键文件索引

| 主题 | Python 文件 |
|---|---|
| 应用入口 | `src/spektrafilm_gui/app.py` |
| 页面协调/持久化 | `src/spektrafilm_gui/workspace.py` |
| 照片库 | `src/spektrafilm_gui/library_page.py`、`library_store.py`、`library_thumbs.py` |
| 显影台 | `src/spektrafilm_gui/editor_page.py` |
| 参数台 | `src/spektrafilm_gui/parameter_deck.py`、`param_manifest.py` |
| 快速模式 | `src/spektrafilm_gui/quick_controls.py`、`quick_engine.py`、`quick_panel.py` |
| 画布/图层 | `src/spektrafilm_gui/napari_layout.py`、`controller_layers.py`、`preview_compare.py` |
| 导出 | `src/spektrafilm_gui/export_settings.py`、`export_dialog.py` |
| 交接/调色台 | `src/spektrafilm_gui/handoff.py`、`grade_page.py` |
| 持久化 | `src/spektrafilm_gui/persistence.py`、`state.py`、`state_bridge.py` |
| UI 文案/枚举 | `src/spektrafilm_gui/ui_names.py`、`i18n.py`、`options.py` |
| 主题 | `src/spektrafilm_gui/theme_oflim.py`、`theme_shell.py`、`theme_library.py` |
| 运行时管线 | `src/spektrafilm/runtime/pipeline.py`、`stages/*.py`、`services/*.py` |
| 参数与摘要 | `src/spektrafilm/runtime/params_schema.py`、`params_builder.py` |
| 物理模型 | `src/spektrafilm/model/*.py` |
| 数值内核 | `src/spektrafilm/utils/*.py` |
| profile | `src/spektrafilm/profiles/io.py` |
| RAW | `src/spektrafilm/utils/raw_file_processor.py` |
| 导出/元数据 | `src/spektrafilm/utils/io.py` |
| 测试基线 | `tests/baselines/*.npz`、`tests/test_regression_baselines.py` |

---

## 附录 D：术语

- **tap**：管线内部命名边界，用于注入/收集中间结果。
- **tc LUT**：光谱上采样查找表，把 CIE xy 三角坐标映射到 81 点辐照度谱。
- **DIR coupler**：显影抑制剂成色剂，产生同层/层间抑制。
- **PCHIP**：分段三次 Hermite 单调插值，运行时 3D LUT 的默认插值。
- **Mitchell**：2D 光谱 LUT 的三次插值核。
- **Reinhard knee**：色域压缩的软拐点函数。
- **handoff**：交给调色台的全尺寸 16-bit ProPhoto 线性 TIFF。
- **quick intent/baseline**：快速轴的意图值与进入工程时的原生基线。

---

## 附录 E：实施进度（`swift-native`）

已完成：profile/色彩/光谱上采样/三阶段确定性链路、输入色域压缩、LUT、halation、USM、DIR couplers、颗粒、
眩光、四族柔光镜、印相像素尺寸、全部输出压缩算法（cam16ucs / oklch / oklrab / jzazbz / aces_rgc）、
出厂中灰滤镜与胶片特定参数 digest、TIFF/EXR/PNG/JPEG 导出（ICC + EXIF/IPTC）、CIRAWFilter RAW 解码、
自动曝光 7 种方法与预览重采样对拍、TIFF Deflate、双三次放大、预览渲染调度（取消/共享 LUT/降采样）、
颗粒与 FFT 性能优化、照片库（导入识别/索引持久化/缩略图）、导出队列（进度/取消）、
`SpektraSkin` 引擎接线（快照/动作/真实预览与缩略图/直方图/导入导出/快速基线持久化）。
对拍数据见 [parity_report.md](parity_report.md)。

后续已按 electron 分支最新版补齐：显影/调色预览的防抖与取消、进度显示、对比分割线、导出设置面板，
以及完整调色台（`GradeRecipe` / `GradeEngine` / `.cube` LUT / 内置与用户预设 / 交接图与调色导出）。

剩余：放大与 skimage `rescale(order=3)` 的逐位一致、真实 RAW 样本验证与 lensfun 校正、XMP 元数据复制。

已完成：双层渲染（拖动期 LUT 预测 D0 + 停手真算 D1 渐变替换 + 导出全尺寸 D2），
实现与验收数据见 §14；待用户做 UI 手感验收。

---

> 本计划书完成于对当前 Python 仓库的通读审计之后。任何与代码冲突的表述，以代码为准；实施前请先完成 P0 的参考冻结与生成物导出。

