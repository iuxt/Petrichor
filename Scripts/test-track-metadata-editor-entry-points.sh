#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MENU="$ROOT_DIR/Views/Components/TrackContextMenu.swift"
CONTENT="$ROOT_DIR/Views/Main/ContentView.swift"
CONSTANTS="$ROOT_DIR/Utilities/Constants.swift"
STRINGS="$ROOT_DIR/Resources/Localizable.xcstrings"
MODEL="$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift"
FILE_SERVICE="$ROOT_DIR/Core/Metadata/SFBTrackMetadataFileService.swift"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"
VIEW_MODEL="$ROOT_DIR/Managers/TrackMetadataEditorViewModel.swift"
SHEET="$ROOT_DIR/Views/Library/Sheets/TrackMetadataEditorSheet.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$CONSTANTS" \
    'static let editTrackMetadata = Notification\.Name\("EditTrackMetadata"\)' \
    'Typed metadata editor notification is missing.'
require_pattern "$MENU" \
    'createEditInfoItem\(for: \[track\]\)' \
    'Single-track and player menus must expose Edit Track Info.'
require_pattern "$MENU" \
    'createEditInfoItem\(for: tracks\)' \
    'Multi-track menus must expose Edit Track Info.'
require_pattern "$MENU" \
    'guard !tracks\.isEmpty else \{ return \[\] \}' \
    'An empty selection must not create a context menu.'
require_pattern "$MENU" \
    'String\(appLocalized: "Edit Track Info\.\.\."\)' \
    'The localized menu action is missing.'
require_pattern "$MENU" \
    'name: \.editTrackMetadata' \
    'Metadata editor menus must post the typed notification.'
require_pattern "$MENU" \
    'userInfo: \["tracks": tracks\]' \
    'Metadata editor menus must post one [Track] payload.'
require_pattern "$CONTENT" \
    '@State private var trackMetadataEditorRequest: TrackMetadataEditorRequest\?' \
    'ContentView must own the active editor request.'
require_pattern "$CONTENT" \
    'sheet\(item: \$trackMetadataEditorRequest\)' \
    'ContentView must present the editor sheet.'
require_pattern "$CONTENT" \
    'publisher\(for: \.editTrackMetadata\)' \
    'ContentView must receive metadata edit requests.'
require_pattern "$CONTENT" \
    'notification\.userInfo\?\["tracks"\] as\? \[Track\]' \
    'ContentView must safely decode the [Track] payload.'
require_pattern "$CONTENT" \
    '!tracks\.isEmpty' \
    'ContentView must reject empty metadata edit requests.'
require_pattern "$CONTENT" \
    'trackMetadataEditorRequest\.wrappedValue == nil' \
    'ContentView must not replace an active metadata editor request.'
require_pattern "$CONTENT" \
    '\.environmentObject\(libraryManager\)' \
    'The metadata editor sheet must receive LibraryManager.'
require_pattern "$CONTENT" \
    '\.environmentObject\(playlistManager\)' \
    'The metadata editor sheet must receive PlaylistManager.'
require_pattern "$CONTENT" \
    '\.environmentObject\(playbackManager\)' \
    'The metadata editor sheet must receive PlaybackManager.'

python3 - "$MENU" "$CONTENT" "$MODEL" "$FILE_SERVICE" "$PLAYBACK" "$VIEW_MODEL" "$SHEET" "$STRINGS" <<'PY'
import json
import re
import sys
from pathlib import Path

menu_path, content_path, model_path, service_path, playback_path, view_model_path, sheet_path, strings_path = map(Path, sys.argv[1:])
menu = menu_path.read_text()
content = content_path.read_text()
model = model_path.read_text()
service = service_path.read_text()
playback = playback_path.read_text()
view_model = view_model_path.read_text()
sheet = sheet_path.read_text()
catalog = json.loads(strings_path.read_text())["strings"]

if menu.count("items.append(createEditInfoItem(for: [track]))") != 2:
    raise SystemExit("Single-track and player menu branches must each append Edit Track Info exactly once.")
if menu.count("items.append(createEditInfoItem(for: tracks))") != 1:
    raise SystemExit("The real multi-selection branch must append Edit Track Info exactly once.")

sheet_route = re.search(
    r"\.sheet\(item: \$trackMetadataEditorRequest\).*?"
    r"\.environmentObject\(libraryManager\).*?"
    r"\.environmentObject\(playlistManager\).*?"
    r"\.environmentObject\(playbackManager\)",
    content,
    re.S,
)
if not sheet_route:
    raise SystemExit("The metadata editor sheet route must inject all three managers.")

required_zh = {
    "Edit Track Info...": "修改歌曲信息…",
    "File Information": "文件信息",
    "Tag Information": "标签信息",
    "Multiple Values": "多个值",
    "Selected Tracks": "已选歌曲",
    "Track Info (%1$lld Tracks)": "歌曲信息（%1$lld 首）",
    "Reading Tags...": "正在读取标签…",
    "Release Date": "发行日期",
    "Total Tracks": "总曲目数",
    "Total Discs": "总碟片数",
    "Comment": "备注",
    "Saving %1$lld of %2$lld": "正在保存第 %1$lld 首，共 %2$lld 首",
    "Saved": "已保存",
    "Skipped": "已跳过",
    "Failed": "失败",
    "Retry Failed": "重试失败项",
    "YYYY or YYYY-MM-DD": "YYYY 或 YYYY-MM-DD",
    "The release date must use YYYY or YYYY-MM-DD.": "发行日期必须使用 YYYY 或 YYYY-MM-DD 格式。",
    "%1$@ must be a positive integer.": "%1$@ 必须是正整数。",
    "This file is read-only.": "此文件为只读。",
    "The %1$@ format is read-only.": "%1$@ 格式为只读。",
    "The file “%1$@” no longer exists.": "文件“%1$@”已不存在。",
    "The file “%1$@” is not writable.": "文件“%1$@”不可写。",
    "Could not read tags: %1$@": "无法读取标签：%1$@",
    "Could not save tags: %1$@": "无法保存标签：%1$@",
    "Saved tags could not be verified: %1$@": "无法验证已保存的标签：%1$@",
    "Playback could not be restored because track data is missing.": "由于歌曲数据缺失，无法恢复播放。",
    "Playback resumed, but its saved position could not be restored.": "播放已恢复，但无法恢复到保存前的位置。",
    "Playback restoration timed out.": "恢复播放超时。",
    "Playback could not be restored: %1$@": "无法恢复播放：%1$@",
    "Playback restoration was interrupted by another playback action.": "另一项播放操作中断了播放恢复。",
}

for key, expected in required_zh.items():
    entry = catalog.get(key)
    if entry is None:
        raise SystemExit(f"Missing English source localization key: {key}")
    actual = (
        entry.get("localizations", {})
        .get("zh-Hans", {})
        .get("stringUnit", {})
        .get("value")
    )
    if actual != expected:
        raise SystemExit(
            f"Invalid Simplified Chinese localization for {key!r}: "
            f"expected {expected!r}, got {actual!r}"
        )

source_requirements = {
    service_path: [
        "The %1$@ format is read-only.",
        "The file “%1$@” no longer exists.",
        "The file “%1$@” is not writable.",
        "Could not read tags: %1$@",
        "Could not save tags: %1$@",
        "Saved tags could not be verified: %1$@",
    ],
    playback_path: [
        "Playback could not be restored because track data is missing.",
        "Playback resumed, but its saved position could not be restored.",
        "Playback restoration timed out.",
        "Playback could not be restored: %1$@",
        "Playback restoration was interrupted by another playback action.",
    ],
    view_model_path: [
        "This file is read-only.",
        "Could not save tags: %1$@",
    ],
    sheet_path: [
        "File Information",
        "Tag Information",
        "Multiple Values",
        "Selected Tracks",
        "Track Info (%1$lld Tracks)",
        "Reading Tags...",
        "Total Tracks",
        "Total Discs",
        "Comment",
        "Saving %1$lld of %2$lld",
        "Saved",
        "Skipped",
        "Failed",
        "Retry Failed",
        "YYYY or YYYY-MM-DD",
    ],
}

texts = {
    model_path: model,
    service_path: service,
    playback_path: playback,
    view_model_path: view_model,
    sheet_path: sheet,
}
for path, keys in source_requirements.items():
    for key in keys:
        literal = f'String(appLocalized: "{key}")'
        multiline_literal = f'appLocalized: "{key}"'
        if literal not in texts[path] and multiline_literal not in texts[path]:
            raise SystemExit(f"{path.name} does not localize user-visible source key: {key}")

for key in [
    "%1$@ must be a positive integer.",
    "The release date must use YYYY or YYYY-MM-DD.",
]:
    if f'String(localized: "{key}")' not in model and f'localized: "{key}"' not in model:
        raise SystemExit(
            f"{model_path.name} must use Foundation localization for user-visible key: {key}"
        )

if "appLocalized:" in model:
    raise SystemExit("The pure metadata edit model must not depend on the app localization extension.")
if "field.rawValue" in model:
    raise SystemExit("Validation errors must not expose internal metadata field raw values.")
if "String.localizedStringWithFormat" not in service:
    raise SystemExit("Formatted file-service errors must use Foundation localized formatting.")
if not re.search(
    r'String\.localizedStringWithFormat\(\s*'
    r'String\(appLocalized: "Playback could not be restored: %1\$@"\)',
    playback,
    re.S,
):
    raise SystemExit("Formatted playback restoration errors must use Foundation localized formatting.")
if not re.search(
    r"private static func localizedSaveFailure\(.*?"
    r"String\.localizedStringWithFormat\(\s*"
    r'String\(appLocalized: "Could not save tags: %1\$@"\)',
    view_model,
    re.S,
):
    raise SystemExit("Unexpected save failures must receive a localized user-facing wrapper.")
if "outcome: .failed(Self.localizedSaveFailure(error))" not in view_model:
    raise SystemExit("The save loop must use its localized unexpected-error wrapper.")
PY

jq -e . "$STRINGS" >/dev/null
printf '%s\n' 'Track metadata editor entry point checks passed'
