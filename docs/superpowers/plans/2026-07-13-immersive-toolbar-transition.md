# Immersive Toolbar Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让主窗口顶部工具栏内容在打开沉浸歌词时同步向上淡出，并在关闭时以相反方向恢复。

**Architecture:** 保留 `ContentView` 现有的沉浸层滑动和延迟折叠 `NSToolbar` 逻辑，新增独立状态来驱动工具栏内容过渡。经典和 macOS 26 工具栏复用同一个 `ViewModifier`；关闭时先恢复原生工具栏，再在下一次主线程更新中播放内容入场动画。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Bash 定向回归检查、Xcode 16

---

## 文件结构

- 新建 `Scripts/test-immersive-toolbar-transition.sh`：约束工具栏过渡的动画参数、应用范围及开关时序。
- 修改 `Views/Main/ContentView.swift`：增加工具栏内容过渡修饰器和独立状态，并把过渡应用到经典与新版工具栏的可见控件。

### Task 1: 添加失败的工具栏过渡回归检查

**Files:**
- Create: `Scripts/test-immersive-toolbar-transition.sh`
- Test: `Scripts/test-immersive-toolbar-transition.sh`

- [ ] **Step 1: 写入定向检查**

```bash
#!/usr/bin/env bash
set -euo pipefail

source_file="Views/Main/ContentView.swift"

if ! rg -n '@State private var isImmersiveToolbarContentHidden = false' "$source_file" >/dev/null; then
    printf 'ContentView must track immersive toolbar content visibility independently.\n' >&2
    exit 1
fi

if ! rg -nU '(?s)private struct ImmersiveToolbarTransition: ViewModifier.*?\.offset\(y: isHidden \? -64 : 0\).*?\.opacity\(isHidden \? 0 : 1\).*?\.allowsHitTesting\(!isHidden\).*?\.animation\([[:space:]]*\.easeInOut\(duration: AnimationDuration\.immersiveTransition\),[[:space:]]*value: isHidden[[:space:]]*\)' "$source_file" >/dev/null; then
    printf 'Immersive toolbar content must move upward, fade, disable hit testing, and use the immersive duration.\n' >&2
    exit 1
fi

transition_count="$(rg -c '^[[:space:]]*\.immersiveToolbarTransition\(isHidden: isImmersiveToolbarContentHidden\)$' "$source_file" || true)"
if [[ "$transition_count" -ne 5 ]]; then
    printf 'Expected immersive toolbar transition on all 5 visible classic and modern toolbar groups; found %s.\n' "$transition_count" >&2
    exit 1
fi

if ! rg -nU '(?s)private func openImmersive\(\).*?withAnimation.*?isImmersiveToolbarContentHidden = true.*?isImmersiveActive = true' "$source_file" >/dev/null; then
    printf 'Opening immersive mode must hide toolbar content in the same animation transaction.\n' >&2
    exit 1
fi

if ! rg -nU '(?s)private func restoreToolbarForImmersiveClose\(\).*?toolbar\?\.isVisible = immersiveToolbarWasVisible.*?DispatchQueue\.main\.async.*?withAnimation.*?isImmersiveToolbarContentHidden = false' "$source_file" >/dev/null; then
    printf 'Closing immersive mode must restore the native toolbar before animating its content back in.\n' >&2
    exit 1
fi

printf 'Immersive toolbar transition checks passed\n'
```

- [ ] **Step 2: 赋予脚本执行权限**

Run: `chmod +x Scripts/test-immersive-toolbar-transition.sh`

Expected: 命令无输出，脚本具有可执行权限。

- [ ] **Step 3: 运行检查并确认按预期失败**

Run: `Scripts/test-immersive-toolbar-transition.sh`

Expected: FAIL，首个错误为 `ContentView must track immersive toolbar content visibility independently.`。

- [ ] **Step 4: 提交失败检查**

```bash
git add Scripts/test-immersive-toolbar-transition.sh
git commit -m "test: 覆盖沉浸工具栏过渡"
```

### Task 2: 实现对称的工具栏内容过渡

**Files:**
- Modify: `Views/Main/ContentView.swift:38-230`
- Modify: `Views/Main/ContentView.swift:345-409`
- Test: `Scripts/test-immersive-toolbar-transition.sh`

- [ ] **Step 1: 在 `ContentView` 前增加复用修饰器**

在 `mainWindowPanelStateKey` 后、`ContentView` 前加入：

```swift
private struct ImmersiveToolbarTransition: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: isHidden ? -64 : 0)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .animation(
                .easeInOut(duration: AnimationDuration.immersiveTransition),
                value: isHidden
            )
    }
}

private extension View {
    func immersiveToolbarTransition(isHidden: Bool) -> some View {
        modifier(ImmersiveToolbarTransition(isHidden: isHidden))
    }
}
```

- [ ] **Step 2: 增加独立的工具栏内容状态**

把沉浸状态声明更新为：

```swift
    @State private var isImmersiveActive = false
    @State private var isImmersiveToolbarContentHidden = false
    // Toolbar state captured before immersive hides it, so closing restores it.
    @State private var immersiveToolbarWasVisible = true
```

- [ ] **Step 3: 在打开和关闭流程中驱动工具栏内容状态**

把关闭监听替换为：

```swift
        .onChange(of: isImmersiveActive) { _, active in
            if !active {
                restoreToolbarForImmersiveClose()
            }
        }
```

把 `openImmersive()` 替换并在其后增加恢复方法：

```swift
    /// Opens immersive mode, animating toolbar content out before the native
    /// toolbar is collapsed so the main content does not visibly reflow.
    private func openImmersive() {
        immersiveToolbarWasVisible = WindowManager.shared.mainWindow?.toolbar?.isVisible ?? true
        withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
            isImmersiveToolbarContentHidden = true
            isImmersiveActive = true
        } completion: {
            // Guard against a quick re-close before the open animation completes.
            if isImmersiveActive {
                WindowManager.shared.mainWindow?.toolbar?.isVisible = false
            }
        }
    }

    /// Restores the native toolbar first, then gives its SwiftUI content one frame
    /// in the hidden position before animating it back down.
    private func restoreToolbarForImmersiveClose() {
        WindowManager.shared.mainWindow?.toolbar?.isVisible = immersiveToolbarWasVisible
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
                isImmersiveToolbarContentHidden = false
            }
        }
    }
```

- [ ] **Step 4: 把过渡应用到经典工具栏的两个可见组**

经典 Tab 的修饰器链应为：

```swift
            .id(localizationSettings.appLanguage.rawValue)
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
```

经典工具栏右侧 `HStack` 的结尾应为：

```swift
            }
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
```

- [ ] **Step 5: 把过渡应用到 macOS 26 工具栏的三个可见组**

新版 Tab 的修饰器链应为：

```swift
            .id(localizationSettings.appLanguage.rawValue)
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
```

新版通知按钮的修饰器链应为：

```swift
            NotificationTray()
                .frame(width: 34, height: 30)
                .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
```

新版搜索框的修饰器链结尾应为：

```swift
            .frame(width: 280)
            .disabled(!libraryManager.shouldShowMainUI)
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
```

- [ ] **Step 6: 运行定向检查并确认通过**

Run: `Scripts/test-immersive-toolbar-transition.sh`

Expected: PASS，输出 `Immersive toolbar transition checks passed`。

- [ ] **Step 7: 提交实现**

```bash
git add Views/Main/ContentView.swift
git commit -m "fix: 对称显示沉浸模式工具栏动画"
```

### Task 3: 完整验证

**Files:**
- Verify: `Scripts/test-*.sh`
- Verify: `Petrichor.xcodeproj`

- [ ] **Step 1: 运行全部 shell 检查**

Run:

```bash
for script in Scripts/test-*.sh; do
  "$script"
done
```

Expected: 所有脚本退出码为 0，包括 `Immersive toolbar transition checks passed`。

- [ ] **Step 2: 运行 Debug 构建**

Run: `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build`

Expected: 退出码为 0，末尾包含 `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 检查最终差异与工作区状态**

Run:

```bash
git diff --check
git status --short
git log -3 --oneline
```

Expected: `git diff --check` 无输出；工作区无未提交改动；最近三个提交依次包含实现、回归检查和实施计划。
