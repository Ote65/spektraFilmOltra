# 0.4.3 发布交接文档

> 交接时间：2026-11-16
> 工作目录：`/Users/megmeet/Documents/开发 APP/SpektrafilmSwift-ios`（分支 `iOS`）
> HEAD：`0ce549e`（已推送 oltra），tag `v0.4.3-ios`
> 工作树：**clean**（无未提交改动）
> 版本：0.4.3 / build 6（`SpektraMobileApp/Info.plist` + `project.yml` 两处）

---

## 一、当前状态总览

| 项 | 状态 |
|---|---|
| App 版本 | 0.4.3 / build 6，开发签名，**2026-11-20 到期** |
| GitHub Release | https://github.com/Ote65/spektraFilmOltra/releases/tag/v0.4.3-ios（IPA 已上传，16.3MB） |
| 官网 | **Ote65/Ote-Site**（ote.asia + spektra.ote.asia，Cloudflare Workers），iOS 段已更新至 0.4.3 并部署，提交 `37d22e4` |
| 下载线路 | GitHub 直链 / ote.asia/dl relay / gh-proxy 镜像，三条全部 200 验证过 |
| 编译 | archive 全量编译通过（ARCHIVE SUCCEEDED） |
| 验证 | parity 门禁五项全过；iPhone 三屏冒烟通过；**iPad 真机交互未验证**（见缺漏） |

---

## 二、本批完成了哪些

### 1. SpektraCore 性能批次（内存瘦身与分带导出）——已审查、已合并

27 文件 +1072/−273，详见 `docs/parity_report.md` 第 11 节。要点：

- **解码直写 RGB Float**（`ImageLoader`/`RawDecoder`）：跳过 RGBAf→Double→Float 三段临时拷贝，34MP 解码临时缓冲少约 1.3GB。
- **`processTiled` 横向分带显影**（`Runtime/Pipeline.swift` +322）：`haloRows(for:)` 按全流程最大空间核取 3σ（偶联扩散 tail、halation 弹跳、颗粒 blur、USM、lensBlur、glare 取最大）+8 行；`preprocessGeometry` 把 preprocess 拆成全图常量（自动曝光 / 裁切矩形 / 放大倍数），条带采样复用同一坐标公式保证一致。
- **`ExportEdge.plan`**（`MobileDevelopSession.swift`）：按可用内存 72% 出条带计划，不够再二分钳位；柔光镜大核不分带。显影台与调色台共用。
- **逐通道 / 原地计算**：光晕、偶联、USM 逐通道（`FastGaussian`、`SpatialEffects`、`Couplers`），颗粒原地写回（`Grain`），spectralIntegral 直写 Float。
- **内存指标**：12MP 全流程峰值 1.45→1.33GB；34MP 调色 2.56→1.76GB；分带一致性偏差 ≤9.6e-07。
- **对拍门禁**（`Tools/ParityCheck/main.swift`）：五项全过，最大 6.84e-08 ≤ 1e-5。
- 附带完整新功能：设置页「启动默认筛选」（`SettingsScreen.swift` 的 `MLaunchScope`，含关闭「支持 JPEG」时回落全部的逻辑）+ `DebugLaunch.launchScope`（`--launch-scope` 调试参数）。

### 2. iPad 布局修复（本会话完成）

- `MLayout.usesSplit`：小窗 / 接近手机竖屏比例回退 iPhone 单列。判定 = 横屏比例（w>h×1.02）+ 宽≥800 + 高≥640 + **画布（扣左右轨）≥470pt**。`DebugLaunch.windowOverride`（`--window WxH`）调试参数。
- `gridColumns`：iPad 主页网格列数渐进公式 `max(1, min(5, Int((width-28)/190)))`，窗口缩小时列数变少、卡片保持体量；iPhone 恒 2 列。
- `MPhotoCard` 锁比例：`.aspectRatio(165/128, contentMode: .fit)` 替代固定高 128，缩小不再变形。
- 设计取舍已与用户确认：分栏看**画布绝对宽度**（触控面板最小宽度约束），非纯比例——1366×1032 与 1024×768 同为 4:3，前者分栏后者单列。

### 3. 发布流水线（本次全链路打通）

- 版本 bump → archive → exportArchive → GitHub Release（API）→ 官网更新 → 三线路验证，全部走通，命令与坑见第四节。

### 4. Code review（已做，仅文本交付）

对未提交改动用 code-review-report-plugin 审查，4 条 minor 已文本交付，**未修复**（见缺漏 1）。插件发布流程曾被「workspace changed during review」drift 拒绝，按规范转文本。

---

## 三、缺漏哪些（按优先级）

### 必须近期处理

1. **开发签名 2026-11-20 到期**。到期后官网下载的包安装/续签走原流程（Sideloadly 重签或重新 archive 发布 build 7）。官网 `oltraflimRelease.ts` notices ⑥ 已如实标注到期日，**下次发包必须同步改这个日期**。
2. **iPad 真机交互未验证**。用户报过「点不开 / 图片卡跟着缩小 / 点击照片卡住进不了显影台」三个问题：
   - 「图片卡跟着缩小」已由锁比例修复（代码 + 模拟器截图确认）；
   - 「点击卡住」审计结论 = 未入库照片走 `importAsset`（iCloud 取回）期间 `.disabled(busy)` 无超时，**已被前批 `5c3d85d`「修复 RAW 首次解码卡住」覆盖**——但只是代码审计推断，**没有真机点过**；
   - CGEvent 合成点击无法映射进模拟器（已实测放弃），真机验证只能人工做。
3. **code review 4 条 minor 未修**：
   - `ImageLoader` 头注释与实际行为有出入（文案窄化）；
   - `MobileDevelopSession.isRawInput` 与 `LibraryStore.isRaw` 双口径（一处按扩展名、一处按 UTType），建议归一到 `LibraryStore`；
   - 旧版本 UserDefaults 里存的索引在「支持 JPEG」关闭后的归一化路径（旧索引 isRaw）需要确认行为一致。
   - 归一化方案曾提议，用户未拍板。

### 待验证 / 待拍板

4. **调色台裁切 / 校正 P0**（`docs/TODO.md`，2026-11-11 记录）：`MCropEditor` 每格刻度整幅重采样 + 内层循环每像素求逆单应矩阵，结论是「绝大部分功能失效、预览极高延迟」。**修复状态未确认**——若 0.4.2/0.4.3 未覆盖，这是下一个性能批次的最大候选；文末列了 5 条真机验收口径。
5. TODO.md 的裁切真机复测项（比例切换换算、镜像方向、90° 旋转、片边作用范围）无真机记录。
6. `--launch-scope` 设置项与 `--detail-bottom` 等调试参数仅用于截图验收，未做真机回归。

### 无影响但建议清理

7. **Chroma-App 本地误改**：`/Users/megmeet/Documents/开发 APP/Spektrafilm/Chroma-App` 有一个未推送的本地 commit `31f741a`（误把它当官网改了 ios.html 的 fetch 源）。该仓库是 web 版原作者 TareqAmeer 的，与本项目发布无关；本地 commit 可直接丢弃，或留着不管。
8. 打包产物散落：`build/` 下历史 xcarchive 与主仓库根的历史 ipa（0.4.0×5、0.4.1、0.4.2-34mp）未清理。

---

## 四、发布操作手册（含踩坑，下次直接照抄）

### 版本 bump

两处同步改：`SpektraMobileApp/Info.plist`（CFBundleShortVersionString + CFBundleVersion）与 `SpektraMobileApp/project.yml`。

### archive（注意：必须命令行传 team）

```bash
cd "/Users/megmeet/Documents/开发 APP/SpektrafilmSwift-ios"
xcodebuild -project SpektraMobileApp/SpektraMobile.xcodeproj -scheme SpektraMobile \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/Spektrafilm-<版本>.xcarchive \
  DEVELOPMENT_TEAM=HH5C68L63U CODE_SIGN_STYLE=Automatic archive
```

坑：**不传 `DEVELOPMENT_TEAM` 会报 signing 错误**（pbxproj 和 project.yml 里都没有 team，0.4.1 当时是命令行传的）。ExportOptions 复用 `build/export-0.4.1/ExportOptions.plist`（method=debugging、teamID HH5C68L63U）。

### export IPA

```bash
xcodebuild -exportArchive -archivePath build/Spektrafilm-<版本>.xcarchive \
  -exportOptionsPlist build/export-0.4.1/ExportOptions.plist \
  -exportPath build/export-<版本>
cp build/export-<版本>/SpektraMobile.ipa "/Users/megmeet/Documents/开发 APP/Spektrafilm/Spektrafilm-<版本>-ios.ipa"
```

### GitHub Release

无 gh CLI，用 `git credential fill` 取 token 调 API：先 POST `api.github.com/repos/Ote65/spektraFilmOltra/releases`（tag_name `v<版本>-ios`、target_commitish `iOS`），再 POST `uploads.github.com/.../releases/<id>/assets?name=<ipa 名>` 二进制上传。

### 官网（真官网是 Ote-Site，不是 Chroma-App！）

- 仓库：`github.com/Ote65/Ote-Site`（本地无固定 clone，clone 到 /tmp 即可；**github.com 直连会断，git/curl 挂本地代理 `127.0.0.1:12450`**：`git -c http.proxy=http://127.0.0.1:12450 clone ...`）。
- 发布信息全在 `src/oltraflimRelease.ts` 的 `ios` 段：`IOS_TAG`、version/build/date、notices（**改签名到期日**）、whatsNew、downloads.ipa（file/size/sha256/三条链接）。
- SHA-256 用本地 ipa `shasum -a 256` 算，签名到期日用 `security cms -D -i <解包的 embedded.mobileprovision>` 查 ExpirationDate。
- 部署：`npm install && npm run deploy`（= vite build + wrangler deploy，wrangler 已 OAuth 登录 3206219621@qq.com）。部署后 curl 线上 js 搜版本号确认内容生效（wrangler 可能显示「No updated asset files」，以 curl 结果为准）。
- relay 线路 `https://ote.asia/dl/<ipa>` 由 worker.js 动态转发 GitHub，**无需额外配置**，发完 Release 自动可用。
- `Chroma-App`（TareqAmeer/Chroma-App）是 web 版 Chromasmith 原作者仓库，**与本项目官网无关**。

### 网络环境

api.github.com / uploads.github.com 一般直连通；github.com 主站（clone/push）经常断，统一挂代理 12450 最稳。

---

## 五、相关文档索引

| 文档 | 内容 |
|---|---|
| `docs/parity_report.md` §11 | 本批（0.4.3）完整改动表 + 门禁记录 |
| `docs/ipad-handoff.md` | 11-11 iPad 专项交接（当时未编译，现已落地发布） |
| `docs/TODO.md` | 调色台裁切 P0（修复状态待确认）+ 真机复测清单 |
| `docs/PORTING_PLAN.md` / `spec.md` / `tasks.md` | 移植计划与规格 |
