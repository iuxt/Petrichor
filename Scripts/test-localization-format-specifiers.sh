#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import re
from pathlib import Path

strings = json.loads(Path("Resources/Localizable.xcstrings").read_text())["strings"]
specifier_pattern = re.compile(r"%(?:(\d+)\$)?(?:[-+#0 ]*\d*(?:\.\d+)?)*(?:@|lld|ld|d|f|s)")


def specifiers(value):
    return [match.group(0) for match in specifier_pattern.finditer(value)]


def specifier_type(specifier):
    return specifier.rsplit("$", 1)[-1].lstrip("%")


errors = []
for key, entry in strings.items():
    key_specs = specifiers(key)
    if len(key_specs) < 2:
        continue

    key_types = [specifier_type(spec) for spec in key_specs]
    for locale, data in entry.get("localizations", {}).items():
        value = data.get("stringUnit", {}).get("value", "")
        value_specs = specifiers(value)
        value_types = [specifier_type(spec) for spec in value_specs]

        if value_types == key_types:
            continue

        has_positions = all("$" in spec for spec in value_specs)
        if value_types and not has_positions:
            errors.append(f"{locale}: {key!r} -> {value!r}")

if errors:
    raise SystemExit(
        "Localized strings that reorder format arguments must use positional specifiers:\n"
        + "\n".join(errors)
    )

print("Localization format specifier checks passed")
PY
