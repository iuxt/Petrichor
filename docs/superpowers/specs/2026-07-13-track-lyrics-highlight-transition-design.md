# 歌词高亮即时切换设计

## 背景

主界面右侧歌词面板由 `TrackLyricsContent` 渲染。迷你播放器和沉浸模式也复用该组件。

当前实现把 `currentLineIndex` 的更新放在弹簧动画事务中，并在每一行上再次绑定以 `currentLineIndex` 为值的弹簧动画。因此切换到下一行时，上一行的字重、前景色和缩放会在约 0.3 秒内逐渐退回非高亮状态，造成上一行短暂保留黑色加粗的视觉残影。

## 目标行为

- 任一时刻只有当前歌词行采用高亮字重、颜色和缩放。
- `currentLineIndex` 改变时，新旧行的高亮样式在同一次视图更新中立即互斥切换。
- 自动将当前行滚动到面板中央的过程继续保持平滑动画。
- 未计时歌词、歌词加载和当前行选择逻辑保持不变。

## 方案

采用最小范围修复：

1. 更新 `currentLineIndex` 时直接赋值，不把状态更新包装在 `withAnimation` 中。
2. 移除每个歌词行上以 `currentLineIndex` 为值的 `.animation` 修饰符，使字重、颜色和缩放立即反映新状态。
3. 保留 `onChange(of: currentLineIndex)` 中包裹 `proxy.scrollTo` 的 `withAnimation`，只对滚动位置变化应用动画。

没有选择“仅让字重立即切换”的方案，因为它需要把同一行的样式拆分到不同动画事务中，同时颜色或缩放的渐退仍可能被看成高亮残留。也不在整行上全局禁用动画，以免无意中限制该视图未来的其他局部动画。

## 修改范围

- 修改 `Views/Main/TrackLyricsView.swift` 中 `TrackLyricsContent` 的高亮和索引更新动画边界。
- 新增一个定向 shell 回归检查，约束高亮样式不能再次绑定到 `currentLineIndex` 动画，同时确认自动滚动仍位于动画事务中。
- 不修改歌词解析、时间轴选择、数据库、文件系统或本地化资源。

## 验证

1. 先运行新增的定向检查，确认它在现有实现上因行样式和索引更新仍带动画而失败。
2. 应用最小修复后重新运行定向检查，确认通过。
3. 运行 `Scripts/test-desktop-lyrics-line-selection.sh`，确认歌词行选择行为不变。
4. 运行仓库全部 `Scripts/test-*.sh` 检查。
5. 使用 Debug 配置构建 `Petrichor`，确认 SwiftUI 修改可编译。
