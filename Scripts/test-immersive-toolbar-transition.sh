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
