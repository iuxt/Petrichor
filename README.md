[English](README_EN.md)
 
## 概览
 
### ✨ 功能特性
 
- 你期望的离线音乐播放器该有的，这里都有！
- 支持丰富的音频文件格式：
  - MP3、AAC/M4A、WAV、AIFF、AIF、ALAC
  - Ogg Vorbis、Speex、Opus 以及 FLAC
  - APE（Monkey's Audio）
  - MPC（Musepack）
  - TTA（True Audio）
  - WV（WavPack）
  - DSF/DFF（Direct Stream Digital）
  - ……还有 MOD、IT、S3M、XM 和 AU
- 映射你的音乐文件夹，以结构化视图浏览资料库。
- 显示本地 TTML、KSC、LRC、SRT 及内嵌歌词；逐字歌词支持实时高亮，TTML 对唱歌词按演唱者左右排列。
- 创建、导入或导出播放列表。
- 通过拖拽交互式地管理播放队列。
- 需要时可用文件夹视图浏览音乐。
- 把几乎任何内容固定到侧边栏，快速访问你喜欢的音乐。
- 导航方便：右键点击曲目可直接跳转到对应的专辑、艺人、年份等。
- 原生 macOS 集成，支持菜单栏和程序坞播放控制，并支持深色模式。
- 能够很好地处理包含数千首歌曲的大型资料库。
 
💡 **提示**：Petrichor 的所有功能都非常依赖曲目拥有良好的元数据。
 
###  系统要求
 
- macOS 14 或更高版本
 
### ⚠️ 首次运行
 
如果你从 App Store 以外的渠道下载了发行版，且 macOS 以"来自身份不明的开发者"的提示阻止运行，
可以移除隔离属性：
 
```bash
sudo xattr -r -d com.apple.quarantine /Applications/Petrichor.app
```
 
### 🔒 隐私与数据访问
 
- Petrichor 运行在沙盒中，并经 Apple 公证。
- 它使用以下 macOS 权限：
  - **读写访问**
    - 用于读写用户选择的文件和文件夹，
      包括导出 M3U 播放列表，以及在歌曲属性中明确保存标签修改。
- 它不会（也永远不会）收集任何关于你使用方式的分析数据。
- 只有在你明确保存歌曲属性时才会修改音频标签；不会自动整理文件夹结构。
- 资料库保存在本地。“歌曲属性 → 在线获取标签”可按需选择网易云音乐或 QQ 音乐搜索：只有点击“搜索”才会发送填写的标题和艺术家，不上传音频文件。结果会标明来源；选中结果后可勾选要填入的字段，返回属性窗口点击“保存”才写入文件。此功能适用于单首可写入歌曲。
- “在线搜索歌词”可选择网易云音乐、QQ 音乐或 [AMLL TTML 歌词库](https://github.com/amll-dev/amll-ttml-db)，默认选择 AMLL。搜索只请求所选来源，结果会标明来源；不会上传音频。AMLL 歌词保存为同名 `.ttml`，两个音乐平台的歌词保存为 UTF-8 `.lrc`，替换同格式文件前会确认。
- “设置 → 通用 → 歌词下载”中的自动下载默认关闭，来源默认 AMLL。开启后，仅为当前播放且没有本地或内嵌歌词的歌曲搜索所选来源；AMLL 需要标题、艺人和专辑完全匹配，音乐平台还会核对时长。不会自动覆盖已有歌词，也不会修改音频文件。

### 🎵 TTML 歌词

把 `歌曲名.ttml` 放在音频文件旁边即可离线使用。例如 `Song.flac` 对应 `Song.ttml`。同名旁车歌词按 **TTML → KSC → LRC → SRT** 的顺序读取；文件无效时继续尝试下一种格式，最后回退到内嵌歌词。TTML 的逐字时间用于实时高亮，`ttm:agent` 标记的两位演唱者分别靠左和靠右；独唱及合唱行保持居中。

在线歌词的 TTML 来源是 [AMLL TTML DataBase Git 仓库](https://github.com/amll-dev/amll-ttml-db.git)，通过其 [官方 API](https://amll.dev/reference/http-api/native) 搜索和获取。手动搜索及自动下载都只请求所选来源；QQ 音乐和网易云音乐的歌词保留为 LRC。自动下载只在用户开启开关、播放缺少歌词的歌曲且匹配可靠时运行。

从Apple Music提取ttml歌词：

```bash
python3 Scripts/export-apple-music-ttml.py list
python3 Scripts/export-apple-music-ttml.py save 歌曲ID --output ~/Downloads/歌名.ttml
```

#### 设计思路

- **统一显示模型**：各种格式都转换为“歌词行 + 逐字时间片”，让主窗口、迷你播放器、沉浸模式和桌面歌词共用高亮逻辑。
- **保留原始格式**：AMLL 歌词按原样保存为同名 `.ttml`，音乐平台歌词保存为同名 UTF-8 `.lrc`。歌词文件与音频标签分开，用户可以自行替换或移走。
- **控制联网与写入**：手动搜索由用户触发；自动下载默认关闭，只处理正在播放且缺少歌词的歌曲。自动下载不覆盖已有歌词，手动替换同格式文件需要确认，不上传或改写音频。

“包含歌词翻译”仅影响 LRC，TTML 按原样保存；目前 TTML 的翻译、音译和歌手样式信息尚未在界面显示。
 
## 🏗️ 开发
 
### 动机
 
我多年来收藏了大量音乐文件，却一直怀念 macOS 上有一款好用的离线音乐播放器。我试过几款免费和付费的方案，
但都缺少流媒体应用里常见的那种简洁与功能，于是我开发了 Petrichor 来满足这个需求。

### 实现概览
 
- 使用 Swift 和 SwiftUI 构建，部分采用 AppKit 以获得最佳的 macOS 集成。
- 添加包含音乐文件的文件夹后，应用会扫描这些文件夹、提取所需元数据，并填充到 SQLite 数据库中。
- 应用默认只读取添加的目录；只有在你明确保存歌曲属性时才会修改音频标签，歌词另存为旁车文件。
- 曲目搜索由 [SQLite FTS5](https://www.sqlite.org/fts5.html) 处理。
- 播放由 [AVFoundation](https://developer.apple.com/av-foundation/) 和第三方音频解码器处理。
 
 
### 鸣谢
 
Petrichor 的诞生离不开以下开源项目！
 
- [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)
- [GRDB.swift](https://github.com/groue/GRDB.swift/)
 
### 开发环境
 
- 确保你运行的是 macOS 14 或更高版本。
- 安装 [Xcode](https://developer.apple.com/xcode/)。
- 克隆仓库并打开 `Petrichor.xcodeproj`。
 
#### 构建与发布
 
你可以无需 Apple 签名凭证，构建一个未签名的本地 `.dmg` 安装包：
 
```bash
Scripts/build-installer.sh --local
```
 
默认情况下，本地构建面向当前 Mac 的架构。如需指定安装包架构，可添加 `--universal`、`--arm-only` 或 `--intel-only`。
 
对于发布构建，你可以使用 [`build-installer.sh`](Scripts/build-installer.sh) 脚本进行签名和公证。
发布公证需要付费的 Apple 开发者账号；若只想签名而不公证，可使用 `--bypass-notary`。使用该脚本前，
请确保除 Xcode 外还安装了以下工具：
 
- [xcpretty](https://github.com/xcpretty/xcpretty)
- [create-dmg](https://github.com/create-dmg/create-dmg)
 
推送 tag 时，GitHub Actions 也会自动发布一个未签名的发行版。tag 名称会传递给
`Scripts/build-installer.sh --version`，用作打包的应用版本号。此 CI 发布流程不需要
Apple 签名证书或仓库密钥。
 
发布一个发行版：
 
```bash
git tag 1.2.3
git push origin 1.2.3
```
