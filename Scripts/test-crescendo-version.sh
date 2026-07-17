#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
from pathlib import Path

resolved = json.loads(
    Path("Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text()
)
pin = next((pin for pin in resolved["pins"] if pin["identity"] == "crescendokit"), None)
if pin is None:
    raise SystemExit("Package.resolved must contain the CrescendoKit pin.")

state = pin["state"]
expected_version = "1.1.1"
expected_revision = "ef50ecfcafad7b5976735c09a8741158b642d258"

if state.get("version") != expected_version:
    raise SystemExit(
        f"CrescendoKit must be pinned to {expected_version}; found {state.get('version')}."
    )

if state.get("revision") != expected_revision:
    raise SystemExit(
        f"CrescendoKit {expected_version} must use revision {expected_revision}; "
        f"found {state.get('revision')}."
    )

print("CrescendoKit version checks passed")
PY
