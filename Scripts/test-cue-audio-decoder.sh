#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
derived="${PETRICHOR_DERIVED_DATA:-}"
if [[ -z "$derived" ]]; then
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Petrichor-*; do
        if [[ -f "$candidate/Build/Products/Debug/SFBAudioEngine.o" ]]; then
            derived="$candidate"
            break
        fi
    done
fi
if [[ ! -f "$derived/Build/Products/Debug/SFBAudioEngine.o" ]]; then
    echo 'Build the Debug app first, or set PETRICHOR_DERIVED_DATA to its DerivedData directory.' >&2
    exit 1
fi
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-cue-decoder.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
# Generate known PCM and reuse built package objects. This never opens an audio
# device: it verifies the actual production decoder's boundaries and seek origin.
python3 - "$ROOT_DIR" "$derived" "$TMP_DIR" <<'PY'
from pathlib import Path
import subprocess, sys, wave, array
repo, derived, root = map(Path, sys.argv[1:])
with wave.open(str(root/'image.wav'), 'wb') as file:
    file.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
    file.writeframes(array.array('h', [1000]*44100 + [2000]*44100 + [3000]*44100).tobytes())
(root/'main.swift').write_text('''import Foundation
import AVFoundation
import SFBAudioEngine
enum AudioPlayerError: Error { case invalidFormat }
let segment = CueTrackSegment(sheetPath: "/tmp/Album.cue", sourcePath: CommandLine.arguments[1], number: 2, start: 1, end: 2)
let region = try CueAudioDecoder.make(segment: segment)
try region.open()
precondition(region.length == 44100 && region.position == 0)
let buffer = AVAudioPCMBuffer(pcmFormat: region.processingFormat, frameCapacity: 4096)!
var total: Int64 = 0
while true {
    try region.decode(into: buffer, length: 4096)
    if buffer.frameLength == 0 { break }
    total += Int64(buffer.frameLength)
}
precondition(total == 44100, "Exact one-second region EOF")
try region.seek(to: 22050)
precondition(region.position == 22050, "Seek is relative to the CUE region")
try region.decode(into: buffer, length: 1)
precondition(buffer.frameLength == 1)
if let sample = buffer.floatChannelData?.pointee[0] {
    precondition(abs(sample - Float(2000.0/32768)) < 0.00001, "Seek remains in second track audio")
} else if let sample = buffer.int16ChannelData?.pointee[0] {
    precondition(sample == 2000)
} else { preconditionFailure("Unexpected test PCM format") }
try region.close()
var frameSegment = segment
frameSegment.start = 1 + 1.0/75
frameSegment.end = 1 + 2.0/75
let frameRegion = try CueAudioDecoder.make(segment: frameSegment)
try frameRegion.open()
precondition(frameRegion.length == 588, "A CD frame is 588 samples at 44.1 kHz")
try frameRegion.close()
var invalidSegment = segment
invalidSegment.start = -1
do {
    _ = try CueAudioDecoder.make(segment: invalidSegment)
    preconditionFailure("Negative start must not reach the decoder")
} catch {}
print("Real SFB decoder: CUE frame boundaries, EOF, relative seek and invalid bounds passed")
''')
products = derived/'Build/Products/Debug'
args = ['xcrun', 'swiftc', '-I', str(products), '-I',
        str(derived/'SourcePackages/checkouts/SFBAudioEngine/Sources/CSFBAudioEngine/include'),
        '-F', str(products), '-F', str(products/'PackageFrameworks'),
        '-Xlinker', '-rpath', '-Xlinker', str(products)]
for module in (derived/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'):
    args += ['-Xcc', '-fmodule-map-file='+str(module)]
args += [str(repo/'Core/Cue/CueSheet.swift'), str(repo/'Core/Playback/CueAudioDecoder.swift'), str(root/'main.swift')]
args += [str(path) for path in products.glob('*.o') if path.name != 'GRDB.o']
for framework in products.glob('*.framework'):
    args += ['-framework', framework.stem]
args += ['-lc++', '-framework', 'Accelerate', '-framework', 'AudioToolbox',
         '-framework', 'AVFoundation', '-o', str(root/'decoder-test')]
subprocess.run(args, check=True)
subprocess.run([str(root/'decoder-test'), str(root/'image.wav')], check=True)
PY
