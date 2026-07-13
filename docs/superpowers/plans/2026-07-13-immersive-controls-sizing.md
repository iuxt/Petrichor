# Immersive Controls Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将全屏沉浸播放界面的整排播放控件和进度控件按当前尺寸放大约 30%，同时保持其他播放界面不变。

**Architecture:** 保留共享的 `NowPlayingControlsView` 和 `NowPlayingProgressBar`，只在 `ImmersiveLayout` 中把传给它们的缩放值乘以 1.3。新增 shell 定向检查约束缩放公式和两个沉浸调用点，避免共享组件或其他播放界面被误改。

**Tech Stack:** Swift 6、SwiftUI、Bash、ripgrep、Xcode 16

## Global Constraints

- 只放大全屏沉浸界面的播放控件。
- 随机播放、上一首、播放/暂停、下一首、循环播放、进度轨、拖动圆点、时间文字和相关点击区域统一放大约 30%。
- 进度条整体宽度继续与封面宽度一致。
- 迷你播放器和主窗口播放栏的尺寸与行为保持不变。
- 不修改播放逻辑、本地化资源、共享播放控件默认值或 Xcode 工程元数据。

---

## 文件结构

- 新建 `Scripts/test-immersive-controls-sizing.sh`：静态检查沉浸缩放公式和共享缩放值的两个调用点。
- 修改 `Views/Immersive/ImmersiveView.swift`：只调整 `ImmersiveLayout.controlsScale` 的计算。

### Task 1: 添加失败的沉浸控件尺寸回归检查

**Files:**
- Create: `Scripts/test-immersive-controls-sizing.sh`
- Test: `Scripts/test-immersive-controls-sizing.sh`

**Interfaces:**
- Consumes: `Views/Immersive/ImmersiveView.swift` 中的 `ImmersiveLayout.controlsScale` 和 `scale: layout.controlsScale` 调用点。
- Produces: 可执行的定向检查 `Scripts/test-immersive-controls-sizing.sh`。

- [ ] **Step 1: 写入定向检查**

```bash
#!/usr/bin/env bash
set -euo pipefail

source_file="Views/Immersive/ImmersiveView.swift"

if ! rg -n 'var controlsScale: CGFloat \{ min\(scale \* 1\.3, 2\.6\) \}' "$source_file" >/dev/null; then
    printf 'Immersive controls must use a 1.3x scale with a 2.6 maximum.\n' >&2
    exit 1
fi

usage_count="$(rg -c 'scale: layout\.controlsScale' "$source_file" || true)"
if [[ "$usage_count" -ne 2 ]]; then
    printf 'Expected the immersive controls and progress bar to share controlsScale; found %s usages.\n' "$usage_count" >&2
    exit 1
fi

printf 'Immersive controls sizing checks passed\n'
```

- [ ] **Step 2: 赋予脚本执行权限**

Run: `chmod +x Scripts/test-immersive-controls-sizing.sh`

Expected: 命令无输出，脚本具有可执行权限。

- [ ] **Step 3: 运行检查并确认按预期失败**

Run: `Scripts/test-immersive-controls-sizing.sh`

Expected: FAIL，输出 `Immersive controls must use a 1.3x scale with a 2.6 maximum.`。

- [ ] **Step 4: 提交失败检查**

```bash
git add Scripts/test-immersive-controls-sizing.sh
git commit -m "test: 覆盖全屏播放控件尺寸"
```

### Task 2: 将沉浸播放控件放大 30%

**Files:**
- Modify: `Views/Immersive/ImmersiveView.swift:34`
- Test: `Scripts/test-immersive-controls-sizing.sh`

**Interfaces:**
- Consumes: `ImmersiveLayout.scale: CGFloat`。
- Produces: `ImmersiveLayout.controlsScale: CGFloat`，返回 `min(scale * 1.3, 2.6)`，供播放控件和进度条共同使用。

- [ ] **Step 1: 修改沉浸控件缩放公式**

把 `ImmersiveLayout.controlsScale` 修改为：

```swift
var controlsScale: CGFloat { min(scale * 1.3, 2.6) }
```

- [ ] **Step 2: 运行定向检查并确认通过**

Run: `Scripts/test-immersive-controls-sizing.sh`

Expected: PASS，输出 `Immersive controls sizing checks passed`。

- [ ] **Step 3: 检查改动范围**

Run:

```bash
git diff --check
git diff -- Views/Immersive/ImmersiveView.swift
```

Expected: `git diff --check` 无输出；Swift 差异只包含 `controlsScale` 的一行公式调整。Task 1 的定向检查已经提交，因此不应再有未提交的脚本差异。

- [ ] **Step 4: 提交实现**

```bash
git add Views/Immersive/ImmersiveView.swift
git commit -m "fix: 放大全屏播放控件"
```

### Task 3: 完整验证

**Files:**
- Verify: `Scripts/test-*.sh`
- Verify: `Petrichor.xcodeproj`

**Interfaces:**
- Consumes: Task 1 的定向检查和 Task 2 的沉浸缩放实现。
- Produces: 全套 shell 检查及 Debug 构建的验证结果。

- [ ] **Step 1: 运行全部 shell 检查**

Run:

```bash
for script in Scripts/test-*.sh; do
  "$script"
done
```

Expected: 所有脚本退出码为 0，包括输出 `Immersive controls sizing checks passed`。

- [ ] **Step 2: 运行 Debug 构建**

Run: `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build`

Expected: 退出码为 0，末尾包含 `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 检查最终差异与工作区状态**

Run:

```bash
git diff --check
git status --short
git log -5 --oneline
```

Expected: `git diff --check` 无输出；工作区无未提交改动；近期提交依次包含实现、回归检查、实施计划和设计文档。
