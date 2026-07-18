#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHEET="$ROOT_DIR/Views/Library/Sheets/TrackMetadataEditorSheet.swift"
CHECKBOX="$ROOT_DIR/Views/Components/MixedStateCheckbox.swift"

require_file() {
    local file="$1"
    local message="$2"
    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n --multiline "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if rg -n --multiline "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_file "$SHEET" 'Metadata editor sheet is missing.'
require_file "$CHECKBOX" 'Mixed-state compilation checkbox is missing.'

require_pattern "$SHEET" 'struct TrackMetadataEditorSheet: View' \
    'Metadata editor sheet view is missing.'
require_pattern "$SHEET" '@StateObject private var model: TrackMetadataEditorViewModel' \
    'The sheet must own the metadata editor ViewModel.'
require_pattern "$SHEET" 'init\(request: TrackMetadataEditorRequest\)' \
    'The sheet must initialize from a metadata editor request.'

for phase in loading editing saving results; do
    require_pattern "$SHEET" "case \\.$phase:" \
        "The $phase phase presentation is missing."
done

require_pattern "$SHEET" 'String\(appLocalized: "File Information"\)' \
    'Read-only file information group is missing.'
require_pattern "$SHEET" 'String\(appLocalized: "Tag Information"\)' \
    'Editable tag information group is missing.'
require_pattern "$SHEET" 'String\(appLocalized: "Multiple Values"\)' \
    'Mixed-value placeholder is missing.'
require_pattern "$SHEET" 'model\.showsMixedPlaceholder\(for: field\)' \
    'Untouched mixed text fields must use the ViewModel placeholder state.'
require_pattern "$SHEET" 'model\.unavailableResults\.count' \
    'The pre-save file summary must count unavailable or read-only items.'
require_pattern "$SHEET" 'TextEditor\([\s\S]*\.accessibilityValue\(commentAccessibilityValue\)' \
    'The multiline comment editor must expose its mixed state to accessibility.'
require_pattern "$SHEET" 'private var commentAccessibilityValue: String[\s\S]*if model\.showsMixedPlaceholder\(for: \.comment\)[\s\S]*String\(appLocalized: "Multiple Values"\)[\s\S]*return model\.text\(for: \.comment\)' \
    'Only a truly mixed comment may expose Multiple Values as its accessibility value.'
require_pattern "$SHEET" 'model\.snapshots\.map\(\\\.file\.duration\)[\s\S]*format: HelperUtils\.formattedShortDuration' \
    'Duration must aggregate exact raw snapshot values before display formatting.'
require_pattern "$SHEET" 'model\.snapshots\.map\(\\\.file\.fileSize\)[\s\S]*format: Self\.formattedFileSize' \
    'File size must aggregate exact raw snapshot values before display formatting.'
require_pattern "$SHEET" 'private func aggregate<Value: Equatable>[\s\S]*values\.dropFirst\(\)\.allSatisfy\(\{ \$0 == first \}\)[\s\S]*format\(first\)' \
    'Numeric aggregation must compare raw optional values before invoking the formatter.'
reject_pattern "$SHEET" '\.duration\.map\(HelperUtils\.formattedShortDuration\)|\.fileSize\.map\(Self\.formattedFileSize\)' \
    'Technical values must not be formatted before batch aggregation.'

for field in title artist album albumArtist composer genre releaseDate \
    trackNumber trackTotal discNumber discTotal bpm comment; do
    require_pattern "$SHEET" "\\.$field" "The $field editor is missing."
done

require_pattern "$SHEET" 'pairedNumberRow\([\s\S]*field: \.trackNumber[\s\S]*totalField: \.trackTotal' \
    'Track number and track total must be presented as a paired control.'
require_pattern "$SHEET" 'pairedNumberRow\([\s\S]*field: \.discNumber[\s\S]*totalField: \.discTotal' \
    'Disc number and disc total must be presented as a paired control.'
require_pattern "$SHEET" 'TextEditor\([\s\S]*fieldBinding\(\.comment\)' \
    'The comment field must use a multiline editor backed by the comment field.'
require_pattern "$SHEET" 'MixedStateCheckbox\([\s\S]*value: model\.compilationValue' \
    'Compilation must use the mixed-state checkbox.'

require_pattern "$SHEET" 'model\.validationError\?\.field == field' \
    'Validation highlighting must target only the invalid field.'
require_pattern "$SHEET" 'model\.validationMessage' \
    'The app-localized validation message must be presented verbatim.'
reject_pattern "$SHEET" 'model\.validationError\?\.message' \
    'The sheet must not display the model fallback instead of the selected app language.'

require_pattern "$SHEET" 'ProgressView\(\s*value: Double\(model\.currentProgress\)[\s\S]*total: Double\(max\(model\.totalProgress, 1\)\)' \
    'Batch saving must show deterministic current/total progress.'
require_pattern "$SHEET" 'interactiveDismissDisabled\(model\.phase == \.saving\)' \
    'Save-time sheet dismissal must be disabled.'
require_pattern "$SHEET" 'disabled\(model\.phase == \.saving\)' \
    'The explicit close control must be disabled while saving.'
require_pattern "$SHEET" 'model\.retryFailed\(' \
    'Failed-only retry action is missing.'
require_pattern "$SHEET" 'model\.hasFailuresToRetry' \
    'Retry must only be offered when failed items exist.'

require_pattern "$SHEET" 'result\.target\.displayName' \
    'Result rows must show the affected filename.'
require_pattern "$SHEET" 'case \.skipped\(let reason\)' \
    'Skipped result reasons must be shown.'
require_pattern "$SHEET" 'case \.failed\(let reason\)' \
    'Failed result reasons must be shown.'
require_pattern "$SHEET" 'model\.savedCount' \
    'The result summary must include the saved count.'
require_pattern "$SHEET" 'model\.skippedCount' \
    'The result summary must include the skipped count.'
require_pattern "$SHEET" 'model\.failedCount' \
    'The result summary must include the failed count.'

require_pattern "$SHEET" 'onChange\(of: model\.allSelectedItemsSaved' \
    'Successful completion must react to the playback-terminal ViewModel flag.'
require_pattern "$SHEET" 'guard completed,[\s\S]*!model\.isAwaitingPlaybackRestoration,[\s\S]*!didFinishSuccessfully else' \
    'Successful completion must require terminal playback restoration and be one-shot.'
require_pattern "$SHEET" 'NotificationManager\.shared\.addMessage\(\s*\.info' \
    'All-success completion must post a success notification.'
require_pattern "$SHEET" 'didFinishSuccessfully = true[\s\S]*dismiss\(\)' \
    'All-success completion must mark completion before dismissing.'

require_pattern "$SHEET" '\.accessibilityLabel\(' \
    'Metadata editor controls must expose accessibility labels.'
require_pattern "$SHEET" '\.keyboardShortcut\(\.defaultAction\)' \
    'Save must support the default keyboard action.'
require_pattern "$SHEET" '\.keyboardShortcut\(\.cancelAction\)' \
    'Cancel or close must support the cancel keyboard action.'
reject_pattern "$SHEET" 'prompt: "[^"]+"' \
    'User-visible field prompts must go through app localization.'

require_pattern "$CHECKBOX" 'struct MixedStateCheckbox: NSViewRepresentable' \
    'Compilation control must bridge an AppKit tri-state checkbox.'
require_pattern "$CHECKBOX" 'allowsMixedState = true' \
    'Compilation checkbox must allow a mixed state.'
require_pattern "$CHECKBOX" 'value\.map \{ \$0 \? \.on : \.off \} \?\? \.mixed' \
    'A nil compilation value must render as the mixed AppKit state.'
require_pattern "$CHECKBOX" 'if sender\.state == \.mixed[\s\S]*sender\.state = \.on' \
    'A user click from mixed state must resolve to a concrete value.'
require_pattern "$CHECKBOX" 'context\.coordinator\.onChange = onChange' \
    'The AppKit coordinator callback must stay current across SwiftUI updates.'
require_pattern "$CHECKBOX" 'setAccessibilityLabel' \
    'The AppKit checkbox must expose an accessibility label.'

reject_pattern "$SHEET" 'ContentView|contextMenu|Notification\.Name' \
    'Task 6 must not add Task 7 routing or context-menu behavior.'

xcrun swiftc -frontend -parse "$SHEET" "$CHECKBOX"

printf '%s\n' 'Track metadata editor UI checks passed'
