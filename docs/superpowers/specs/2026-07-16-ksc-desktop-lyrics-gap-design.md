# KSC 桌面歌词句间空态修复设计

## 问题

KSC 每句同时携带开始时间和结束时间。当前桌面歌词选择器只把播放时间落在 `[startTime, endTime)` 内的歌词视为当前句；当上一句已经结束、下一句尚未开始时，选择结果为 `nil`。`DesktopLyricsLineProvider` 随后把该结果发布为 `.empty`，令桌面歌词短暂显示“没有可用歌词”。

LRC 通常把上一句结束时间补齐到下一句开始时间，因此较少出现同样的空态。SRT 的有限时间间隔仍应保留现有语义。

## 目标行为

- 仅对 KSC 启用句间保持行为。
- 在两句 KSC 之间的空隙中，继续显示播放时间之前最近的一句非空歌词。
- 保持上一句的原始 `endTime`，使逐字高亮在句末保持完整完成状态。
- 下一句到达 `startTime` 时正常切换。
- 最后一句结束后继续保留最后一句，直到曲目或歌词状态改变。
- 播放时间跳转后根据目标时间重新计算显示内容，不依赖先前发布的 UI 状态。
- 非 KSC 的同步歌词继续沿用现有有限时间间隔行为。

## 设计

扩展 `DesktopLyricsLineSelection.syncedDisplayLines`，加入显式的句间保持策略。默认策略保持现有行为；KSC provider 调用时选择“保持最近已开始的非空歌词”。

选择顺序如下：

1. 若时间位于某句有效区间，选择该句。
2. 若时间早于第一句，继续显示第一句非空歌词，与现有行为一致。
3. 若没有活动句且启用了 KSC 句间保持，从播放时间之前已开始的歌词中向前寻找最近的非空句。
4. 若仍无可显示歌词，返回 `nil`。
5. `next` 始终取当前句之后的下一条非空歌词。

provider 根据已加载歌词的 `isKaraoke` 标志传入策略。不会修改 KSC 解析结果、原始时间戳或其他歌词视图。

## 错误与边界处理

- 空歌词数组及全空白歌词仍返回 `nil`。
- 空白 KSC 行不会成为保持目标。
- 时间位于第一句之前时不尝试查找“上一句”。
- 时间位于最后一句之后时保持最后一条非空 KSC 歌词。
- 跳转到任意句间空隙时，按目标时间选择正确的上一句，避免保留跳转前的陈旧状态。

## 测试与验证

先在 `Scripts/test-desktop-lyrics-line-selection.sh` 添加失败用例，覆盖：

- 默认同步歌词策略在有限间隔中仍返回 `nil`。
- KSC 句间保持策略在间隔中返回上一句与下一句。
- KSC 最后一句结束后仍保留最后一句。
- provider 在同一 KSC 间隔中保持 `.lyrics`，不会发布 `.empty`。

随后实现最小改动，并运行：

- `Scripts/test-desktop-lyrics-line-selection.sh`
- `Scripts/test-karaoke-timing.sh`
- `Scripts/test-karaoke-lyrics-rendering.sh`
- `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build`
