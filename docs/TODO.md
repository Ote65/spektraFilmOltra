# 待做：调色台裁切 / 校正（功能失效 + 预览卡顿）

> 记录于 2026-11-11，基于提交 `1e9be9e`。此处只记录问题与代码位置，暂不做优化。
> 用户实测结论：拖动一下走一帧、绝大部分功能失效、透视纠正完全无效、预览延迟极高。

## 现象归因（一句话）

`onChange(of: draft)` 每动一格就整幅重采样，而每次重采样又在**每个采样点**里重新构造并求逆单应矩阵；
串行队列不取消旧任务，只丢弃旧结果 → 越拖越卡，看起来所有旋钮都失灵。

---

## P0-1 每动一次刻度就整幅重渲染

- `SpektraMobile/Sources/Screens/MCropEditor.swift:74-75`
  `onChange(of: draft) { _, value in preview.render(value) }` —— 只要 draft 变（含每一格刻度）就调用重采样。
- `SpektraMobile/Sources/Screens/MCropEditor.swift:174`
  `MTickRuler(range:step:value:haptics:)` —— 刻度尺每个 tick 都会 commit 一个新 value，没有合并/节流。
- `SpektraMobile/Sources/Screens/MCropEditor.swift:214`
  透视的两条刻度尺同理（垂直 / 水平各一条）。
- `SpektraMobile/Sources/Screens/MCropEditor.swift:653-666`
  `MCropPreviewRenderer.render` 只用 `target != last` 去重；**不做节流**，也没有取消机制，
  旧任务会在串行队列里排队跑完，`token` 只决定“显示哪一帧”，不决定“算哪一帧”。

结果：拖动时长越长、落后越多，表现为“拖动无反应 → 忽然跳一下”。

## P0-2 采样内层循环里重复构造 + 求逆单应矩阵（最致命）

调用链：

1. `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:215-219`（`apply(to: ImageRGB)`，导出/主预览）
2. `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:308-316`（`apply(buffer:)`，裁切页 RGBA8 预览）
3. → `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:110-114` `sourcePoint(outputX:outputY:...)`
4. → `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:132-139` `inverseWarp(...)`
5. → `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:137-138` 每呼叫一次就 `warpQuad` + `unitSquareToQuad` + `.inverted`

关键问题：第 1/2 处的 `sourcePoint(...)` 位于 `for sy in 0..<grid { for sx in 0..<grid { ... } }` 的最内层，
即 **每个输出像素 × 每个超采样点都做一次单应矩阵构造 + 3×3 求逆**。
`grid` 由 `sampleGrid` 决定，最多 3×3（`:183-188`）。

量级：1200 长边预览 ≈ 120 万像素 × 4（2×2）≈ 500 万次求逆/帧；导出整幅更大。
这份计算本应“每帧一次”，现在是“每采样点一次”。

## P0-3 透视纠正完全无效（几何自抵消）

- `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:142-179` `warpQuad`
- `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:171`
  `perspScale = 1 / max(0.05, min(top, bottom, left, right))`
- `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:173-178` 以中心放大整块四边形

原因：`perspScale` 恰好把**最窄的那条边放大回 1.0**（贴满画幅），最宽的边被推到画外；
于是输出的采样点大量落到源图 `[0,1]` 之外，被
`SpektraMobile/Sources/Engine/MPhotoGeometry.swift:343-344`（以及 `:245-246`）的 `min(max(...))` clamp 成边缘像素。
视觉上就是“拉满只有边缘拖影/拉伸”，而不是把梯形拉直 —— 即“透视失效”。

已核对 UI 绑定本身没问题：
- `SpektraMobile/Sources/Screens/MCropEditor.swift:198-199` 绑定 `draft.perspectiveV / perspectiveH`
- `SpektraMobile/Sources/Screens/MCropEditor.swift:204-217` `range: -100...100, step: 1`
所以问题在几何，不在滑杆。

- 另需注意 `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:150-155` 的四边形构造：
  `top/bottom` 只改 x 宽度、`left/right` 只改 y 高度，且四条边仍落在画幅边界上，
  没有“向内收”的梯形概念，天然无法真正拉直透视。

## P1 次生问题

- `SpektraMobile/Sources/Engine/MPhotoGeometry.swift:169-170`
  `rotScale = max(cos + (h/w)|sin|, cos + (w/h)|sin|)`：非方形图在 45° 时放大到 1.65 倍（4:3），
  水平纠正时能明显看到“越拉越放大”。
- `SpektraMobile/Sources/Screens/MCropEditor.swift:635-666`
  串行队列没有 `DispatchWorkItem.cancel()` / 代际中断，只能丢弃结果，无法停止浪费的算力。
- `SpektraMobile/Sources/Screens/MCropEditor.swift:639`
  `maxEdge = 1200`：透视/水平拉满时预览分辨率不足，边缘锯齿与插值痕迹明显。
- `SpektraMobile/Sources/Engine/MobileGradeSession.swift:187-233`（`:210` `target.apply(to: pristine)`）
  点“完成”时在后台对整幅交接图做一次全量 `apply`，大图 1–3 秒；期间主预览仍是旧图，容易被当成“没生效”。
- `SpektraMobile/Sources/Engine/MobileGradeSession.swift:168-181` `prepareCropBase()`
  失败时不回写状态；`SpektraMobile/Sources/Screens/GradeScreen.swift:176-196` 的 sheet 会永久停在 ProgressView，只能下滑关闭。

## 未单独验证、需真机复测

- 比例（原始/自由/正方形/4:3/3:2/16:9/9:16）切换后的取景框换算 —— `MCropEditor.swift:125-153`、`apply(ratio:)`
- 水平/垂直镜像方向 —— `MPhotoGeometry.swift:117-130`，`MCropEditor.swift:219-236`
- 90° 旋转后裁切框与比例是否一致 —— `MPhotoGeometry.swift` 的 `rotatedClockwise()`、`MCropEditor.swift` 的 `rotateClockwise()`
- 完成后片边是否只包住裁切后的照片（几何在前、片边在后）—— `MobileGradeSession.swift:187-233` 与导出段

## 验收口径（修完后）

1. 拖动任一滑杆：预览跟手 ≤100ms，松手 1 帧内收敛，CPU 占用不随拖动时长增长。
2. 透视 ±100 能把明显梯形拉直，四角不出黑边、拖影、拉伸。
3. 水平纠正 ±45° 的自动放大克制，不出现明显变焦。
4. 旋转 / 镜像 / 比例 / 裁切框拖动互不干扰；完成后调色台预览与导出结果一致。
5. 片边仍只作用于裁切后的照片。
