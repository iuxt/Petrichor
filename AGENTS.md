# AGENTS.md

面向在本仓库中工作的 AI 编码代理的说明。

## 项目概览

Petrichor 是一个原生 macOS 离线音乐播放器，使用 Swift、SwiftUI 和 AppKit 构建。它会扫描用户选择的音乐文件夹，读取音频元数据，通过 GRDB 将资料库数据存入 SQLite，并通过 AVFoundation 及第三方解码后端播放音频。

应用运行在沙盒中，除明确的用户可见操作外，不应修改用户的音频文件或文件夹结构。允许的明确行为包括写入播放列表文件，读取用户已有的 `.lrc` / `.srt` 歌词旁车文件，或将文件移到废纸篓。

## 仓库结构

- `PetrichorApp.swift` - 应用入口和顶层应用装配。
- `Application/` - app delegate、coordinator 和窗口级行为。
- `Views/` - SwiftUI 视图和少量 AppKit 集成视图。
- `Views/Components/` - 可复用 UI 组件。
- `Managers/` - 应用状态和业务编排。
- `Managers/Database/` - GRDB 初始化、迁移和查询模块。
- `Managers/Library/` - 资料库扫描和文件夹操作。
- `Managers/Playlist/` - 队列、智能播放列表、固定项目和文件型播放列表行为。
- `Managers/Automation/` - App Intents 和自动化支持。
- `Models/` - GRDB 实体、值模型和枚举。
- `Core/` - 元数据、播放、歌词、封面、废纸篓处理和搜索等聚焦领域辅助代码。
- `Utilities/` - 全局辅助代码、常量、日志、钥匙串、图像和文件系统工具。
- `Resources/Localizable.xcstrings` - 本地化字符串。
- `Scripts/` - 针对特定行为的 shell 检查。
- `docs/superpowers/specs/` 和 `docs/superpowers/plans/` - 近期变更的设计说明和实现计划。

## 构建和测试命令

使用 Xcode 16 或更高版本，并运行在 macOS 14+。

构建应用：

```sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

运行仓库中的所有 shell 检查：

```sh
for script in Scripts/test-*.sh; do
  "$script"
done
```

运行某个定向 shell 检查：

```sh
Scripts/test-search-ranking.sh
Scripts/test-localization-format-specifiers.sh
```

仅在用户明确要求时创建 release DMG：

```sh
Scripts/build-installer.sh
```

安装包脚本可能需要签名、公证、`create-dmg`，以及 `PETRICHOR_TEAM_ID`、`PETRICHOR_DEVELOPER_ID` 等环境变量。

## 开发指南

- 优先沿用相邻文件中的现有模式，不要轻易引入新的架构。
- SwiftUI 视图文件应专注于 UI 组合；可复用领域逻辑应放到 `Core/` 或相关 manager 中。
- 数据库访问应保持在 `Managers/Database/` 模块内。需要变更 schema 时，在 `DatabaseMigration.swift` 中添加迁移，并同步更新 `DMSetup.swift` 中的新库初始化逻辑。
- 修改搜索查询时要保留 FTS 搜索排序。避免先取 ranked IDs 再重新查询导致 SQLite FTS 排序丢失。
- 面向 UI 的异步状态更新以及 AppKit 窗口/控制器工作应使用 `@MainActor`。
- 资料库扫描、元数据读取、文件 IO 或网络工作不得阻塞主线程。
- 不要写入音频文件。新的文件写入必须是明确的产品行为，并遵守沙盒和 security-scoped URL 模型。
- 修改播放列表时要记住：普通播放列表通过 `.m3u` 文件做文件型存储；不要重新引入基于数据库的普通播放列表曲目变更路径。
- 歌词功能应保持离线：读取用户已有的 `.lrc` / `.srt` 旁车文件和内嵌歌词，不要重新引入在线歌词下载或歌词数据库写入路径。
- 删除或移动曲目/播放列表时，保留现有的废纸篓 fallback 行为，以支持没有本地废纸篓的卷。
- 不要重新引入 Last.fm、在线歌词、在线封面、在线艺人图片等运行时联网音乐服务。新增涉及隐私或联网的集成必须先有明确产品决策并保持 opt-in。

## UI 指南

- 匹配现有 macOS SwiftUI 风格和紧凑的桌面信息密度。
- 只有在 SwiftUI 无法提供所需 macOS 行为时才使用 AppKit，例如专用窗口、标题栏控制或更底层的事件处理。
- 重复的 UI 模式优先使用 `Views/Components/` 中的可复用组件。
- 面向用户的文本应通过 `Resources/Localizable.xcstrings` 本地化。
- 修改带有重排格式参数的本地化字符串时，使用 positional specifiers，并运行 `Scripts/test-localization-format-specifiers.sh`。

## 验证清单

交付变更前，运行范围最窄但有意义的检查；可行时也运行一次构建。

按领域选择常用检查：

- 搜索变更：`Scripts/test-search-ranking.sh`
- 本地化变更：`Scripts/test-localization-format-specifiers.sh`
- 播放列表文件行为：`Scripts/test-file-backed-playlists-codec.sh` 和 `Scripts/test-file-backed-playlists-integration.sh`
- 废纸篓行为：`Scripts/test-track-trash-sidecars.sh` 和 `Scripts/test-playlist-trash-fallback.sh`
- 歌词行为：`Scripts/test-desktop-lyrics-line-selection.sh`
- 封面行为：`Scripts/test-external-artwork-priority.sh` 和 `Scripts/test-artwork-resolver-priority.sh`
- 功能移除回归：`Scripts/test-favorites-updates-removed.sh`、`Scripts/test-artist-info-download-removed.sh` 和 `Scripts/test-online-services-removed.sh`

如果当前环境无法运行某项检查，请在最终回复中明确说明，并解释已改用什么方式验证。

## Git 和工作区安全

- 工作区可能包含用户改动。不要回退不是你创建的变更。
- 编辑范围应限制在用户请求相关内容内。
- 除非用户明确要求，否则不要运行 `git reset --hard` 或 `git checkout --` 等破坏性 Git 命令。
- 除非任务需要添加、删除或移动项目文件，否则避免修改生成的 Xcode project 元数据。

## 依赖和外部服务

- GRDB 用于 SQLite 支持的模型和查询。
- 元数据和播放代码包含 AVFoundation、SFB 相关路径和 Crescendo 相关路径。后端专用逻辑应保持在对应的 `Core/Metadata/` 或 `Core/Playback/` 实现中。
- 当前音乐资料、歌词、封面和艺人图片功能应保持离线；不要添加分析、后台数据收集或运行时音乐服务请求。
