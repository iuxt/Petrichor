#!/usr/bin/env bash
set -euo pipefail

source_file="Views/Main/ContentView.swift"
extensions_file="Views/Components/ViewExtensions.swift"

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

if ! rg -nU '(?s)private func openImmersive\(\).*?makeFirstResponder\(nil\).*?completion:.*?guard isImmersiveActive else.*?isImmersiveToolbarItemsHidden = true' "$source_file" >/dev/null; then
    printf 'Opening immersive mode must dismiss search focus and hide native items after the animation, guarding against a quick close.\n' >&2
    exit 1
fi

hidden_item_count="$(rg -cF '.hidden(isImmersiveToolbarItemsHidden)' "$source_file" || true)"
if [[ "$hidden_item_count" -ne 5 ]]; then
    printf 'All 5 visible toolbar groups must hide their native items to remove search fields and shared backgrounds.\n' >&2
    exit 1
fi

if rg -n 'toolbar\?\.isVisible[[:space:]]*=|immersiveToolbarWasVisible' "$source_file" >/dev/null; then
    printf 'Immersive mode must keep the native toolbar laid out so window button positions stay fixed.\n' >&2
    exit 1
fi

if ! rg -nU '(?s)private func restoreToolbarContentForImmersiveClose\(\).*?isImmersiveToolbarItemsHidden = false.*?DispatchQueue\.main\.async.*?guard !isImmersiveActive else.*?withAnimation.*?isImmersiveToolbarContentHidden = false' "$source_file" >/dev/null; then
    printf 'Closing immersive mode must restore native items before animating content back in, guarding against a quick reopen.\n' >&2
    exit 1
fi

if ! rg -nF '.toolbarBackground(isImmersiveActive ? .hidden : .automatic, for: .windowToolbar)' "$source_file" >/dev/null; then
    printf 'Immersive mode must hide the toolbar background while preserving its layout.\n' >&2
    exit 1
fi

if rg -n 'adaptiveSharedBackgroundHidden\([^)]*isImmersive|\.sharedBackgroundVisibility\(' "$source_file" >/dev/null; then
    printf 'Immersive mode must hide whole toolbar items and preserve default tab/search backgrounds for restoration.\n' >&2
    exit 1
fi

background_count="$(rg -cF '.adaptiveSharedBackgroundHidden()' "$source_file" || true)"
if [[ "$background_count" -ne 1 ]]; then
    printf 'Only the notification toolbar item should permanently hide its shared background.\n' >&2
    exit 1
fi

if ! rg -nU '(?s)func adaptiveSharedBackgroundHidden\(\).*?#if compiler\(>=6\.2\).*?self\.sharedBackgroundVisibility\(\.hidden\)' "$extensions_file" >/dev/null; then
    printf 'The static notification background helper must keep Xcode 16 compatibility.\n' >&2
    exit 1
fi

printf 'Immersive toolbar transition checks passed\n'
