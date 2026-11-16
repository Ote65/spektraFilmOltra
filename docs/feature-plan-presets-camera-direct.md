# Spektrafilm iOS 功能开发方案：保存预设 / 显影联动 / 相机增强 / 直出模式

> 状态：方案待评审，**本文不含任何代码改动**
> 编写日期：2026-11-16
> 适用工程：`SpektrafilmSwift-ios`（iPhone 竖屏，iOS 17.0+，Swift 6）
> 目标：四项功能可独立交付、互不冲突，交互与样式贴近 iOS 原生。

---

## 0. 已确认决策

| # | 议题 | 最终结论 |
|---|---|---|
| 1 | 保存预设按钮位置 | 右上角，调色 / 导出按钮**左侧** |
| 2 | 重置范围 | 显影台、调色台**各自独立重置**，点哪个台只重置哪个台 |
| 3 | 显影重置目标 | 回到**导入时状态**（`LibraryPhoto.initialEditData`） |
| 4 | 显影预设保存范围 | 胶片 / 相纸 / 黑白 + **勾选的专业参数**；未勾选项套用时保持当前值 |
| 5 | 调色预设勾选粒度 | **按组勾选**：光影 / 色调 / 质感 / 细节 / LUT；裁切不参与 |
| 6 | 直出渲染规格 | 直接使用设置里的**导出格式 / 尺寸 / 质量 / 水印开关** |
| 7 | 直出保存原图 | 生成**完整工程，可回放调色** |
| 8 | 镜像前置 | 保留开关，标注“仅前置 RAW 机型生效” |

---

## 1. 代码基线与总体约束

### 1.1 关键文件

| 领域 | 文件 |
|---|---|
| 显影会话 | `SpektraMobile/Sources/Engine/MobileDevelopSession.swift` |
| 调色会话 | `SpektraMobile/Sources/Engine/MobileGradeSession.swift` |
| 相机会话 | `SpektraMobile/Sources/Engine/MCameraSession.swift` |
| 照片入库 | `SpektraMobile/Sources/Engine/MobileEngine.swift` |
| 相册写入 | `SpektraMobile/Sources/Engine/PhotoLibraryExport.swift` |
| 显影模型 / 专业目录 | `SpektraMobile/Sources/Models/MobileModels.swift`、`MobileCatalog.swift` |
| 显影界面 | `SpektraMobile/Sources/Screens/DevelopScreen.swift` |
| 调色界面 | `SpektraMobile/Sources/Screens/GradeScreen.swift` |
| 相机界面 | `SpektraMobile/Sources/Screens/CameraScreen.swift` |
| 设置界面 | `SpektraMobile/Sources/Screens/SettingsScreen.swift` |
| 根导航 | `SpektraMobile/Sources/Screens/MobileRootView.swift` |
| 共用控件 | `SpektraMobile/Sources/Design/MobileComponents.swift` |
| 预设存储 | `Sources/SpektraCore/Grade/GradePresets.swift` |
| 图库模型 | `Sources/SpektraCore/Services/LibraryStore.swift` |
| 调色配方 | `Sources/SpektraCore/Grade/GradeRecipe.swift` |

工程文件为 `SpektraMobileApp/SpektraMobile.xcodeproj`，规格源是 `SpektraMobileApp/project.yml`。
本机未安装 `xcodegen`，**新增 `.swift` 必须手动登记 pbxproj**（FileReference → Group → Sources Build Phase），或临时安装 xcodegen 后执行 `xcodegen generate`。建议本方案尽量把新代码放进已有文件，减少 pbxproj 改动。

### 1.2 总体原则

1. **复用现有管线**：显影、调色、导出、水印、相册写入都走现有实现，不新写算法。
2. **一次用户操作只产生一条撤销记录**：批量应用预设时先组装 `PhotoEdit`，最后只 `pushUndo` 一次。
3. **新字段向后兼容**：JSON 新字段一律 optional 或提供默认解码，旧照片打开不能失败。
4. **原生交互**：弹窗用系统 `.sheet` + detents + grabber；分段选择用系统语义；触控目标 ≥ 44pt；转场不手写 `asyncAfter` 接力。
5. **防呆**：空名、重名、空勾选、无预设、权限拒绝、渲染中重复操作、关闭相机、切后台都要有明确出口。
6. **不引入两套真相**：快速 / 专业的参数一致性由一个 `PhotoEdit` 快照 + 冻结轴集合决定，禁止再维护第二份参数副本。

---

## 2. 功能一：保存预设

### 2.1 现状

- 显影：`MDevelopPreset` 是 `MobileDevelopPresets.all` 里的硬编码内置预设，只有 `filmID / paperID / quick / monochrome`，**没有用户预设存储，也不保存专业参数**。
- 调色：`GradePresetStore` 已有 `save / delete / userPresets` 与 JSON 落盘，但 `GradeScreen` 只展示列表、没有保存入口和删除交互。
- 两者都不支持“只保存部分参数”。

### 2.2 显影预设模型

新增两个类型（放在 `MobileModels.swift`，避免新文件）：

```swift
/// 专业参数值：滑块 / 开关 / 下拉统一编码。
enum MProValue: Codable, Hashable {
    case number(Double)
    case flag(Bool)
    case option(String)
}

/// 用户保存的显影预设：胶片组合 + 勾选的专业参数。
struct MUserDevelopPreset: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = Date()
    var filmID: String
    var paperID: String
    var monochrome: Bool
    /// 控件 ID → 值，只包含用户勾选的项。
    var pro: [String: MProValue]
    var schema: Int = 1
}
```

存储新增 `MDevelopPresetStore`（放在 `MobileModels.swift` 或 `GradePresets.swift` 同层），**沿用 `GradePresetStore` 的 Application Support JSON 模式**，不要用 `UserDefaults`：

- 目录：`Application Support/Spektrafilm/`
- 文件：`develop_presets.json`
- 结构：`{ "schema": 1, "presets": [MUserDevelopPreset] }`
- 接口：`@Published private(set) var userPresets`、`save`、`rename`、`delete`、`isNameTaken(_:excluding:)`
- 与内置预设合并展示：`MobileDevelopPresets.all + store.userPresets`，列表分组“内置 / 我的”。

如果不想改 `Map` 的 Codable 麻烦，可改为：

```swift
struct MProEntry: Codable, Hashable {
    var id: String
    var number: Double?
    var flag: Bool?
    var option: String?
}
```

二选一即可，推荐前者，语义更清晰。

### 2.3 显影预设的保存范围

保存弹窗固定保存：

- 胶片 `filmStock`
- 相纸 `printStock`
- 黑白 `monochrome`

专业参数按控件逐项勾选，候选项来自 `MobileCatalog.proPages` 的四页：

- 光调：拍摄 / 印相 / 预闪
- 色彩：印相滤色 / 浓度 / 分色 / 柔光镜 / 印相柔光 / 印相眩光
- 胶片：片基 / 颗粒 / 光晕 / 胶片眩光
- 细节：扫描 / 黑白场 / 底片 / 输入 / 输出

**裁切相关参数不进入显影预设**：`crop`、`crop_center_x/y`、`crop_size_x/y` 属于构图，不保存。若用户勾选了“输入”分组里的裁切，保存弹窗中该行置灰并标注“构图参数不参与预设”。

**推荐默认勾选状态**：打开弹窗时，只勾选“当前值 ≠ 默认值”的参数；全部为默认值时全不勾选。这样用户按保存不会无意识塞入一整套默认值。

### 2.4 调色预设模型

`GradePreset` 已有 `builtin` 和自定义解码，扩展一个可选的组集合：

```swift
enum MGradeGroupKey: String, CaseIterable, Codable, Hashable {
    case light, color, optics, quality, lut
}

struct GradePreset {
    ...
    /// nil = 旧数据 / 内置预设，视为全组。
    var groups: Set<MGradeGroupKey>?
}
```

- 自定义 `init(from:)` 中 `groups = try? c.decode(...)`，缺省 `nil`。
- 新建用户预设时写入实际勾选组；内置预设保持 `nil`。
- 保存时仍然保存完整 `GradeRecipe` 快照（便于列表展示与未来扩展），但**应用时只覆盖勾选组**。

组与字段对应（以 `MGradeRecipe.gradeRecipe` 为准）：

| 组 | 覆盖字段 |
|---|---|
| 光影 `light` | exposure / contrast / highlights / shadows / whites / blacks / midtones / highlightRolloff / 四条曲线 |
| 色调 `color` | temperature / tint / saturation / vibrance / colorDensity / hsl / grading |
| 质感 `optics` | vignette / vignetteMidpoint / vignetteRoundness / vignetteFeather / grain / grainSize / grainRoughness / chromaticAberration |
| 细节 `quality` | clarity / texture / dehaze / sharpenAmount / sharpenRadius / sharpenThreshold / noiseLuminance / noiseColor |
| LUT `lut` | `lut.path` / `lut.strength`，以及视图层的 `lutName` |

**裁切 / 边框不参与**：`MPhotoGeometry`、`cropData`、`MFilmBorderConfig` 都不在 `GradeRecipe` 内。保存弹窗不列出裁切；应用预设也不触碰 `session.geometry` 与 `session.border`。

新增 `MGradeRecipe.merge(_ other: GradeRecipe, groups: Set<MGradeGroupKey>)`，逐组覆盖；LUT 组还要同步 `lutName`。

### 2.5 保存按钮

- 显影台：`DevelopScreen.floatingChrome` 右侧由 `[调色]` 变为 `[保存圆钮][调色]`。
- 调色台：`GradeScreen.navigationBar` 右侧由 `[重置圆钮][导出]` 变为 `[重置圆钮][保存圆钮][导出]`。
- 样式：与 `MBrassPill` 同色、同高（32pt），但**无文字**，直径 32–36pt 的圆形黄铜按钮。
- 新增 `MBrassCircleButton(icon:size:)`（`MobileComponents.swift`），内部结构与 `MBrassPill` 一致，只是 `Circle()` 容器：
  - 图标用 SF Symbol（矢量，满足“圆形 SVG”要求）：保存预设用 `bookmark`，加号态可用 `bookmark.fill`。
  - `accessibilityLabel("保存预设")`，44pt 命中区域（`contentShape` 外扩）。
  - 有保存动作进行中时显示 `ProgressView` 并禁用。
- 位置必须在“调色 / 导出”左侧，不能放回左上角。

### 2.6 保存弹窗（两个台共用一套结构）

用系统 `.sheet`：

```swift
.sheet(isPresented: $presetSaveOpen) {
    MPresetSaveSheet(...)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MRadius.sheet)
        .presentationBackground(MColor.surface1)
}
```

内容从上到下：

1. 标题“保存显影预设 / 保存调色预设”，右上角“取消”。
2. 名称输入框：系统 `TextField`，自动聚焦，最多 20 字，右侧显示字数。
3. 固定项摘要：
   - 显影：当前胶片 · 相纸 · 黑白（只读）。
   - 调色：不显示固定项。
4. 勾选列表：
   - 显影：按 `proPages` 分组，组头带“全选 / 全不选”；每行左侧 `MCheckRow`（自绘勾选框，44pt 行高），右侧显示当前值和单位。下拉类显示当前选项文字。
   - 调色：5 个组一行，显示组名与包含项摘要；LUT 组显示“LUT 名称 + 强度”。
5. 底部“保存”主按钮：
   - 名称为空 / 全空白：禁用并提示“请输入预设名称”。
   - 重名：禁用并提示“已有同名预设，请换一个名称”。
   - 显影专业参数一项未勾选：允许保存（只保存胶片组合），但按钮上方提示“仅保存胶片与相纸”。
   - 调色一组未勾选：禁用并提示“至少选择一组参数”。
6. 保存成功：关闭 sheet，列表刷新，Toast“已保存预设 · 名称”，轻触反馈。

**名称去重策略**：不做“自动改名”，直接阻止重名。理由：直出模式按名称展示预设，重名会让用户无法区分。

### 2.7 应用预设

显影：新增 `MobileDevelopSession.applyUserPreset(_ preset: MUserDevelopPreset)`：

1. `pushUndo(key: "develop.userPreset")`，只一次。
2. `var next = edit`
3. 写入 `filmStock / printStock / monochrome`，并按现有 `scanFilmForSelection` 规则修正 `io.scanFilm`。
4. 遍历 `preset.pro`：
   - `.number` → `writePro(id:value:into:&next)`
   - `.flag` → `writeProToggle(id:value:into:&next)`
   - `.option` → `writeProChoice(id:value:into:&next)`
   - 需要先把现有 `writePro / applyProToggle / applyProChoice` 的写入逻辑抽成 `into: inout PhotoEdit` 版本，原方法变成薄包装，避免重复 switch。
5. 对预设中包含、且会映射到快速轴的专业控件，标记对应快速轴冻结（见 3.4）。
6. `edit = next`，`publishFromEdit()`，`persistNow()`，`schedulePreview()`。

调色：改造 `MobileGradeSession.applyPreset(_:)`：

```swift
let groups = preset.groups ?? Set(MGradeGroupKey.allCases)
displayRecipe.merge(preset.recipe, groups: groups)
if groups.contains(.lut) {
    lutPath = preset.recipe.lut.path
    displayRecipe.lutName = ...
}
```

`GradeScreen` 里现有的 `recipe = MGradeRecipe(grade:...)` 全量替换要改成 merge，否则部分保存失效。`onChange(of: recipe)` 仍负责推撤销与 `session.apply`。

### 2.8 列表与左滑删除

- 显影台预设列表：`MobileDevelopPresets.all` 只读 + 用户预设可删。
- 调色台预设列表：`session.presets`（`GradePresetStore.shared.all`），`builtin == true` 不可删。
- 左滑交互**不要用 `List`**：两个台的预设列表都在抽屉 `ScrollView` 里，嵌套 `List` 会导致滚动冲突与高度塌陷。新增自绘 `MSwipeDeleteRow`（`MobileComponents.swift`）：
  - 内容行 + 右侧红色“删除”按钮；
  - `DragGesture(minimumDistance: 12)`，只有水平位移大于垂直位移才接管，避免抢抽屉纵向滚动；
  - 左滑超过 40pt 展开删除按钮；继续超过 60% 行宽或快速甩动直接触发删除；
  - 同一时间只允许一行展开，由列表持有 `@State openedRowID`；
  - 展开/回弹用 `.spring(response: 0.28, dampingFraction: 0.86)`，删除用 `.easeInOut(0.2)`；
  - 无障碍：`.accessibilityAction(named: "删除")`。
- 删除后：
  - 立即从存储删除并刷新列表；
  - Toast“已删除预设”并提供 4 秒“撤销”（需要给现有 Toast 增加可选 action）；
  - 如果直出模式当前选中的预设被删除，自动回退到第一个显影预设 / “中性”，并 Toast 说明。
- 显影内置预设、调色 `builtin == true` 不显示左滑，避免误删不可恢复内容。

### 2.9 防呆清单（功能一）

- [ ] 空名、纯空格、超长名。
- [ ] 同名（含大小写与首尾空格）。
- [ ] 显影专业参数 0 勾选、调色 0 组勾选。
- [ ] 保存时用户快速连点，第二次被 `isSaving` 拦截。
- [ ] 预设数组为空时列表显示空状态，不出现空白区。
- [ ] 删除正在被直出模式引用的预设。
- [ ] 旧 `grade_presets.json` 没有 `groups` 字段仍能解码。
- [ ] 调色预设应用后，裁切、边框、几何状态完全不变。

---

## 3. 功能二：显影台快速 / 专业联动

### 3.1 问题根因

- 快速轴通过 `applyQuickMapping` 写入 `PhotoEdit` 的若干专业字段。
- 专业页 `applyPro / applyProToggle / applyProChoice` 直接写同一批字段，但不更新 `quickIntents`。
- `quickValues` 仍来自 `quickIntents`，于是“快速滑块显示 0，但画面已经被专业参数改变”，下一次拖快速轴又会按 `baseline` 重算并覆盖专业改动。

解决思路：**专业参数一旦接管某个快速轴，该轴冻结**。冻结不是全局开关，而是逐轴。

### 3.2 快速轴 → 专业控件映射

以 `MobileDevelopSession.applyQuickMapping` 现有实现为准：

| 快速轴 | 受影响专业控件 ID | 说明 |
|---|---|---|
| `camera_exposure` | `exposure_compensation_ev` | 同时会临时关闭 `print_exposure_compensation` |
| `print_brightness` | `print_exposure` | 按 2 的幂换算 |
| `tonal_contrast` | `gamma_factor` | `densityCurvesMorph.gammaFactor` |
| `highlight_softening` | `developer_exhaustion` | 复用专业“高光柔和” |
| `color_density` | `inhibition_interlayer`、`couplers_active` | 快速非零会启用成色剂 |
| `grain_amount` | `grain_density_min`、`grain_uniformity`、`grain_active` | 强度轴 |
| `grain_size` | `particle_area_um2`、`grain_blur` | 尺寸轴 |
| `scanner_clarity` | `scanner_unsharp_amount`、`scanner_unsharp_sigma`、`scanner_lens_blur` | 正负方向分别动锐化 / 模糊 |
| `temperature` | `print_y_filter_shift` | 快速正值更暖，引擎取负 |

反向映射写在 `MobileDevelopSession`：

```swift
static func quickAxes(affectedByPro id: String) -> [String]
```

只有表内的专业控件会触发冻结；`white_balance`、`crop`、`output_gamut_compress` 等不影响快速轴的控件不冻结任何轴。

### 3.3 冻结状态存放

在 `PhotoEdit` 增加可选字段（`PhotoEdit` 已含 `quickIntents`，冻结状态属于同层语义）：

```swift
var frozenQuick: [String]? = nil
```

理由：

- 撤销栈当前只存 `PhotoEdit`，放进同一快照后撤销天然一致。
- `persistNow` 直接落盘，重开照片仍保持冻结，不会出现“专业值还在、快速轴又能拖”的错位。
- 直出工程回放时也能正确表达。

注意：合成 `Codable` 对 optional 使用 `decodeIfPresent`，旧 JSON 缺字段会得到 `nil`，无需迁移。

访问器：

```swift
var frozenQuickAxes: Set<String> {
    get { Set(frozenQuick ?? []) }
    set { frozenQuick = newValue.isEmpty ? nil : Array(newValue).sorted() }
}
```

### 3.4 冻结规则

1. **专业滑块 / 开关 / 下拉**：
   - `applyPro`、`applyProToggle`、`applyProChoice` 写入后，把 `quickAxes(affectedByPro: id)` 中的轴加入 `frozenQuickAxes`。
   - 只有值真正变化时才冻结；无变化的重复点击不冻结。
2. **快速拖动**：
   - `applyQuick` 开头 `guard !frozenQuickAxes.contains(id) else { return }`。
   - `applyQuickMapping` 内部也跳过冻结轴，双保险。
3. **应用用户显影预设**：
   - 预设包含的专业控件若命中映射表，应用后冻结对应快速轴。
   - 预设只改胶片 / 相纸 / 黑白时，不冻结任何轴。
4. **重置**：
   - `resetAllDevelop()`：`frozenQuick = nil`，快速轴恢复。
   - `resetQuick()`：如果存在冻结轴，先把冻结轴对应的专业字段恢复为 `baseline` 值，再清空 `frozenQuickAxes` 与 `quickIntents`。这样“重置快速”不会留下专业改动，也不会出现假恢复。
   - `resetPro()`：保留现状（回到 `baseline`），同时 `frozenQuick = nil`。
5. **撤销**：`undo()` 恢复 `PhotoEdit`，冻结集合随快照回退，无需额外逻辑。
6. **换胶片 / 换相纸**：不改变冻结集合；`setFilm` 已有的 `applyQuickMapping` 循环需要跳过冻结轴。
7. **快速页 / 专业页切换**：不改变冻结状态。

### 3.5 快速模式 UI

- 冻结轴滑块：
  - 整体透明度 0.38，轨道变灰，圆点替换为小锁图标（`lock.fill`）。
  - 禁止拖动；点击时 Toast“专业模式已接管此参数，重置后恢复”。
  - 数值仍显示最后一次快速值，但视觉上明确不可用。
  - 无障碍：`accessibilityValue("已冻结")`，`accessibilityHint` 说明重置路径。
- 快速页顶部横幅（仅当 `frozenQuickAxes` 非空时显示）：
  - 文案：**“专业模式有调整，重置参数后恢复”**
  - 样式：黄铜色细边胶囊 / 条，左侧 `info.circle`，右侧“重置显影”文字按钮。
  - 点“重置显影”调用 `resetAllDevelop()`（可撤销），不弹二次确认。
- 未冻结的轴保持正常，可继续拖。
- 快速页的“一键重置快速”按钮在存在冻结轴时改文案为“重置并恢复快速”，避免用户误以为只清快速值。

### 3.6 重置按钮迁移

- 显影台新增 `resetAllDevelop()`：
  - `pushUndo(key: "reset.develop.all")`
  - `edit = initialEditData ?? baseline`（需要 session 在 `init` 时额外保存 `initialEdit`）
  - `filmID / paperID / isMonochrome` 从 `edit` 重新发布
  - `quickIntents = edit.quickIntents`（导入时通常为空）
  - `frozenQuick = nil`
  - `publishFromEdit()`、`persistNow()`、必要时 `scheduleRawReload()`
  - 注意：`initialEditData` 包含导入时的 `loadRaw`、旋转、裁切等，全部回到导入态；调色台的 `geometry / cropData / border` 不受影响。
- 按钮从专业页底部移除，迁到抽屉 `drawerToolRow`，放在**撤回按钮左侧**：
  - `[重置圆钮][撤回圆钮][缩放...]`
  - 圆形、无文字，图标 `arrow.counterclockwise`，与 `MCircleIconButton` 一致。
  - 当 `edit == initialEdit` 时禁用（降低透明度），避免无效点击。
- 调色台已有 `resetAllGrade()`（`GradeScreen.navigationBar` 左侧圆形按钮），保留现状；确认它只重置调色 recipe，不动裁切 / 边框。若现在会动裁切，需要收窄到只重置 `recipe` 与 `lutPath`。

### 3.7 防呆清单（功能二）

- [ ] 专业页快速拖动被冻结轴不响应，但其他轴正常。
- [ ] 撤销后冻结状态与参数同步回退。
- [ ] 重开照片后冻结横幅仍存在。
- [ ] 应用显影预设后，被接管的快速轴显示冻结。
- [ ] `resetQuick` 后冻结轴对应专业值确实回到基线。
- [ ] 换胶片不会把冻结轴重新激活。
- [ ] 重置显影后调色 recipe / 裁切 / 边框不变。

---

## 4. 功能三：相机优化

### 4.1 计时器

**入口**：顶栏下方新增一条相机工具条（或顶栏右侧控制簇），包含 `计时器 / 网格 / 直出`。点击计时器后，**整条工具条切换为二级菜单**：

`关闭 · 3 秒 · 5 秒 · 10 秒`

- 四个选项使用极简线性 SVG 风格图标：关闭 = 斜线圆圈；3/5/10 = 圆形计时器 + 数字。
- 当前选项黄铜高亮；选择后菜单收起，按钮显示当前档位（关闭时不显示角标）。
- 状态持久化：`@AppStorage("mobile.camera.timer")`，默认 0（关闭）。
- 倒计时：
  - 快门按下后进入倒计时，取景框中央显示大号剩余秒数 + 环形进度；
  - 每秒一次 `MHaptic.tick()`，最后 1 秒 `MHaptic.light()`；
  - 倒计时期间快门禁用、显示“取消”；点击取景框任意位置取消；
  - `scenePhase != .active` 立即取消；
  - 倒计时结束调用现有 `camera.capture()`，并恢复按钮。
- 与直出模式不冲突：直出渲染卡片显示期间禁用快门与计时器。

### 4.2 网格线

- 取景框内叠加九宫格：两条竖线、两条横线，位置 1/3、2/3。
- 线宽 0.5–0.7pt，白色 0.35，外侧轻微黑色阴影保证亮背景下可见；圆角裁剪跟随取景框。
- 开关在相机工具条；状态 `@AppStorage("mobile.camera.grid")`，默认关闭。
- 切换用 `.easeInOut(0.18)` 淡入淡出，不重建预览层。
- 网格不拦截触摸（`.allowsHitTesting(false)`）。

### 4.3 水平仪

新增 `MLevelMonitor`（`SpektraMobile/Sources/Engine/MLevelMonitor.swift`）：

```swift
@MainActor
final class MLevelMonitor: ObservableObject {
    @Published private(set) var roll: Double = 0        // 度，-180...180
    @Published private(set) var pitch: Double = 0       // 度，0...90 离水平面
    @Published private(set) var isLevel = false
    @Published private(set) var mode: Mode = .horizontal
    enum Mode { case horizontal, topDown }
    func start()
    func stop()
}
```

- `CMMotionManager.deviceMotionUpdateInterval = 1.0 / 60.0`，在后台队列取样，主线程发布。
- 重力投影：
  - 竖拍：`roll = atan2(g.x, -g.y) * 180 / π`
  - 横拍：按 `UIDevice.current.orientation` / 现有 `badgeAngle` 旋转 90° 或 -90° 后再计算，保证水平线始终相对真实地平线。
  - `pitch = asin(clamp(-g.z, -1, 1)) * 180 / π`（屏幕朝上、镜头朝下时接近 90°）。
- 模式切换：
  - `pitch < 45°` → 水平仪；
  - `pitch ≥ 45°` → 俯拍十字。
  - 加 3° 回差，避免边界抖动。

**水平模式视觉（对齐 iOS 原生）**：

- 屏幕中央一条短水平参考线（约 120pt），左右两段；倾斜时两段沿垂直方向反向错位，错位量映射 `roll`。
- 对准（`|roll| < 0.5°`）时两段合并为一条绿色实线，两侧出现小刻度。
- 角度绝对值显示在线的右侧（如 `1.2°`），对准后隐藏。
- 变绿瞬间 `UIImpactFeedbackGenerator(style: .light)` 触发一次；离开 ±1.5° 才解除，带迟滞防止连续震动。

**俯拍十字视觉**：

- 中央十字 `+` + 一个可移动小圆点（气泡）。
- 气泡位置由重力在屏幕平面的投影决定；进入中心圆环（半径约 10pt）即对准。
- 对准后十字与圆环变绿，轻触反馈；离开后恢复白色。

**显隐与性能**：

- 仅在设置“水平仪”开启、相机授权、`scenePhase == .active` 时启动；
- 直出渲染卡片显示、倒计时数字覆盖时隐藏；
- 页面消失 / 切后台立即 `stop()`，避免 CoreMotion 常驻耗电。

### 4.4 设置页“相机”分区

在 `SettingsScreen` 的“输入”之后、“导出”之前插入 `cameraSection`：
`MSectionHead(title: "相机")` + `MToggleRow`。

| 开关 | 默认 | 存储键 | 说明 |
|---|---|---|---|
| 水平仪 | 开 | `mobile.camera.level` | 控制 4.3 的显隐与 CoreMotion 启停 |
| 镜像前置相机 | 关 | `mobile.camera.mirrorFront` | 副标题“仅前置 RAW 机型生效” |
| 拍摄后进入显影台 | 开 | `mobile.camera.enterDevelop` | 关闭后连续拍摄，停留在取景页 |
| 音量键拍摄 | 开 | `mobile.camera.volumeShutter` | 调用 `AVCaptureEventInteraction` |
| 直出模式保存原图 | 关 | `mobile.camera.directSaveOriginal` | 直出保存时是否保留 RAW 与工程 |

**镜像前置的诚实处理**：

- 现有 `MCameraSession.flip()` 在前置无 RAW 时会回退，iPhone 前置基本拿不到 DNG。
- 因此该开关在检测不到前置 RAW 设备时置灰，副标题显示“当前机型前置不支持 RAW”。
- 一旦前置 RAW 可用：
  - 预览层设置 `automaticallyAdjustsVideoMirroring = false`、`isVideoMirrored = true`；
  - 直出渲染输出做一次水平翻转；
  - RAW 原始 DNG **不翻转**（DNG 无法无损镜像），设置页副标题明确“仅预览与直出成片镜像”。
- 不要为了这个开关去改显影管线；这属于相机层职责。

**音量键拍摄**：

- `AVCaptureEventInteraction` 仅 iOS 17.2+ 可用，部署目标 17.0 需要 `if #available(iOS 17.2, *)`。
- 挂载在 `MCameraPreview` 内部的 `MPreviewView` 上，避免额外视图层级。
- 处理 `primaryAction` → 触发与快门相同的 `capture()` 路径（含计时器、直出判断）。
- 低于 17.2 或开关关闭时不安装 interaction；设置页开关在低版本置灰并提示“需要 iOS 17.2”。

**连续拍摄**：

- `CameraScreen` 的回调从 `onCaptured: (URL) -> Void` 改为 `onCaptured: (URL, enterDevelop: Bool) -> Void`。
- `MobileRootView.openCaptured(url, enterDevelop:)`：
  - 始终 `importPhotos([url], publishToAlbum: true)`；
  - `enterDevelop == true` 且仍在相机页 → 打开显影台；
  - `false` → 只刷新图库与缩略图，停留相机，Toast“已保存到访达”；
  - 保留“用户在入库期间关闭相机就不再强行跳页”的现有判断。
- 连续拍摄时 `lastShotThumbnail` 显示最新一张；连拍计数可用右上角小角标（可选，不强制）。

### 4.5 防呆清单（功能三）

- [ ] 计时器倒计时中再次按快门 / 音量键无效。
- [ ] 倒计时中关闭相机、切后台、进入直出渲染都能取消。
- [ ] 水平仪在横竖拍切换时不跳动错位。
- [ ] 俯拍与水平模式切换无边界抖动（3° 回差）。
- [ ] 对准只触发一次触感，离开再回正才再次触发。
- [ ] 音量键在 17.0/17.1 上不崩溃。
- [ ] 关闭“拍摄后进入显影台”后连拍不跳页，且图库有记录。
- [ ] 前置无 RAW 时镜像开关置灰，不出现“开了没效果”。

---

## 5. 功能四：直出模式

### 5.1 状态机

```
off ──tap──> armed(预设已选) ──shutter──> rendering ──完成──> ready(重拍/保存)
 ↑                    ↑                        │                    │
 └──────tap────────────┴──────失败/取消─────────┘        保存成功 ──> armed
```

- `off`：普通拍摄，按“拍摄后进入显影台”设置决定是否进显影。
- `armed`：直出开关打开，取景页正常；顶部直出按钮黄铜高亮。
- `capturing`：快门已按，RAW 落盘。
- `developing`：中央白色相片卡片显示显影动画，同时后台渲染。
- `ready`：渲染完成，卡片显示成片 + “重拍 / 保存”。
- `saving`：保存中，按钮转圈并禁用。
- `failed`：卡片显示错误与“重试 / 重拍”。

同一时间只允许一个直出任务；`isDirectBusy` 时快门、计时器、预设选择器、关闭相机都要有明确行为（关闭相机先取消任务并清理临时文件）。

### 5.2 开关与预设选择器

- 位置：相机顶部工具条最右侧，圆形 SVG 开关。
- 点击：切换直出模式；长按（0.45s）：在图标正下方展开预设选择器。
- 长按与点击共存：`Button` + `.simultaneousGesture(LongPressGesture(minimumDuration: 0.45))`，长按触发后抑制本次 tap。
- 选择器：
  - 两列：左“显影”、右“调色”。
  - 每列独立 `ScrollView`，最大高度约 260pt，圆角 18pt，`mGlassSurface`（26+）/ 实心暗色（17–25）。
  - 显影列表：`MobileDevelopPresets.all` + 用户预设；默认第一个（`standard` 标准负片）。
  - 调色列表：`GradePresetStore.shared.all`；默认 `builtin:neutral`（中性）。
  - 选中行黄铜勾选；两列始终有默认值，因此不存在“未选满”。
  - 点击取景框任意位置收起；再次点击直出按钮也收起。
  - 选择持久化：`@AppStorage` 存预设 ID；启动时若 ID 已失效，回退默认并 Toast。
- 直出关闭时保留上次选择，不清空。

### 5.3 拍摄与渲染

**渲染输入**：

- 原始 DNG（`camera.lastShot.url`）
- 显影预设 → 构造 `PhotoEdit`
  - 内置预设：复用现有 `MDevelopPreset` 的 `quick` 映射；
  - 用户预设：`filmID / paperID / monochrome + pro`，以及冻结轴集合。
- 调色预设 → `GradeRecipe`（只取勾选组；直出默认全组）。
- 导出参数：`MobileSettings` 的格式、长边、质量、水印开关。
- 裁切：不应用；片边：不应用（直出预设不包含这两项）。

**处理链**（新增 `MDirectRenderer`，`SpektraMobile/Sources/Engine/MDirectRenderer.swift`）：

1. `ImageLoader.load(url:maxSize:rawOptions:rotationTurns:)` 解码 DNG。
2. `SimulationPipeline` 显影到目标长边；大图按 `ExportEdge.plan` 分带，复用现有内存上限逻辑。
3. 显影输出设为 **ProPhoto RGB 线性**（`params.io.outputColorSpace = "ProPhoto RGB"`、`outputCCTFEncoding = false`），与 `prepareHandoff` 的交接色彩空间一致。
4. `GradeEngine.prepareSource` → `GradeEngine.render(recipe:)` 应用调色。
5. `MWatermarkRenderer.composite`（仅当设置开启水印）。
6. 按导出格式编码：JPEG / TIFF sRGB 16-bit / TIFF ProPhoto 16-bit / EXR ACES half。
7. 返回临时文件 URL + 预览用 `CGImage`。

> 不建议直接复制 `MobileDevelopSession.export` 的整段代码。正确做法是把“解码 → 显影 → 分带 → 编码”抽成 `MDevelopRenderService`，让普通导出与直出共用；调色和水印作为可选后处理。这样避免两条链路日后分叉。

**进度**：

- `SimulationPipeline.processTiled` 已有 `progress` 回调（阶段 + 条带），直出卡片用它驱动显影动画。
- 单带渲染没有进度时，按阶段映射：解码 0.05 → 显影 0.1–0.7 → 调色 0.75–0.9 → 编码 0.95 → 1.0。
- 动画不得早于真实完成：进度到 0.9 后等待渲染完成再跳到 1.0；设置最短展示 1.2s，避免小图一闪而过。

### 5.4 显影卡片与动画

- 卡片位置：屏幕中央，宽约屏宽 72%，3:4 白色相纸，圆角 2–4pt（拍立得感），投射阴影。
- 内部图像区域：
  - 初始近白（`white` 叠加 0.92）；
  - 随进度逐渐降低白遮罩、提高对比与饱和度，模拟拍立得显影；
  - 可叠加轻微暗角与颗粒，但不要做“描边光走过”的假循环。
- 使用 `TimelineView` 或 `Canvas` 驱动遮罩，进度来自渲染，不用手写 `asyncAfter` 链条。
- 渲染完成：
  - 卡片只显示成片 + 下方“重拍”“保存”两个按钮；
  - `UINotificationFeedbackGenerator().notificationOccurred(.success)` 轻触反馈；
  - 保存按钮为主按钮（黄铜），重拍为次按钮。
- 卡片显示期间：
  - 取景框变暗（黑色 0.55），不可对焦 / 不可快门；
  - 工具条与预设选择器隐藏；
  - 关闭相机按钮保留，点击先取消任务。

### 5.5 保存策略

**设置“直出模式保存原图”开启**：

1. 渲染成功后，先把 RAW 临时文件 `importPhotos([url], publishToAlbum: true)` 入库，拿到 `photoID`。
2. 把直出结果写回该记录：
   - `edit` = 显影预设生成的 `PhotoEdit`
   - `initialEditData` = 导入时默认编辑（保留“重置回导入态”）
   - `quickBaselineData` = 同一份导入默认
   - 新增 `gradeData` = 编码后的 `GradeRecipe`（含 LUT 路径）
   - `thumbnail` = 渲染成片缩略图
   - `isGraded = true`
3. 系统相册：RAW 由 `publishImportsToAlbum` 写入；渲染成片再由 `PhotoLibraryExport.save` 写入。
4. 访达“RAW”项目显示：缩略图使用成片，打开显影台时使用 `edit`，进入调色台时从 `gradeData` 恢复 recipe。
5. Toast“已保存原图与成片”。

**设置关闭**：

1. 不调用 `importPhotos`，不生成 `LibraryPhoto`，不写 RAW 到系统相册。
2. 只把渲染成片写入系统相册。
3. 访达不出现该照片；Toast“成片已保存到相册”。

**格式与权限**：

- 相册不支持 EXR：直出保存时若格式为 EXR，自动回退 JPEG 并 Toast“相册不支持 EXR，已保存 JPEG”。普通导出仍保留 EXR 文件分享。
- 相册权限拒绝：卡片保留，显示“无法写入相册，请在设置中允许访问”，提供“打开设置”。
- 保存失败：保留卡片，按钮恢复，可重试；不重复导入同一 RAW（用 `didImportOriginal` 标记）。
- 重拍：删除渲染临时文件；若原图已导入（保存原图流程尚未点保存就重拍），不应提前导入 —— 所以**原图入库放在点“保存”之后**，重拍永远不产生库记录。

### 5.6 完整工程回放

新增 `LibraryPhoto.gradeData: Data?`：

- `LibraryStore` 的 Codable 自动兼容旧记录（optional）。
- `MobileGradeSession.init` 若 `photo.gradeData` 存在，解码为 `GradeRecipe`：
  - `displayRecipe = MGradeRecipe(grade: recipe, lutName: ...)`
  - `lutPath = recipe.lut.path`
  - 仍以 `photo.cropData` / `photo.borderData` 恢复几何与边框。
- 打开调色台时不再从空白 recipe 开始，直出工程可以继续微调并再次导出。

### 5.7 与现有功能的冲突处理

| 场景 | 处理 |
|---|---|
| 直出开启 + “拍摄后进入显影台”开启 | 直出优先，不进显影台；设置项仅在直出关闭时生效 |
| 直出开启 + 计时器 | 允许；倒计时结束才捕获，渲染卡片出现后禁用计时器 |
| 直出渲染中关闭相机 | `cancel()` 渲染任务、删除临时文件、丢弃结果；不写相册 |
| 直出渲染中切后台 | 暂停 UI 动画；渲染可继续，完成后若页面已销毁则清理临时文件 |
| 直出渲染中再按快门 / 音量键 | `isDirectBusy` 拦截，Toast“正在显影” |
| 预设被删除 | 选择器回退默认；若正在渲染，使用已捕获的快照，不中断 |
| 相册权限被拒 | 卡片保留可重试；不丢渲染结果 |
| RAW 导入失败（保存原图开） | 仍保存成片，Toast“原图未保存，成片已保存” |
| 低电量 / 内存警告 | 直出按导出长边分带；失败时提示降低导出尺寸，不崩溃 |

### 5.8 防呆清单（功能四）

- [ ] 直出开关关闭后，所有普通拍摄行为与现在完全一致。
- [ ] 预设选择器两列始终有选中项，不存在空选择。
- [ ] 长按后松手不会误触切换开关。
- [ ] 渲染完成前不显示“保存”。
- [ ] 重拍不产生任何相册 / 访达记录。
- [ ] 保存原图关闭时，访达与系统相册都没有 RAW。
- [ ] 保存原图开启时，访达缩略图是成片，进入调色台能恢复参数。
- [ ] EXR、权限拒绝、导入失败都有明确提示与可重试路径。
- [ ] 连续拍摄两次直出不会串图（每次任务独立 ID）。

---

## 6. 文件改动清单

### 6.1 修改

| 文件 | 改动 |
|---|---|
| `SpektraMobile/Sources/Models/MobileModels.swift` | `MProValue`、`MUserDevelopPreset`、`MDevelopPresetStore`；`MGradeRecipe.merge`；`MDevelopPreset` 增加 `builtin` 标识（可选） |
| `Sources/SpektraCore/Grade/GradePresets.swift` | `MGradeGroupKey`、`GradePreset.groups`、解码兼容、`save(name:recipe:groups:)` |
| `Sources/SpektraCore/Services/LibraryStore.swift` | `LibraryPhoto.gradeData` |
| `SpektraMobile/Sources/Engine/MobileDevelopSession.swift` | 写入方法 `into:` 版本；`applyUserPreset`；冻结轴；`resetAllDevelop`；`resetQuick` 恢复冻结轴；`undo` 随快照 |
| `SpektraMobile/Sources/Engine/MobileGradeSession.swift` | `applyPreset` 按组合并；`savePreset(groups:)`；`deletePreset`；`presets` 刷新；`gradeData` 恢复 |
| `SpektraMobile/Sources/Engine/MCameraSession.swift` | 音量键 interaction 挂载支持；前置镜像配置；暴露捕获方向 |
| `SpektraMobile/Sources/Engine/MobileEngine.swift` | 直出结果写回：`applyDirectResult(photoID:edit:gradeData:thumbnail:)`；静默导入路径 |
| `SpektraMobile/Sources/Screens/CameraScreen.swift` | 工具条、计时器、网格、水平仪、直出开关、预设选择器、显影卡片、保存流程、回调签名 |
| `SpektraMobile/Sources/Screens/DevelopScreen.swift` | 保存圆钮、保存弹窗、用户预设列表、左滑删除、冻结 UI、重置按钮迁移 |
| `SpektraMobile/Sources/Screens/GradeScreen.swift` | 保存圆钮、保存弹窗、预设分组勾选、左滑删除、部分应用 |
| `SpektraMobile/Sources/Screens/SettingsScreen.swift` | 相机分区 5 个开关 |
| `SpektraMobile/Sources/Screens/MobileRootView.swift` | `onCaptured` 增加 `enterDevelop` 参数；直出保存后的图库刷新 |
| `SpektraMobile/Sources/Design/MobileComponents.swift` | `MBrassCircleButton`、`MCheckRow`、`MSwipeDeleteRow`、`MToggleRow` 详情副标题、Toast action |

### 6.2 新增（需登记 pbxproj）

| 文件 | 职责 |
|---|---|
| `SpektraMobile/Sources/Engine/MLevelMonitor.swift` | CoreMotion 水平 / 俯拍姿态 |
| `SpektraMobile/Sources/Engine/MDirectRenderer.swift` | 直出显影 + 调色 + 水印 + 编码 |
| `SpektraMobile/Sources/Engine/MDevelopRenderService.swift` | 可选：抽出的共用显影导出核心（推荐） |
| `SpektraMobile/Sources/Views/MPresetSaveSheet.swift` | 保存预设弹窗（若不想拆文件，可并入两个 Screen） |
| `SpektraMobile/Sources/Views/MDirectCard.swift` | 直出显影卡片（可并入 CameraScreen） |

为减少 pbxproj 手工登记，优先把 `MLevelMonitor`、`MDirectRenderer` 放进已有 Engine 文件？不建议：职责过重。至少这两个新文件值得独立。其余视图可内联在 `CameraScreen.swift` / `DevelopScreen.swift` / `GradeScreen.swift`。

---

## 7. 实施顺序

### 阶段 A：预设（功能一）

1. 模型与存储：`MUserDevelopPreset` + `MDevelopPresetStore`；`GradePreset.groups` + 兼容解码。
2. 应用语义：`applyUserPreset`、`MGradeRecipe.merge`、`applyPreset` 部分覆盖。
3. UI：`MBrassCircleButton`、`MCheckRow`、保存弹窗、列表合并、`MSwipeDeleteRow`。
4. 验证：保存 → 重开 App → 应用 → 删除 → 撤销。

### 阶段 B：快速 / 专业冻结 + 重置（功能二）

1. `PhotoEdit.frozenQuick`、`quickAxes(affectedByPro:)`、写入拦截。
2. `applyPro*` / `applyQuick*` / 预设应用 / 换胶片 全部接入。
3. 快速页冻结样式与横幅；`resetAllDevelop`；重置按钮迁移。
4. 验证：冻结、撤销、重开、重置、换胶片。

### 阶段 C：相机（功能三）

1. `MobileSettings` 五个键 + 设置页分区。
2. 工具条 + 计时器 + 网格。
3. `MLevelMonitor` + 水平 / 俯拍 UI + 触感。
4. 音量键、镜像前置、连续拍摄回调。
5. 验证：真机水平仪方向、音量键、前后台、连拍。

### 阶段 D：直出（功能四）

1. `MDirectRenderer` / `MDevelopRenderService`，先跑通“RAW → 显影 → 调色 → JPEG 临时文件”。
2. 相机直出开关 + 双列预设选择器。
3. 显影卡片 + 进度 + 重拍 / 保存。
4. `LibraryPhoto.gradeData`、保存原图流程、缩略图 / 访达映射、调色回放。
5. 验证：开/关保存原图、权限拒绝、EXR 回退、连续两次直出。

阶段之间互不强依赖，但建议按 A → B → C → D，因为 D 会复用 A 的预设与 B 的冻结语义。

---

## 8. 验收标准

### 8.1 构建

- `./build-ios-preview.sh` 通过（SwiftUI 源码可编译）。
- `xcodebuild -project SpektraMobileApp/SpektraMobile.xcodeproj -scheme SpektraMobile -destination 'generic/platform=iOS Simulator' build` 通过。
- 无 Swift 6 并发警告新增；CoreMotion / AVFoundation 回调不跨 actor 直接改 UI。

### 8.2 回归矩阵

| 用例 | 期望 |
|---|---|
| 显影台改 3 个专业参数 → 保存预设 → 重置 → 应用 | 3 个参数恢复，其他参数保持应用前的值 |
| 快速曝光 +50 → 专业曝光改 0.5 → 快速滑块 | 冻结、不可拖、横幅出现 |
| 上述状态撤销 | 快速轴与专业值一起回到上一步 |
| 保存调色“仅光影” → 应用 | 只改光影，色调 / 质感 / 细节 / LUT / 裁切不变 |
| 左滑删除用户预设 | 列表移除，直出选择回退 |
| 相机切 3 秒 → 快门 | 3 秒倒计时后拍摄，倒计时可取消 |
| 网格开 | 取景框出现九宫格，不挡触摸 |
| 水平仪竖拍 / 横拍 / 俯拍 | 三种姿态显示正确，对准变绿并轻触一次 |
| 设置关闭“拍摄后进入显影台” → 连拍 2 张 | 停留相机，图库新增 2 张 |
| 音量键拍摄 | 与快门一致，含计时器与直出 |
| 直出开 + 保存原图关 → 拍 1 张 → 保存 | 相册只有成片；访达无记录 |
| 直出开 + 保存原图开 → 拍 1 张 → 保存 | 相册有 RAW + 成片；访达缩略图是成片；调色台可恢复参数 |
| 直出 EXR | 成片回退 JPEG 并提示 |
| 直出渲染中关闭相机 | 无残留临时文件、无相册写入 |

### 8.3 UI 评审

- 保存按钮在右上角、调色 / 导出左侧，圆形无文字。
- 重置按钮在撤回左侧，圆形无文字。
- 所有 sheet 有系统 grabber / detent，无自绘 scrim。
- 触控目标 ≥ 44pt；关键读数等宽数字；Dynamic Type 不撑破抽屉。
- 无固定 `852 / 393 / 54 / 34` 画布常量新增。

---

## 9. 风险与取舍

| 风险 | 说明 | 对策 |
|---|---|---|
| 直出渲染耗时 | 全尺寸显影 + 调色 + 编码在手机 CPU 上可能数秒 | 分带渲染、进度驱动动画、渲染中禁止重复操作；必要时先按导出长边上限（2048/4096）渲染 |
| 内存峰值 | RAW 解码 + 显影 + 调色同时持有大图 | 复用 `ExportEdge.plan` 内存上限；中间图及时释放；`ImageRGB` 避免 COW 复制 |
| CoreMotion 漂移 | 长时间使用水平仪可能偏差 | 每次启动重新取样；水平态带迟滞；不持久化校准值 |
| 前置 RAW 缺失 | 镜像开关可能永远不可用 | 明确置灰与副标题，不做假开关 |
| 预设存储迁移 | 旧 JSON 无新字段 | 全部 optional + 自定义解码 + schema 字段 |
| 快速冻结语义复杂 | 用户可能不理解为什么滑块不能动 | 横幅 + 锁图标 + “重置显影”一键恢复；不打全局模态弹窗 |
| 文件夹结构 | 新增文件需手改 pbxproj | 优先内联；必须新增时按 FileReference → Group → Sources 三步登记并编译验证 |
| 直出与普通导出分叉 | 两套代码日后不一致 | 抽出 `MDevelopRenderService`，普通导出与直出共用 |

---

## 10. 明确不做

- 不新增显影 / 调色算法。
- 不改 RAW 解码与色彩管理链路。
- 不为预设增加云同步、导入导出（本次范围外）。
- 不做直出模式的自定义画幅、片边、裁切。
- 不改 iPad 分栏布局；新增控件若进入 iPad 布局，只做可用性适配，不重排信息架构。
- 不把 `List` 嵌入抽屉来换取原生左滑；滚动一致性优先，用自绘 `MSwipeDeleteRow` 还原交互。
