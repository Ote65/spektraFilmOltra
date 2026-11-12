# iPadOS 版本交接文档

> 状态：**开发中断，未编译、未验收**。当前工作树有 4 个文件已改未提交。
> 交接时间：2026-11-11
> 工作目录：`/Users/megmeet/Documents/开发 APP/SpektrafilmSwift-ios`（分支 `iOS`）

---

## 一、现状

### 已完成（代码已改，但一次都没编译过）

| 文件 | 改了什么 |
|---|---|
| `SpektraMobile/Sources/Design/MobileTokens.swift` | 新增 `MLayout` 枚举：`isPad`、`usesSplit(_:)`、`inspectorWidth(for:)`、`gridColumns(for:)`（第 123–154 行） |
| `SpektraMobile/Sources/Design/MHousing.swift` | `detect()` 首行加 iPad 判断，平板直接返回 `.none`，避免横屏顶部安全区 24pt 被误判成「刘海」而画出假光效（第 66–69 行） |
| `SpektraMobile/Sources/Screens/MobileRootView.swift` | ① 启动页面为相机时 iPad 强制回落主页（第 29 行）；② 新增窗口尺寸 preference，旋转 / 分屏 / 台前调度时刷新真实安全区（第 146–159 行 + 文件末尾 `MWindowSizeKey`）；③ `openCamera()` 在 iPad 直接 return（第 203–207 行）；④ `beginSuck()` 在 iPad 跳过吸入动画，直接进调色台（第 289–296 行） |
| `SpektraMobile/Sources/Screens/DevelopScreen.swift` | 显影台横屏左右分栏：新增 `isSplit`（第 55 行）；`body` 拆成 `stackedLayout`（第 111 行，原单列逻辑原样搬入）与 `splitLayout`（第 162 行）；抽出 `drawerToolRow`（第 664 行）；分栏下隐藏抽屉 chevron；`tabBar` 由属性改为 `tabBar(bottomPadding:)` 函数（第 1262 行） |

### 未完成

- 调色台（`GradeScreen`）**完全没有开始**，仍是单列。
- 主页网格仍固定两列；iPad 底部相机按钮**仍然显示**（点了没反应，因为 `openCamera` 已守卫）。
- 设置页「软件打开页面」仍提供「相机」选项。
- **工程配置还没改**：现在 `TARGETED_DEVICE_FAMILY = "1"`、`Info.plist` 只有 `UIInterfaceOrientationPortrait`，所以 iPad 上跑起来也只能竖屏、也无法以 iPad 原生形态安装。
- 未编译验证。分栏代码可能存在编译错误或布局问题。

---

## 二、硬约束

1. **禁止新建 Swift 文件**。机器上没有 xcodegen，`project.pbxproj` 需手工三处注册，风险高。本次全部新符号都塞进了 `MobileTokens.swift` 等既有文件，后续请沿用这个做法。
2. **不要改 `Sources/SpektraCore`**：引擎与 Python 参考实现共用算法语义，动它要跑双端对拍。
3. **iPhone 端视觉与交互必须零变化**。分栏只在 `MLayout.usesSplit == true` 时生效。
4. **iOS 改动默认不提交 git**，除非用户明确要求。
5. 不改视觉体系：沿用暖石墨 + 黄铜，不新造颜色。
6. 用户本人做 UI 实测；助手只做代码、编译与打包，不主动启动模拟器点页面。

---

## 三、需求全貌

- 做 iPadOS 版本，后端（`SpektraCore`）与 iPhone 完全一致。
- **竖屏 / 分屏（窗口宽度小于高度）→ 沿用 iPhone 单列布局。**
- **横屏 → 左右分栏布局**（参考 macOS 版编辑页的左右结构）。
- 功能层面与 iOS 版一致：参数设计、LUT、预设、片边边框都保持 iOS 现有实现，不搬 macOS 的控件。
- **iPad 不做相机功能**。
- UI 尽量使用 iOS 原生组件与原生交互语义。

---

## 四、已确定的设计

### 1. 布局判定（唯一入口）

- 分栏条件：`MLayout.isPad && width > height * 1.02 && width >= 800`。
  - iPad mini 横屏 1133×744 → 分栏。
  - iPad 横屏二分之一分屏（约 507×744）→ 单列。
  - 台前调度任意窗口 → 按实际尺寸实时切换。
- 分栏右栏宽度：`min(430, max(330, width * 0.34))`。
- 主页网格列数：宽 ≥1180 → 5 列；≥980 → 4 列；≥720 → 3 列；否则 2 列。

### 2. 横屏编辑页结构（以显影台为样板）

```
┌───────────────────────────────┬──────────┐
│ 左：画布                       │ 右：参数栏 │
│  · 顶部悬浮控件（返回/调色/快速专业）│ · 工具行  │
│  · 预览 + 捏合缩放 + 平移        │ · 参数面板 │
│  · 左边缘 22pt 返回手势区        │ · 分页胶囊 │
└───────────────────────────────┴──────────┘
```

- 中间用 1px `MColor.hairline` 竖线分隔，不画第二套底色。
- 参数面板在分栏里仍是圆角悬浮窗口（复用原 `drawer`），不改造成贴边面板。
- 原浮在抽屉上方的「旋转 / 预览比例 / 撤销」改为参数栏顶部固定工具行 `drawerToolRow`。
- 分页胶囊 `tabBar(bottomPadding:)` 放在参数栏最底部。
- 顶部安全区统一由 `insets.top` 处理；iPad 横屏约 24pt。

### 3. iPad 形态修正

- 开孔：iPad 一律 `.none`，不画光效。
- 吸入动画：iPad 不播（没有开孔，飞向细线读不出意义），直接切调色台。
- 相机：入口不显示、`openCamera` 守卫、启动页选项回落。注意 `CameraScreen` 代码仍编译在包里，不删除。

---

## 五、待办（按顺序）

### P0 必须完成，否则 iPad 跑不起来

1. **改工程配置**
   - `SpektraMobileApp/project.yml`：`TARGETED_DEVICE_FAMILY: "1,2"`；新增 `UISupportedInterfaceOrientations~ipad`（Portrait / PortraitUpsideDown / LandscapeLeft / LandscapeRight）；iPhone 保持仅 Portrait。
   - `SpektraMobileApp/Info.plist`：加 `UIDeviceFamily = [1, 2]`，加 `UISupportedInterfaceOrientations~ipad` 四向。
   - `SpektraMobileApp/SpektraMobile.xcodeproj/project.pbxproj`：**实际生效的是这里**，Debug / Release 两处 `TARGETED_DEVICE_FAMILY` 都要从 `"1"` 改成 `"1,2"`（`project.yml` 只是留档，不会自动重新生成）。

2. **调色台分栏**（照抄显影台做法）
   - 加 `isSplit = MLayout.usesSplit(insets.size)`。
   - `body` 拆 `stackedLayout` / `splitLayout`。
   - 分栏左列 = `navigationBar` + `previewStage`；右列 = `drawerToolRow`（原 overlay 里的裁切 + `gradeScaleMenu`）+ `drawer` + `toolbar(bottomPadding: 8)`。
   - `drawer` 内 `MDrawerChevron` 用 `if !isSplit` 包住；`.overlay(alignment: .top)` 里的工具行同样 `if !isSplit`。
   - `toolbar` 从属性改成 `toolbar(bottomPadding:)` 函数，调用点两处：单列 `8 + insets.bottom`、分栏 `8`。

3. **主页**
   - `photoGrid` 的写死两列改为 `MLayout.gridColumns(for: insets.width)` 生成 `[GridItem]`。
   - 底部 `cameraEntry` 用 `if !MLayout.isPad` 包住（现在只是点了没反应，按钮还在）。

4. **设置页**
   - `launchOptions` 在 iPad 上过滤掉 `.camera`；`launchTitle` 对已存值兜底成「访达」。

### P1 清理

5. 分栏下 `syncDrawerToContent()` 仍会写 `drawerHeight`（分栏不使用该值），可在 `isSplit` 时直接 return，避免无意义的状态刷新。
6. 检查 `MobileRootView` 的 `--screen camera` 调试分支是否也要在 iPad 上屏蔽（当前未守卫，仅影响调试参数）。

### P2 验收

7. 编译（命令见下），修掉编译错误。
8. 交付给用户自测清单：iPad 横屏显影/调色分栏、竖屏单列、二分之一分屏单列、旋转过程不闪烁、无假刘海光效、无相机入口、参数栏可滚动、画布缩放平移正常。

---

## 六、符号与接口速查

| 符号 | 位置 | 说明 |
|---|---|---|
| `MLayout.isPad` | `Design/MobileTokens.swift` | `UIDevice.userInterfaceIdiom == .pad`，macOS 预览宿主恒 false |
| `MLayout.usesSplit(_ size:)` | 同上 | 横屏分栏判定 |
| `MLayout.inspectorWidth(for:)` | 同上 | 右栏 330–430 |
| `MLayout.gridColumns(for:)` | 同上 | 主页 2–5 列 |
| `MSafeInsets` | `Design/MobileTokens.swift` | `top/bottom/size/width/height/contentHeight` |
| `MScreenMetrics.current()` | `Design/MobileTokens.swift` | 从 key window 读真实安全区 |
| `MWindowSizeKey` | `Screens/MobileRootView.swift` 文件末尾 | 私有 `PreferenceKey`，承载整窗尺寸 |
| `DevelopScreen.isSplit` | `Screens/DevelopScreen.swift` | 分栏开关 |
| `DevelopScreen.stackedLayout` / `splitLayout` | 同上 | 两套版式 |
| `DevelopScreen.drawerToolRow` | 同上 | 旋转/预览比例/撤销 |
| `DevelopScreen.tabBar(bottomPadding:)` | 同上 | 底部 5 个分页胶囊 |
| `MDrawerChevron` | `Design/MobileComponents.swift` | 抽屉二档切换箭头，分栏下隐藏 |
| `MGlassTabCapsule` | 同上 | 分页胶囊容器 |
| `MBackSwipe` | 同上 | 左边缘返回手势，分栏里只给画布列 22pt |
| `MDeviceHousing.detect()` | `Design/MHousing.swift` | 已加 iPad → `.none` |
| `MobileDevelopSession` | `Engine/MobileDevelopSession.swift` | 显影会话，`previewImage / isRendering / rotateClockwise / undo / export` |
| `MobileGradeSession` | `Engine/MobileGradeSession.swift` | 调色会话，`previewImage / sourceReady / prepareCropBase / export` |
| `MobileEngine` | `Engine/MobileEngine.swift` | `openDevelop / openGrade / closeDevelop / closeGrade / refreshAssets` |

---

## 七、审美与交互口径

- 唯一强调色黄铜 `#C7A577`；底色 `#0E0D0B`；参数面板 `surface2` 玻璃质感。分栏不引入新色。
- 分栏分隔只用 1px 发丝线（`MColor.hairline`），不要给右栏加深色底块。
- 参数面板保持圆角 28 的悬浮窗口 + 双层阴影，与 iPhone 上是同一块面板，只是换了位置。
- 动效沿用现有 `MMotion`（`drawer` 抽屉、`state` 分页、`quick` 显隐），不新增曲线。
- 触控目标 ≥ 44pt；图标按钮沿用 `MCircleIconButton`。
- 竖屏 / 分屏下用户不应察觉到任何差异，仍是原来的 iPhone 体验。

---

## 八、开工步骤

1. 先看改动全貌，确认没被覆盖：
   ```bash
   cd "/Users/megmeet/Documents/开发 APP/SpektrafilmSwift-ios"
   git status --short
   git diff --stat
   ```
2. 按第五节 P0-1 先改工程配置（否则 iPad 上没有横屏，分栏代码根本跑不到）。
3. 按 P0-2/3/4 补完调色台、主页、设置页。
4. 编译：
   ```bash
   xcodebuild -project SpektraMobileApp/SpektraMobile.xcodeproj \
     -scheme SpektraMobile -configuration Debug \
     -destination 'generic/platform=iOS Simulator' build
   ```
5. 编译通过后交给用户自测；未签名 ipa 由用户自行重签安装。
6. 收尾时清理 `syncDrawerToContent` 的无效状态写入。

---

## 九、已知坑

- **`project.yml` 不会自动同步**：机器无 xcodegen，必须同时手改 `project.pbxproj`，否则改了 yml 等于没改。
- **安全区只在窗口尺寸变化时刷新**：`MScreenMetrics.current()` 读的是 key window；分屏拖拽时尺寸变化密集，preference 已做 1pt 阈值去抖，但若发现安全区滞后，优先怀疑 window 还没完成布局而不是公式。
- **分栏里不要给 `drawer` 再套固定高度**：它内部 `ZStack` 已是 `maxHeight: .infinity`，外层 `VStack` 会自然分配剩余空间。
- **`syncDrawerToContent` 会改 `drawerHeight`**：分栏不使用它，但状态仍会变，可能引发多余重绘（P1-5 清理）。
- **iPad 上 `MHousingAura`**：`resolved()` 现在返回 `.none`，`MHousingAura` 对 `.none` 是否仍绘制需在实机上确认；若仍看到顶部细光，检查 `MHousingAura` 内部对 `.none` 的处理。
- **相机代码仍在**：`CameraScreen` 未删除，仅入口不可达；不要把 `NSCameraUsageDescription` 删掉，否则改回来会崩。
- **当前 4 个文件未提交**：若用户在别的机器继续开发，先确认这份工作树的改动还在。
