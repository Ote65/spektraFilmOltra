# Spektrafilm 前端改造 — Agent 交接守则

> **先读 `Agent.md`（跨项目总则：前端原则、截图验收、独立 review、progress.txt 留痕），再读本文。**

> 交接对象：负责**前端交互逻辑与 UI 优化**的 Agent。
> 动手前必读本文与《核心算法保护守则.md》，两份都读完再写第一行代码。

## 一、项目是什么

`andreavolpato/spektrafilm`（GPLv3，v0.3.4）——胶片显影的**光谱物理模拟**：RAW/线性图像 → 虚拟胶片 → 放大机 → 相纸 → 扫描输出。

当前状态：上游源码**一行未改**，已在其 Qt/napari GUI 上完成三轮 oflim 风格的前端改造（深色版式、汉化、拖放导入、分页重组）。

## 二、环境与启动（先跑通再动代码）

**给用户的快捷方式**：项目根的 `启动_Spektrafilm.command`，双击即可打开界面（已内置环境变量，无需终端）。

```bash
# 虚拟环境（已装好全部依赖 + pytest，勿重建）
VENV=/Users/megmeet/.workbuddy-ai/binaries/python/envs/spektrafilm

# 启动预览（约 3-4 分钟，napari 首次建主题缓存）
cd "/Users/megmeet/Documents/开发 APP/Spektrafilm"
NUMBA_CACHE_DIR=/tmp/sf_numba_cache PYTHONPYCACHEPREFIX=/tmp/sf_pycache \
  $VENV/bin/python -c "from spektrafilm_gui.app import main; main()"

# 回归测试（改完必跑，见第五节）
QT_QPA_PLATFORM=offscreen $VENV/bin/python -m pytest tests/gui -q --basetemp=/tmp/sf_pytest_base
```

**环境坑（都是踩过的）**：
- 必须在**沙箱外**启动 GUI：沙箱的 brokered-IO 会让 napari 构建主题 SVG 缓存时卡死（症状：无窗口、日志空白）。
- pytest 必须加 `--basetemp=/tmp/...`，否则临时目录 mkdir 被安全钩子误报 PermissionError。
- `NUMBA_CACHE_DIR` / `PYTHONPYCACHEPREFIX` 指到 /tmp，避免项目的 `__pycache__` 被钩子拦截清理。
- 本机网络直连 GitHub 极慢（~30KB/s），需要拉上游时用 `gh-proxy.com` 镜像。

## 三、代码地图（改哪里、别碰哪里）

```
src/spektrafilm/            ← ⛔ 核心算法，见《核心算法保护守则》
src/spektrafilm_gui/        ← ✅ 你的工作区
  app.py                    组装入口：create_app / connect_auto_preview_signals
  napari_layout.py          主窗口、顶栏、分页(EXPOSE/FILM/PRINT/OUTPUT/CONFIG)、拖放、画布工具条
  theme_oflim.py            设计 token（表面色阶/黄铜强调色/圆角）——视觉规范的唯一来源
  theme_palette.py          兼容层：旧变量名 → oflim token，20+ 引用方靠它
  theme_styles.py           全部 QSS
  i18n.py                   汉化词典 + tr()/tr_tooltip()
  widget_primitives.py      CollapsibleSection（卡片/扁平两态）、Chevron
  widget_lookcard.py        胶片身份卡（LookCard）
  widget_editors.py         参数编辑器（含 SliderRowEditor 滑块行）
  widget_sections.py        各参数面板与行构建（_add_param_row 统一入口）
  param_manifest.py         ⚠️ 参数的 label/范围/tier 声明——改 UI 可引用，改语义即越界
  controller*.py            ⚠️ 控制器：载入/保存/模拟调度。交互入口可加，调度逻辑别动
tests/gui/                  GUI 回归测试（152 条）
build-macos/                打包工程（spec + 打包说明.md，用户验收后才打包）
```

## 四、已完成的三轮改造（接手时不要回退）

1. **oflim 版式**：深色表面阶 #0B0B0B→#262624、黄铜强调 #C8A97E、发丝线分隔、圆角卡片。
2. **结构重组**：inspector = 页眉(显影+重置) → 胶片身份卡(LookCard) → 胶囊分页 → 一张 tabCard 内扁平参数组 → 动作栏；分页按暗房流程 EXPOSE/FILM/PRINT/OUTPUT/CONFIG；SCAN/SAVE 为次级按钮（唯一强调色原则）。
3. **汉化 + 交互**：`i18n.py` 词典约 200 条；拖文件进窗口即导入（RAW/RGB 自动分流）；状态栏、弹窗、文件对话框全中文。`mode_label`（Preview/Scan）是内部标识，保持英文，展示时过 `tr()`。

## 五、验收标准（每次改动后全过才算完）

1. `pytest tests/gui -q --basetemp=/tmp/sf_pytest_base` → **152 passed**。
2. `pytest tests -q --basetemp=/tmp/sf_pytest_core --ignore=tests/gui` → **547 passed**，仅
   `test_lut_mode.py::test_lut_mode_digest_disables_every_dangerous_effect` 一条失败（上游测试引用了
   schema 里不存在的 `mult_usm_amount` 字段，上游自带 bug，详见《核心算法保护守则》第五节）。
3. 真实启动 GUI：无异常栈（napari 的 `visual effect areas` 警告是正常的）。
4. 手动冒烟：拖入一张图 → 载入；改一个滑块 → 自动预览触发；重置 → 参数回默认。
5. 断言跟随实现：汉化后消息文本断言用中文，**不允许**为通过而删断言。

## 六、历史教训（照做，别重踩）

- QFormLayout 里长下拉项会把整卡撑出侧栏 → combobox 必须 `AdjustToMinimumContentsLengthWithIcon`。
- 自绘控件（BoolEditor）不画背景时，父容器必须 transparent，否则露出全局黑底。
- 同一 widget 的 setStyleSheet 会级联，子控件样式要用 ID 选择器隔离。
- 参数行的行构建**必须**走 `_add_param_row`，绕过它会出现左右列错位、背景发黑。
- 汉化词条缺失时 `tr()` 回退英文原文，**不要**为了"全中文"硬造词条。

## 七、给下一位的边界提醒

- oflim（`~/Documents/开发 APP/oflim`）只允许读 `Sources/OltraFlim/Views/` 与 `Support/DesignSystem.swift` 参考**版式与交互形态**；严禁把它的调色、RAW、LUT、Renderer 代码搬进来，严禁读它目录下的 md。
- 用户不验收不打包。打包流程见 `build-macos/打包说明.md`。
- 不删用户机器上的任何文件；中间产物（dist*/build*/dmg_staging*）留给用户处理。
