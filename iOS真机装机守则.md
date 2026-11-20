# iOS 真机装机守则

> 适用：把 `iOS` 分支构建到连接的 iPhone 真机上，并完成可验证的验收。
> 目标读者：接手这个仓库的 Agent 或开发者。**照抄命令即可，不要凭记忆改参数。**
>
> 最后验证：2026-11-19，0.7.11 (39)，iPhone 13 Pro Max / iOS 26。

---

## 0. 关键常量（不要猜，用这些）

| 项 | 值 |
|---|---|
| 工程 | `SpektraMobileApp/SpektraMobile.xcodeproj` |
| Scheme | `SpektraMobile` |
| Bundle ID | `com.spektrafilm.mobile` |
| Team ID | `HH5C68L63U` |
| 签名身份 | `iPhone Developer`（Apple Development: treesex_aydola@icloud.com） |
| 导出配置 | `build/export-options.plist`（method=development） |
| 目标机 UDID | `00008110-001C20523E04801E`（iPhone 13 Pro Max，有线） |

换机器时用 `xcrun devicectl list devices` 重新取 UDID，**只认 `Reality = physical` 且 `State = connected` 的那一行**；`simulated` 的行是模拟器，装了没意义。

---

## 1. 发版前：版本号两处必须同步

```bash
cd "/Users/megmeet/Documents/开发 APP/SpektrafilmSwift-ios"

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.7.12" \
  -c "Set :CFBundleVersion 40" \
  SpektraMobileApp/Info.plist
```

再改 `SpektraMobileApp/project.yml` 里的 `CFBundleShortVersionString`（xcodegen 的数据源，不改会和下次重新生成冲突）。

> ⚠️ 两个坑：
> 1. macOS 上 `sed -i '' 's/x/y/' 文件` 在含空格的路径里会报 `No such file or directory` ——用 Python 或 PlistBuddy，别用 sed。
> 2. `git add` 会把工作区里别人正在改的版本号一起带走。提交前先 `git diff SpektraMobileApp/` 确认。

---

## 2. 归档（Release / 通用 iOS 设备）

```bash
cd "/Users/megmeet/Documents/开发 APP/SpektrafilmSwift-ios"
rm -rf /tmp/spk-dd /tmp/spk.xcarchive

xcodebuild \
  -project SpektraMobileApp/SpektraMobile.xcodeproj \
  -scheme SpektraMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/spk.xcarchive \
  -derivedDataPath /tmp/spk-dd \
  DEVELOPMENT_TEAM=HH5C68L63U \
  CODE_SIGN_IDENTITY='iPhone Developer' \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  archive
```

**三个参数不能省：**

- `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` —— 本机不加会构建失败。`$(inherited)` 不能漏，否则覆盖掉工程原有 flags。
- `-derivedDataPath` / `-archivePath` 指向 `/tmp` —— 放项目目录里会因 `.swiftpm/security`、`build.db` 写入被拒而失败。
- 命令需要在**不受限的终端**里跑。在受限沙箱中执行时，需要放行整个命令（WorkBuddy 里是 `dangerouslyDisableSandbox`）。

耗时约 1.5–2 分钟。成功标志：`** ARCHIVE SUCCEEDED **`。

---

## 3. 导出 ipa

```bash
rm -rf /tmp/spk-export
xcodebuild -exportArchive \
  -archivePath /tmp/spk.xcarchive \
  -exportPath /tmp/spk-export \
  -exportOptionsPlist build/export-options.plist
```

成功标志：`** EXPORT SUCCEEDED **`，产物 `/tmp/spk-export/SpektraMobile.ipa`（约 17 MB）。

> 日志里 `Command line name "development" is deprecated. Use "debugging" instead.` 是警告，可忽略。

---

## 4. 安装到真机

```bash
rm -rf /tmp/spk-inst && mkdir -p /tmp/spk-inst
cd /tmp/spk-inst && unzip -q /tmp/spk-export/SpektraMobile.ipa -d .

for i in 1 2 3; do
  xcrun devicectl device install app \
    --device 00008110-001C20523E04801E \
    /tmp/spk-inst/Payload/SpektraMobile.app 2>&1 | grep -qE "App installed" \
    && { echo "安装成功"; break; } \
    || { echo "第 $i 次被拒，20s 后重试"; sleep 20; }
done
```

**必须带重试循环。** 设备锁屏或休眠时 `devicectl install` 会报：

```
ERROR: The device is not able to fulfill the requested usage assertion requirements.
       (com.apple.dt.CoreDeviceError error 4016)
       CurrentlyAssertableStates = ( )
```

这不是构建问题、不是签名问题，**就是手机没醒**。等 20 秒重试即可，不要去改任何构建参数。

---

## 5. 启动 + 截屏验收（必做）

```bash
DEV=00008110-001C20523E04801E

xcrun devicectl device process launch --device $DEV --terminate-existing com.spektrafilm.mobile

sleep 10   # 12MP RAW 预览解码需要时间，太早截会是空画布

xcrun devicectl device capture screenshot --device $DEV --destination /tmp/shot.png
```

`devicectl capture screenshot` 自带真机截屏，**不需要装 libimobiledevice / ideviceinstaller**。输出 1284×2778（@3x）。

> ⚠️ 两个会让截图骗人的坑：
> 1. **系统通知横幅**会盖住顶栏，看起来像"按钮消失/被裁切"。截到异常顶栏时先看看是不是横幅，别急着当布局 bug 报。
> 2. **动画中间帧**。页面切换（显影台 → 调色台吸入）期间截图会看到左右两个面板并排的假象。隔 2–4 秒重截一次再判断。

`process launch` 报 `Unable to launch ... device was not, or could not be, unlocked` = 手机锁屏，让用户解锁或稍后重试。

---

## 6. 验收用的启动参数

`launch` 后面的参数用 `--` 隔开再传：

```bash
xcrun devicectl device process launch --device $DEV --terminate-existing \
  com.spektrafilm.mobile -- --screen develop
```

| 参数 | 作用 |
|---|---|
| `--screen home\|camera\|develop\|grade\|settings` | 直达某屏 |
| `--page film\|tone\|color\|detail` | 显影台参数页 |
| `--drawer mid\|max` | 抽屉档位 |
| `--probe-geometry` | 启动时把真实安全区与开孔矩形打到 NSLog |
| `--housing notch\|island\|none` | 强制开孔形态（任意机型复现某分支） |
| `--zoom 2.4` / `--pan-y 80` | 画布初始缩放 / 偏移 |
| `--video-open` / `--export-run` | 视频显影台 / 自动开跑导出 |

读几何日志（不用连 Xcode）：

```bash
xcrun devicectl device process launch --console --terminate-existing \
  --device $DEV com.spektrafilm.mobile -- --probe-geometry 2>&1 \
  | grep MGeometry
# 期望：MGeometry size=428x926 top=47 bottom=34 housing=notch opening={{136, 0}, {156, 32}}
```

---

## 7. 归档产物

```bash
cp /tmp/spk-export/SpektraMobile.ipa \
   "/Users/megmeet/Documents/开发 APP/Spektrafilm/Spektrafilm-<版本>-ios.ipa"

rm -rf /tmp/spk-dd /tmp/spk.xcarchive /tmp/spk-export /tmp/spk-inst
```

ipa 统一放在 **Spektrafilm 工作区根目录**（不是 iOS 源码仓库），命名 `Spektrafilm-<版本>-ios.ipa`。

---

## 8. 常见问题对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `4016` / `CurrentlyAssertableStates = ( )` | 设备锁屏或休眠 | 等 20s 重试；连续失败让用户解锁 |
| `device was not, or could not be, unlocked` | 同上 | 同上 |
| 4016 连续 3 次、且 `list devices` 显示 `unavailable` | **设备已断开**（拔线 / 关机 / 睡到断连），不是锁屏 | 让用户插线并解锁；重试无意义，别空转 |
| 构建报 `.swiftpm/security` 或 `build.db` 写入被拒 | derivedData 放在项目内 | 挪到 `/tmp` |
| `Sandbox: deny file-write` | 受限沙箱 | 放行命令重跑 |
| 装了但桌面看不到 | 首次安装需在「设置 → 通用 → VPN与设备管理」信任开发者证书 | 设备上手动信任一次 |
| 截屏是黑屏或空画布 | 截图早于预览解码 | `sleep 10` 后重截 |
| 截图顶栏缺按钮 | 通知横幅遮挡 / 动画中间帧 | 重截，别当 bug |

---

## 9. 交付前自检

- [ ] 工作区干净（`git status` 无输出），或明确知道哪些改动属于本次
- [ ] `Info.plist` 与 `project.yml` 版本号一致
- [ ] `ARCHIVE SUCCEEDED` + `EXPORT SUCCEEDED`
- [ ] `App installed` 且版本号与源码一致
- [ ] 真机截屏确认目标页面渲染正常、无裁切
- [ ] ipa 已归档到 Spektrafilm 根目录并带版本号
