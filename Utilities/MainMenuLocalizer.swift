import AppKit
import Foundation

enum MainMenuLocalizer {
    static func refresh(menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }

        for update in menuTitleUpdates {
            updateMenuTitles(
                in: menu,
                matching: Set(update.candidates),
                to: update.title
            )
        }

        updateAppNamedMenuTitles(in: menu)
    }

    private static var menuTitleUpdates: [(candidates: [String], title: String)] {
        [
            (["File", "文件"], localizedString("File")),
            (["Edit", "编辑"], localizedString("Edit")),
            (["View", "显示", "视图"], localizedString("View")),
            (["Playback", "播放"], localizedString("Playback")),
            (["Window", "窗口"], localizedString("Window")),
            (["Help", "帮助"], localizedString("Help")),
            (["About Petrichor", "关于 Petrichor"], localizedString("About Petrichor")),
            (["Settings", "设置"], localizedString("Settings")),
            (["Services", "服务"], localizedString("Services")),
            (["Hide Petrichor", "隐藏 Petrichor"], localizedString("Hide Petrichor")),
            (["Hide Others", "隐藏其他"], localizedString("Hide Others")),
            (["Show All", "全部显示"], localizedString("Show All")),
            (["Quit Petrichor", "退出 Petrichor"], localizedString("Quit Petrichor")),
            (["Undo", "撤销"], localizedString("Undo")),
            (["Redo", "重做"], localizedString("Redo")),
            (["Cut", "剪切"], localizedString("Cut")),
            (["Copy", "复制"], localizedString("Copy")),
            (["Paste", "粘贴"], localizedString("Paste")),
            (["Select All", "全选"], localizedString("Select All")),
            (["New", "新建"], localizedString("New")),
            (["Library", "资料库"], localizedString("Library")),
            (["Close", "关闭"], localizedString("Close")),
            (["Close Window", "关闭窗口"], localizedString("Close Window")),
            (["Playlist", "播放列表"], localizedString("Playlist")),
            (["Playlist from Selection", "从所选内容创建播放列表"], localizedString("Playlist from Selection")),
            (["Add Folder(s) to Library", "将文件夹添加到资料库"], localizedString("Add Folder(s) to Library")),
            (["Refresh Library Folders", "刷新资料库文件夹"], localizedString("Refresh Library Folders")),
            (["Play/Pause", "播放/暂停"], localizedString("Play/Pause")),
            (["Shuffle", "随机播放"], localizedString("Shuffle")),
            (["Repeat: Off", "重复：关闭"], localizedString("Repeat: Off")),
            (["Repeat: Current Track", "重复：当前歌曲"], localizedString("Repeat: Current Track")),
            (["Repeat: All", "重复：全部"], localizedString("Repeat: All")),
            (["Next", "下一首"], localizedString("Next")),
            (["Previous", "上一首"], localizedString("Previous")),
            (["Seek Forward", "前进"], localizedString("Seek Forward")),
            (["Seek Backward", "后退"], localizedString("Seek Backward")),
            (["Volume Up", "提高音量"], localizedString("Volume Up")),
            (["Volume Down", "降低音量"], localizedString("Volume Down")),
            (["Equalizer", "均衡器"], localizedString("Equalizer")),
            (["Mini Player", "迷你播放器"], localizedString("Mini Player")),
            (["Immersive Mode", "沉浸模式"], localizedString("Immersive Mode")),
            (["Keep Mini Player always on top", "迷你播放器始终置顶"], localizedString("Keep Mini Player always on top")),
            (["Search Library", "搜索资料库"], localizedString("Search Library")),
            (["Folders Tab", "文件夹标签页"], localizedString("Folders Tab")),
            (["Minimize", "最小化"], localizedString("Minimize")),
            (["Zoom", "缩放"], localizedString("Zoom")),
            (["Bring All to Front", "全部前置", "全部置于前台"], localizedString("Bring All to Front")),
            (["Enter Full Screen", "进入全屏幕", "进入全屏"], localizedString("Enter Full Screen")),
            (["Exit Full Screen", "退出全屏幕", "退出全屏"], localizedString("Exit Full Screen")),
            (["Project Homepage", "项目主页"], localizedString("Project Homepage")),
            (["Support Development", "支持开发"], localizedString("Support Development")),
            (["Petrichor User Guide", "Petrichor 用户指南"], localizedString("Petrichor User Guide"))
        ]
    }

    private static func localizedString(_ key: String.LocalizationValue) -> String {
        String(appLocalized: key)
    }

    private static func updateMenuTitles(in menu: NSMenu, matching candidates: Set<String>, to title: String) {
        for item in menu.items {
            if candidates.contains(item.title) {
                item.title = title
                item.submenu?.title = title
            }

            if let submenu = item.submenu {
                updateMenuTitles(in: submenu, matching: candidates, to: title)
            }
        }
    }

    private static func updateAppNamedMenuTitles(in menu: NSMenu) {
        for appName in appMenuNameCandidates {
            updateMenuTitles(
                in: menu,
                matching: Set(["Hide \(appName)", "隐藏 \(appName)"]),
                to: "\(localizedString("Hide")) \(appName)"
            )
            updateMenuTitles(
                in: menu,
                matching: Set(["Quit \(appName)", "退出 \(appName)"]),
                to: "\(localizedString("Quit")) \(appName)"
            )
        }
    }

    private static var appMenuNameCandidates: [String] {
        [
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            ProcessInfo.processInfo.processName,
            "Petrichor",
            "Petrichor Dev"
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { names, name in
            if !names.contains(name) {
                names.append(name)
            }
        }
    }
}
