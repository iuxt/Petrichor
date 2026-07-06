#!/usr/bin/env bash
# Unit tests for EqualizerHeadroomCompensation.gainOffset, the shared EQ headroom
# policy used by both playback backends. Verifies the preamp compensation logic
# without needing a running audio engine.
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

// --- EQ disabled: no compensation regardless of gains ---
let off = EqualizerHeadroomCompensation.gainOffset(eqEnabled: false, gains: [3, 3, 3, 3, 3, 3, 3, 3, 3, 3])
precondition(off == 0, "EQ disabled should yield 0 offset, got \(off)")
print("EQ disabled -> 0 offset OK")

// --- EQ enabled, flat (all zeros): no positive boost, no compensation ---
let flat = EqualizerHeadroomCompensation.gainOffset(eqEnabled: true, gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
precondition(flat == 0, "Flat EQ should yield 0 offset, got \(flat)")
print("EQ enabled + flat gains -> 0 offset OK")

// --- EQ enabled with positive boost: offset = -(max + 1.0) ---
let boost = EqualizerHeadroomCompensation.gainOffset(eqEnabled: true, gains: [0, 2, 0, 0, 0, 0, 0, 0, 0, 0])
precondition(boost == -3.0, "2dB boost should yield -3.0 offset (-(2+1)), got \(boost)")
print("EQ enabled + 2dB boost -> -3.0 OK")

let bigBoost = EqualizerHeadroomCompensation.gainOffset(eqEnabled: true, gains: [0, 0, 0, 0, 6, 0, 0, 0, 0, 0])
precondition(bigBoost == -7.0, "6dB boost should yield -7.0 offset (-(6+1)), got \(bigBoost)")
print("EQ enabled + 6dB boost -> -7.0 OK")

// --- EQ enabled with only cuts (negative gains): no compensation ---
let cuts = EqualizerHeadroomCompensation.gainOffset(eqEnabled: true, gains: [-3, -2, -1, 0, 0, 0, 0, 0, 0, 0])
precondition(cuts == 0, "All-negative gains should yield 0 offset, got \(cuts)")
print("EQ enabled + only cuts -> 0 offset OK")

// --- Mixed: offset is driven by the max positive gain only ---
let mixed = EqualizerHeadroomCompensation.gainOffset(eqEnabled: true, gains: [-4, 3, -2, 1, 0, 0, 0, 0, 0, 0])
precondition(mixed == -4.0, "Max boost 3dB should yield -4.0 (-(3+1)), got \(mixed)")
print("EQ enabled + mixed (max +3) -> -4.0 OK")

// --- Empty array: max() returns nil -> 0 ---
let empty = EqualizerHeadroomCompensation.gainOffset(eqEnabled: true, gains: [])
precondition(empty == 0, "Empty gains should yield 0, got \(empty)")
print("EQ enabled + empty gains -> 0 OK")

print("All EQ headroom compensation tests passed")
SWIFT

swiftc Core/Playback/EqualizerHeadroomCompensation.swift "$tmpdir/main.swift" -o "$tmpdir/eq-test"
"$tmpdir/eq-test"
