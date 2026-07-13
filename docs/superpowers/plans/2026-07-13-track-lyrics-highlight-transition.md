# 歌词高亮即时切换实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让计时歌词切换行时旧行立即取消高亮、新行立即高亮，同时保留自动滚动动画。

**Architecture:** 保持 `TrackLyricsContent` 现有状态和歌词时间轴选择逻辑不变，只收窄 SwiftUI 动画事务的作用范围。`currentLineIndex` 与行样式同步、无动画地更新，`ScrollViewReader` 监听索引变化后单独对 `scrollTo` 应用动画。

**Tech Stack:** Swift 6、SwiftUI、Bash、ripgrep、Xcode 16

---

## 文件结构

- 新建 `Scripts/test-track-lyrics-highlight-transition.sh`：对高亮切换与滚动动画的边界做定向回归检查。
- 修改 `Views/Main/TrackLyricsView.swift`：移除行样式和当前行索引更新上的弹簧动画，保留滚动动画。

### Task 1: 添加高亮动画边界回归检查

**Files:**
- Create: `Scripts/test-track-lyrics-highlight-transition.sh`
- Test: `Scripts/test-track-lyrics-highlight-transition.sh`

- [ ] **Step 1: 写入失败检查**

```bash
#!/usr/bin/env bash
set -euo pipefail

source_file="Views/Main/TrackLyricsView.swift"

if rg -n '\.animation\(.*value: currentLineIndex\)' "$source_file" >/dev/null; then
    printf 'Lyric highlight styles must switch immediately instead of animating with currentLineIndex.\n' >&2
    exit 1
fi

if rg -nU '(?s)private func updateCurrentLine\(for time: TimeInterval\).*?withAnimation.*?currentLineIndex = newIndex' "$source_file" >/dev/null; then
    printf 'The current lyric index must update outside an animation transaction.\n' >&2
    exit 1
fi

if ! rg -n '^[[:space:]]*currentLineIndex = newIndex$' "$source_file" >/dev/null; then
    printf 'The current lyric index update is missing.\n' >&2
    exit 1
fi

if ! rg -nU '(?s)\.onChange\(of: currentLineIndex\).*?withAnimation[[:space:]]*\{.*?proxy\.scrollTo\(newIndex, anchor: \.center\)' "$source_file" >/dev/null; then
    printf 'Lyric auto-scrolling must remain animated.\n' >&2
    exit 1
fi

printf 'Track lyrics highlight transition checks passed\n'
```

- [ ] **Step 2: 赋予脚本执行权限**

Run: `chmod +x Scripts/test-track-lyrics-highlight-transition.sh`

Expected: 命令退出码为 0，脚本成为可执行文件。

- [ ] **Step 3: 运行检查并确认红灯**

Run: `Scripts/test-track-lyrics-highlight-transition.sh`

Expected: FAIL，输出 `Lyric highlight styles must switch immediately instead of animating with currentLineIndex.`，证明检查能捕获现有残留高亮行为。

### Task 2: 收窄 SwiftUI 动画事务

**Files:**
- Modify: `Views/Main/TrackLyricsView.swift:139-160`
- Modify: `Views/Main/TrackLyricsView.swift:236-240`
- Test: `Scripts/test-track-lyrics-highlight-transition.sh`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: 移除歌词行样式动画**

把歌词行修饰符末尾从：

```swift
.id(index)   // For scrollTo
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentLineIndex)
```

改为：

```swift
.id(index)   // For scrollTo
```

- [ ] **Step 2: 让当前行索引直接更新**

把：

```swift
if newIndex != currentLineIndex {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        currentLineIndex = newIndex
    }
}
```

改为：

```swift
if newIndex != currentLineIndex {
    currentLineIndex = newIndex
}
```

不要修改 `onChange(of: currentLineIndex)` 中包裹 `proxy.scrollTo` 的 `withAnimation`。

- [ ] **Step 3: 运行高亮边界检查并确认绿灯**

Run: `Scripts/test-track-lyrics-highlight-transition.sh`

Expected: PASS，输出 `Track lyrics highlight transition checks passed`。

- [ ] **Step 4: 运行歌词行选择检查**

Run: `Scripts/test-desktop-lyrics-line-selection.sh`

Expected: PASS，输出 `Desktop lyrics line selection tests passed`。

- [ ] **Step 5: 检查差异并提交测试与修复**

Run: `git diff --check && git diff -- Scripts/test-track-lyrics-highlight-transition.sh Views/Main/TrackLyricsView.swift`

Expected: `git diff --check` 无输出；差异只包含新增定向检查、移除两处高亮相关动画。

```bash
git add Scripts/test-track-lyrics-highlight-transition.sh Views/Main/TrackLyricsView.swift
git commit -m "fix(lyrics): 立即切换当前行高亮"
```

### Task 3: 完整验证

**Files:**
- Verify: `Scripts/test-*.sh`
- Verify: `Petrichor.xcodeproj`

- [ ] **Step 1: 运行全部 shell 检查**

Run: `for script in Scripts/test-*.sh; do "$script"; done`

Expected: 所有脚本退出码均为 0；没有 `FAIL` 或错误输出。

- [ ] **Step 2: 构建 Debug 应用**

Run: `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build`

Expected: 退出码为 0，输出以 `** BUILD SUCCEEDED **` 结束。

- [ ] **Step 3: 核对最终工作区和提交**

Run: `git status --short && git log -2 --oneline`

Expected: 工作区无未提交更改；最新提交为 `fix(lyrics): 立即切换当前行高亮`，其前为本实施计划提交。
