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
