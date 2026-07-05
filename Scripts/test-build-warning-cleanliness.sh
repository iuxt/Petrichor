#!/usr/bin/env bash
set -euo pipefail

build_script="Scripts/build-installer.sh"
project_file="Petrichor.xcodeproj/project.pbxproj"
encodable_record="Vendor/SwiftPM/GRDB.swift/GRDB/Record/EncodableRecord.swift"
fetchable_record="Vendor/SwiftPM/GRDB.swift/GRDB/Record/FetchableRecord.swift"
host_time="Vendor/SwiftPM/SFBAudioEngine/Sources/CSFBAudioEngine/Player/host_time.hpp"
speex_mdf="Vendor/SwiftPM/CSpeex/Sources/speex/libspeexdsp/mdf.c"
speex_math_approx="Vendor/SwiftPM/CSpeex/Sources/speex/libspeexdsp/math_approx.h"

if [ -f "$encodable_record" ] && [ -f "$fetchable_record" ]; then
    if rg -n 'encoder\.userInfo = databaseEncodingUserInfo$' "$encodable_record" >/dev/null; then
        printf 'GRDB encoding userInfo must not assign [CodingUserInfoKey: Any] directly to JSONEncoder.userInfo.\n' >&2
        exit 1
    fi

    if rg -n 'databaseEncodingUserInfo as \[CodingUserInfoKey: any Sendable\]' "$encodable_record" >/dev/null; then
        printf 'GRDB encoding userInfo must not use a direct Sendable cast that still triggers strict concurrency warnings.\n' >&2
        exit 1
    fi

    if rg -n 'decoder\.userInfo = databaseDecodingUserInfo$' "$fetchable_record" >/dev/null; then
        printf 'GRDB decoding userInfo must not assign [CodingUserInfoKey: Any] directly to JSONDecoder.userInfo.\n' >&2
        exit 1
    fi

    if rg -n 'databaseDecodingUserInfo as \[CodingUserInfoKey: any Sendable\]' "$fetchable_record" >/dev/null; then
        printf 'GRDB decoding userInfo must not use a direct Sendable cast that still triggers strict concurrency warnings.\n' >&2
        exit 1
    fi

    if ! rg -n 'unsafeBitCast\(userInfo, to: \[CodingUserInfoKey: any Sendable\]\.self\)' "$encodable_record" "$fetchable_record" >/dev/null; then
        printf 'GRDB userInfo must bridge through a helper that avoids strict concurrency warnings without changing the public Any API.\n' >&2
        exit 1
    fi
fi

if [ -f "$host_time" ] && rg -n 'timebase = \[\] noexcept' "$host_time" >/dev/null; then
    printf 'SFBAudioEngine host_time lambda must include an explicit empty parameter clause for C++23 compatibility.\n' >&2
    exit 1
fi

if [ -f "$speex_mdf" ] && [ -f "$speex_math_approx" ] && rg -n '\bM_PI\b' "$speex_mdf" "$speex_math_approx" >/dev/null; then
    printf 'CSpeex libspeexdsp must use a private pi constant instead of the ambiguous system M_PI macro.\n' >&2
    exit 1
fi

if find Resources/Assets.xcassets -path '*.symbolset/*.svg' -print0 | xargs -0 rg -n 'Template v\.([7-9]|[1-9][0-9]+)\.' >/dev/null; then
    printf 'Custom SF Symbol SVG assets must use template format 6.x or older so Xcode 16 actool can compile them on CI.\n' >&2
    exit 1
fi

if find Resources/Assets.xcassets -path '*.symbolset/*.svg' -print0 | xargs -0 rg -n 'Requires Xcode ([7-9][0-9]?|1[7-9]|[2-9][0-9]) or greater' >/dev/null; then
    printf 'Custom SF Symbol SVG assets must not require newer than Xcode 16 because release CI runs Xcode 16.\n' >&2
    exit 1
fi

if rg -n '\.buttonStyle\(\.glass\)|glassEffect|sharedBackgroundVisibility' Views PetrichorApp.swift Managers Core Utilities --glob '!Views/Components/ViewExtensions.swift' >/dev/null; then
    printf 'SwiftUI APIs newer than Xcode 16 must be isolated behind compatibility helpers in ViewExtensions.swift.\n' >&2
    exit 1
fi

if rg -n '\.buttonStyle\(\.glass\)|glassEffect|sharedBackgroundVisibility' Views/Components/ViewExtensions.swift >/dev/null &&
    ! rg -n '#if compiler\(>=6\.2\)' Views/Components/ViewExtensions.swift >/dev/null; then
    printf 'ViewExtensions SwiftUI compatibility helpers must guard new SDK APIs with #if compiler(>=6.2).\n' >&2
    exit 1
fi

if ! rg -n -- '--hdiutil-quiet' "$build_script" >/dev/null; then
    printf 'build-installer must pass --hdiutil-quiet to create-dmg to suppress deprecated hdiutil create/convert output.\n' >&2
    exit 1
fi

if ! rg -n -- '--no-internet-enable' "$build_script" >/dev/null; then
    printf 'build-installer must pass --no-internet-enable to create-dmg because internet-enable was removed from hdiutil.\n' >&2
    exit 1
fi

if rg -n -- '-destination "platform=macOS"' "$build_script" >/dev/null; then
    printf 'build-installer local builds must use a unique macOS destination to avoid xcodebuild multiple destination warnings.\n' >&2
    exit 1
fi

if ! rg -n -- '-destination "generic/platform=macOS"' "$build_script" >/dev/null; then
    printf 'build-installer local builds must target generic/platform=macOS.\n' >&2
    exit 1
fi

if ! rg -n 'CLANG_CXX_LANGUAGE_STANDARD=gnu\+\+20' "$build_script" >/dev/null; then
    printf 'build-installer must pass C++20 explicitly to xcodebuild so SwiftPM C++ dependencies compile on CI.\n' >&2
    exit 1
fi

if ! rg -n -- '-D_LIBCPP_ENABLE_EXPERIMENTAL' "$build_script" >/dev/null; then
    printf 'build-installer must define _LIBCPP_ENABLE_EXPERIMENTAL so Xcode 16 exposes std::jthread and std::stop_token for SwiftPM C++ dependencies.\n' >&2
    exit 1
fi

if ! rg -n 'diskutil image resize --size' "$build_script" >/dev/null; then
    printf 'build-installer must patch create-dmg hdiutil resize calls to diskutil image resize.\n' >&2
    exit 1
fi

if ! rg -n 'diskutil image attach --mountPoint "\\\$\{MOUNT_DIR\}" --nobrowse' "$build_script" >/dev/null; then
    printf 'build-installer must patch create-dmg hdiutil attach calls to diskutil image attach with a random mount point.\n' >&2
    exit 1
fi

if ! rg -n 'mkdir -p "\\\$\{MOUNT_DIR\}"' "$build_script" >/dev/null; then
    printf 'build-installer must create the random diskutil mount point before attaching the DMG.\n' >&2
    exit 1
fi

if ! rg -n 'MOUNT_DIR="\\\$\{TMPDIR:-\\?/tmp\}\\?/dmg' "$build_script" >/dev/null; then
    printf 'build-installer diskutil mount points must live under TMPDIR instead of /Volumes, which is not user-writable on CI.\n' >&2
    exit 1
fi

if ! rg -n 'diskutil eject "\\\$\{DEV_NAME\}"' "$build_script" >/dev/null; then
    printf 'build-installer must patch create-dmg hdiutil detach calls to diskutil eject.\n' >&2
    exit 1
fi

if rg -n '^[[:space:]]*hdiutil create' "$build_script" >/dev/null; then
    printf 'build-installer fallback DMG creation must use diskutil image create instead of deprecated hdiutil create.\n' >&2
    exit 1
fi

if ! rg -n '"test-build-warning-cleanliness\.sh"' "$project_file" >/dev/null; then
    printf 'build warning test script must be excluded from the Petrichor app resource sync group.\n' >&2
    exit 1
fi

if ! rg -n '"test-vendored-swiftpm-offline\.sh"' "$project_file" >/dev/null; then
    printf 'missing vendored SwiftPM test script must be excluded from the Petrichor app resource sync group.\n' >&2
    exit 1
fi

printf 'build warning cleanliness checks passed\n'
