#!/bin/bash

# build-installer.sh - Build and create a DMG installer for Petrichor

set -e  # Exit on error

# Configuration
APP_NAME="Petrichor"
SCHEME="Petrichor"
CONFIGURATION="Release"
PROJECT="Petrichor.xcodeproj"
NOTARY_PROFILE="Petrichor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_BACKGROUND="${PETRICHOR_INSTALLER_BACKGROUND:-$SCRIPT_DIR/assets/install.svg}"
DMG_WINDOW_WIDTH=660
DMG_WINDOW_HEIGHT=400
DMG_ICON_SIZE=128
DMG_APP_ICON_X=165
DMG_APP_ICON_Y=180
DMG_APPLICATIONS_ICON_X=495
DMG_APPLICATIONS_ICON_Y=180

# Read from environment variables
TEAM_ID="${PETRICHOR_TEAM_ID:-}"
DEVELOPER_ID="${PETRICHOR_DEVELOPER_ID:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "✅ $1"; }
error() { echo -e "❌ $1" >&2; }
warning() { echo -e "⚠️  $1"; }
info() { echo -e "ℹ️  $1"; }

prepare_dmg_source() {
    local app_source="$1"
    local dmg_source="$2"

    rm -rf "$dmg_source"
    mkdir -p "$dmg_source/.background"
    ditto "$app_source" "$dmg_source/$APP_NAME.app"

    if [ -f "$INSTALLER_BACKGROUND" ]; then
        cp "$INSTALLER_BACKGROUND" "$dmg_source/.background/install.svg"
    else
        warning "Installer background not found at $INSTALLER_BACKGROUND"
    fi
}

create_dmg_with_layout() {
    local dmg_title="$1"
    local dmg_path="$2"
    local dmg_source="$3"
    local create_dmg_bin
    create_dmg_bin="$(create_dmg_command)"

    local args=(
        --volname "$dmg_title"
        --hdiutil-quiet
        --no-internet-enable
        --window-size "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT"
        --icon-size "$DMG_ICON_SIZE"
        --icon "$APP_NAME.app" "$DMG_APP_ICON_X" "$DMG_APP_ICON_Y"
        --app-drop-link "$DMG_APPLICATIONS_ICON_X" "$DMG_APPLICATIONS_ICON_Y"
    )

    if [ -f "$dmg_source/.background/install.svg" ]; then
        args+=(--background "$dmg_source/.background/install.svg")
    fi

    "$create_dmg_bin" "${args[@]}" "$dmg_path" "$dmg_source"
}

create_dmg_command() {
    local original
    original="$(command -v create-dmg)"

    if ! grep -q 'hdiutil_retry detach "${DEV_NAME}"' "$original"; then
        printf '%s\n' "$original"
        return 0
    fi

    local wrapper_dir="${BUILD_DIR:-${TMPDIR:-/tmp}/petrichor-build}/create-dmg-diskutil-eject"
    local original_dir
    original_dir="$(cd "$(dirname "$original")" && pwd)"
    local prefix_dir
    prefix_dir="$(dirname "$original_dir")"

    rm -rf "$wrapper_dir"
    mkdir -p "$wrapper_dir"
    cp "$original" "$wrapper_dir/create-dmg"
    touch "$wrapper_dir/.this-is-the-create-dmg-repo"

    if [ -d "$original_dir/support" ]; then
        ln -s "$original_dir/support" "$wrapper_dir/support"
    elif [ -d "$prefix_dir/share/create-dmg/support" ]; then
        ln -s "$prefix_dir/share/create-dmg/support" "$wrapper_dir/support"
    fi

    perl -0pi -e '
        s/hdiutil resize -limits "\$\{DMG_TEMP_NAME\}"/hdiutil resize -limits "\${DMG_TEMP_NAME}" 2>\/dev\/null/g;
        s/hdiutil resize \$\{HDIUTIL_VERBOSITY\} -size \$\{DISK_IMAGE_SIZE\}m "\$\{DMG_TEMP_NAME\}"/diskutil image resize --size \${DISK_IMAGE_SIZE}m "\${DMG_TEMP_NAME}"/g;
        s/DEV_NAME=\$\(hdiutil attach -mountrandom \$\{MOUNT_RANDOM_PATH\} -readwrite -noverify -noautoopen -nobrowse "\$\{DMG_TEMP_NAME\}"/MOUNT_DIR="\${MOUNT_RANDOM_PATH}\/dmg.\${RANDOM}.\$\$"\nDEV_NAME=\$\(diskutil image attach --mountPoint "\${MOUNT_DIR}" --nobrowse "\${DMG_TEMP_NAME}"/g;
        s/hdiutil_retry detach "\$\{DEV_NAME\}"/diskutil eject "\${DEV_NAME}"/g;
    ' "$wrapper_dir/create-dmg"
    chmod +x "$wrapper_dir/create-dmg"
    printf '%s\n' "$wrapper_dir/create-dmg"
}

# Check required tools
check_requirements() {
    local missing_tools=()
    
    # Check for Xcode
    if ! command -v xcodebuild >/dev/null 2>&1; then
        missing_tools+=("xcodebuild (Install Xcode from App Store)")
    fi
    
    # Check for git
    if ! command -v git >/dev/null 2>&1; then
        missing_tools+=("git (Install Xcode Command Line Tools)")
    fi
    
    # Check for codesign unless doing an unsigned local package
    if [ "$LOCAL_PACKAGE" = false ] && ! command -v codesign >/dev/null 2>&1; then
        missing_tools+=("codesign (Install Xcode Command Line Tools)")
    fi

    if ! command -v hdiutil >/dev/null 2>&1; then
        missing_tools+=("hdiutil (Install macOS)")
    fi

    if ! command -v diskutil >/dev/null 2>&1; then
        missing_tools+=("diskutil (Install macOS)")
    fi
    
    # Check for notarytool (if not bypassing)
    if [ "$BYPASS_NOTARY" = false ] && ! command -v xcrun >/dev/null 2>&1; then
        missing_tools+=("xcrun (Install Xcode Command Line Tools)")
    fi
    
    # Check optional tools
    if ! command -v xcpretty >/dev/null 2>&1; then
        warning "xcpretty not found - install with: gem install xcpretty"
        warning "Build output will be verbose without xcpretty"
    fi
    
    if ! command -v create-dmg >/dev/null 2>&1; then
        warning "create-dmg not found - install with: npm install --global create-dmg"
        warning "Using fallback DMG creation method"
    fi
    
    # Exit if required tools are missing
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            error "  - $tool"
        done
        echo ""
        error "Please install the missing tools and try again."
        exit 1
    fi
    
    # Auto-detect project directory
    if [ -e "$PROJECT" ]; then
        # Already in project root (-e checks if exists, whether file or directory)
        PROJECT_ROOT="."
    elif [ -e "../$PROJECT" ]; then
        # In Scripts directory
        PROJECT_ROOT=".."
        cd "$PROJECT_ROOT"
        log "Changed to project root directory"
    else
        error "Cannot find $PROJECT"
        error "Please run this script from the project root or Scripts directory"
        exit 1
    fi
}

# Progress animation
show_progress() {
    local pid=$1
    tput civis  # Hide cursor
    while kill -0 $pid 2>/dev/null; do
        for dots in "" "." ".." "..."; do
            printf "\r   Building%-4s " "$dots"
            sleep 0.1
            kill -0 $pid 2>/dev/null || break
        done
    done
    printf "\r                    \r"
    tput cnorm  # Show cursor
}

# Run xcodebuild with standard parameters
run_build() {
    local action="$1"
    local log_file="$2"
    local arch="$3"
    shift 3
    
    # Configure signing based on available credentials
    local sign_config=""
    if [ -n "$DEVELOPER_ID" ] && [ "$DEVELOPER_ID" != "-" ]; then
        # Use Developer ID (paid account)
        sign_config="DEVELOPMENT_TEAM='$TEAM_ID' CODE_SIGN_IDENTITY='$DEVELOPER_ID' CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS='--timestamp --options=runtime'"
    else
        # Use automatic signing (free account)
        sign_config="CODE_SIGN_IDENTITY='Apple Development' CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic ENABLE_HARDENED_RUNTIME=NO"
    fi
    
    local cmd="xcodebuild $action \
        -project '$PROJECT' \
        -scheme '$SCHEME' \
        -configuration '$CONFIGURATION' \
        $sign_config \
        MARKETING_VERSION='$VERSION' \
        CURRENT_PROJECT_VERSION='$VERSION' \
        ARCHS='$arch' \
        ONLY_ACTIVE_ARCH=NO \
        $*"
    
    if [ "$VERBOSE" = false ]; then
        cmd="$cmd -quiet"
        if command -v xcpretty >/dev/null 2>&1; then
            (eval "$cmd" 2>&1 | tee "$log_file" | xcpretty --no-utf --simple >/dev/null 2>&1) &
            local pid=$!
            show_progress $pid
            wait $pid
            return $?
        fi
    fi
    
    eval "$cmd" 2>&1 | tee "$log_file"
    return ${PIPESTATUS[0]}
}

# Run an unsigned local xcodebuild build for personal packaging
run_local_build() {
    local log_file="$1"
    local arch="$2"
    local derived_data="$3"

    local cmd=(
        xcodebuild build
        -project "$PROJECT"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -destination "generic/platform=macOS"
        -derivedDataPath "$derived_data"
        "MARKETING_VERSION=$VERSION"
        "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
        "ARCHS=$arch"
        ONLY_ACTIVE_ARCH=NO
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGN_IDENTITY=
        CODE_SIGN_ENTITLEMENTS=
    )

    if [ "$VERBOSE" = false ]; then
        cmd+=(-quiet)
    fi

    "${cmd[@]}" 2>&1 | tee "$log_file"
    return ${PIPESTATUS[0]}
}

# Notarize function (app or dmg)
notarize() {
    local file="$1"
    local type="$2"
    
    info "Notarizing $type (this may take 5-15 minutes)..."
    
    # Create zip if it's an app
    if [[ "$file" == *.app ]]; then
        local zip_path="${file}.zip"
        ditto -c -k --keepParent "$file" "$zip_path"
        file="$zip_path"
    fi
    
    # Submit for notarization
    if xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait; then
        log "$type notarization completed"
        
        # Staple the ticket (use original path for .app)
        local staple_target="${1}"
        xcrun stapler staple "$staple_target"
        
        # Clean up zip if created
        [[ "$file" == *.zip ]] && rm -f "$file"
        return 0
    else
        error "$type notarization failed!"
        [[ "$file" == *.zip ]] && rm -f "$file"
        return 1
    fi
}

# Create DMG for specific architecture
create_installer() {
    local arch="$1"
    local suffix="$2"
    local display_name="$3"
    
    log "Building $display_name version..."
    
    local archive_path="$BUILD_DIR/$APP_NAME-$suffix.xcarchive"
    local export_path="$BUILD_DIR/export-$suffix"
    local dmg_path="$BUILD_DIR/${APP_NAME}-${VERSION}-$suffix.dmg"
    local error_log="$BUILD_DIR/build-$suffix.log"
    
    # Step 1: Archive
    info "Archiving for $display_name..."
    run_build archive "$error_log" "$arch" \
        -archivePath "$archive_path" \
        -destination "generic/platform=macOS" \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    
    if [ ! -d "$archive_path" ]; then
        error "Archive failed for $display_name! Check $error_log for details"
        grep -E "(error:|ERROR:|failed|FAILED)" "$error_log" 2>/dev/null | tail -10
        return 1
    fi
    
    # Step 2: Export based on signing method
    info "Exporting signed app..."
    mkdir -p "$export_path"
    
    if [ -n "$DEVELOPER_ID" ] && [ "$DEVELOPER_ID" != "-" ]; then
        # Export with Developer ID
        cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF
        
        xcodebuild -exportArchive \
            -archivePath "$archive_path" \
            -exportPath "$export_path" \
            -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" &>/dev/null
    else
        # Export with development signing (free account)
        cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
</dict>
</plist>
EOF
        
        xcodebuild -exportArchive \
            -archivePath "$archive_path" \
            -exportPath "$export_path" \
            -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" &>/dev/null
    fi
    
    [ -d "$export_path/$APP_NAME.app" ] || { error "Export failed"; return 1; }
    
    # Step 3: Notarize app (skip if bypassing)
    if [ "$BYPASS_NOTARY" = false ]; then
        notarize "$export_path/$APP_NAME.app" "app" || return 1
    else
        warning "Skipping app notarization (signed but not notarized)"
    fi
    
    # Step 4: Create DMG
    info "Creating DMG for $display_name..."

    if command -v create-dmg >/dev/null 2>&1; then
        local dmg_title="$APP_NAME $VERSION"
        [ "$suffix" != "Universal" ] && dmg_title="$APP_NAME-$suffix"
        local dmg_source="$BUILD_DIR/dmg-source-$suffix"
        prepare_dmg_source "$export_path/$APP_NAME.app" "$dmg_source"
        create_dmg_with_layout "$dmg_title" "$dmg_path" "$dmg_source" || {
            error "create-dmg failed"; return 1
        }
        rm -rf "$dmg_source"
    else
        # Fallback to diskutil
        DMG_DIR="$BUILD_DIR/dmg-$suffix"
        mkdir -p "$DMG_DIR"
        cp -R "$export_path/$APP_NAME.app" "$DMG_DIR/"
        ln -s /Applications "$DMG_DIR/Applications"
        rm -f "$dmg_path"
        diskutil image create from \
            --volumeName "$APP_NAME $VERSION" \
            --format UDZO \
            "$DMG_DIR" "$dmg_path"
        rm -rf "$DMG_DIR"
    fi

    [ -f "$dmg_path" ] || { error "DMG creation failed!"; return 1; }
    
    # Step 5: Sign DMG if we have Developer ID
    if [ -n "$DEVELOPER_ID" ] && [ "$DEVELOPER_ID" != "-" ]; then
        info "Signing DMG..."
        codesign --force --sign "$DEVELOPER_ID" "$dmg_path"
        
        if [ "$BYPASS_NOTARY" = false ]; then
            notarize "$dmg_path" "DMG" || return 1
        else
            warning "Skipping DMG notarization (signed but not notarized)"
        fi
    else
        warning "DMG not signed (using free developer account)"
    fi
    
    # Generate checksum
    cd "$BUILD_DIR" && shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256" && cd - >/dev/null
    
    # Cleanup
    rm -rf "$archive_path" "$export_path" "$error_log" "$BUILD_DIR/exportOptions.plist"
    
    log "$display_name installer created: $dmg_path"
    return 0
}

# Create an unsigned DMG for local use without archive/export/signing/notarization
create_local_installer() {
    local arch="$1"
    local suffix="$2"
    local display_name="$3"

    log "Building unsigned local $display_name version..."

    local derived_data="$BUILD_DIR/DerivedData-$suffix"
    local export_path="$BUILD_DIR/local-$suffix"
    local dmg_path="$BUILD_DIR/${APP_NAME}-${VERSION}-$suffix-local.dmg"
    local error_log="$BUILD_DIR/build-local-$suffix.log"

    info "Building app for $display_name without code signing..."
    run_local_build "$error_log" "$arch" "$derived_data"

    local products_dir="$derived_data/Build/Products/$CONFIGURATION"
    local built_app=""
    built_app=$(find "$products_dir" -maxdepth 1 -name "*.app" -type d | head -n 1)

    if [ -z "$built_app" ] || [ ! -d "$built_app" ]; then
        error "Local build failed for $display_name! Check $error_log for details"
        grep -E "(error:|ERROR:|failed|FAILED)" "$error_log" 2>/dev/null | tail -10
        return 1
    fi

    rm -rf "$export_path"
    mkdir -p "$export_path"
    ditto "$built_app" "$export_path/$APP_NAME.app"

    info "Creating unsigned local DMG for $display_name..."
    if command -v create-dmg >/dev/null 2>&1; then
        local dmg_title="$APP_NAME $VERSION Local"
        [ "$suffix" != "Universal" ] && dmg_title="$APP_NAME-$suffix Local"
        local dmg_source="$BUILD_DIR/dmg-source-$suffix-local"
        prepare_dmg_source "$export_path/$APP_NAME.app" "$dmg_source"
        create_dmg_with_layout "$dmg_title" "$dmg_path" "$dmg_source" || {
            error "create-dmg failed"
            return 1
        }
        rm -rf "$dmg_source"
    else
        local dmg_dir="$BUILD_DIR/dmg-$suffix"
        rm -rf "$dmg_dir"
        mkdir -p "$dmg_dir"
        cp -R "$export_path/$APP_NAME.app" "$dmg_dir/"
        ln -s /Applications "$dmg_dir/Applications"
        rm -f "$dmg_path"
        diskutil image create from \
            --volumeName "$APP_NAME $VERSION Local" \
            --format UDZO \
            "$dmg_dir" "$dmg_path"
        rm -rf "$dmg_dir"
    fi

    [ -f "$dmg_path" ] || { error "DMG creation failed!"; return 1; }

    (cd "$BUILD_DIR" && shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256")

    rm -rf "$derived_data" "$export_path" "$error_log"

    log "$display_name local installer created: $dmg_path"
    return 0
}

# Print usage
print_usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --version <version>  Specify version number (e.g., 1.0.0)"
    echo "  --verbose           Show full build output"
    echo "  --universal         Build universal binary (default)"
    echo "  --intel-only        Build Intel-only installer"
    echo "  --arm-only          Build Apple Silicon-only installer"
    echo "  --separate          Build separate Intel and Apple Silicon installers"
    echo "  --local             Build unsigned local DMG without signing or notarization"
    echo "                      Defaults to this Mac's architecture unless an arch option is set"
    echo "  --bypass-notary     Skip notarization (still signs with Developer ID)"
    echo "  --help              Show this help message"
}

# Print bypass instructions
print_bypass_instructions() {
    if [ -n "$DEVELOPER_ID" ] && [ "$DEVELOPER_ID" != "-" ]; then
        # Instructions for Developer ID signed but not notarized
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  Signed but Not Notarized - Testing Build${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        
        echo -e "This build is signed with your Developer ID but not notarized."
        echo -e "Users will see an 'unidentified developer' warning.\n"
        
        echo -e "${GREEN}To install:${NC}"
        echo -e "  1. Right-click the DMG → Open"
        echo -e "  2. Click 'Open' in the warning dialog"
        echo -e "  3. Drag Petrichor to Applications"
        echo -e "  4. Right-click Petrichor.app → Open"
        echo -e "  5. Click 'Open' in the warning dialog\n"
    else
        # Instructions for free account development build
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  Development Build - Free Account${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        
        echo -e "${RED}IMPORTANT LIMITATIONS:${NC}"
        echo -e "  • This app will ${RED}expire after 7 days${NC}"
        echo -e "  • It may only work on this machine"
        echo -e "  • Cannot be shared with other users\n"
        
        echo -e "${GREEN}To install:${NC}"
        echo -e "  1. Open the DMG"
        echo -e "  2. Drag Petrichor to Applications"
        echo -e "  3. Open Petrichor from Applications"
        echo -e "  4. If blocked, go to System Settings → Privacy & Security"
        echo -e "  5. Click 'Open Anyway'\n"
        
        echo -e "${YELLOW}After 7 days:${NC} You'll need to rebuild the app with this script.\n"
    fi
    
    echo -e "${YELLOW}Note:${NC} This build is for testing only, not for distribution to end users.\n"
}

# Print local package instructions
print_local_instructions() {
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️  Unsigned Local Build${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    echo -e "This DMG is unsigned and not notarized. It is intended for this Mac only.\n"

    echo -e "${GREEN}To install:${NC}"
    echo -e "  1. Open the DMG"
    echo -e "  2. Drag Petrichor to Applications"
    echo -e "  3. If macOS blocks launch, right-click Petrichor.app and choose Open"
    echo -e "  4. If still blocked, go to System Settings → Privacy & Security and click Open Anyway\n"
}

# Parse arguments
VERSION=""
VERBOSE=false
BUILD_UNIVERSAL=true
BUILD_INTEL=false
BUILD_ARM=false
BYPASS_NOTARY=false
LOCAL_PACKAGE=false
ARCH_OPTION_SET=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) VERSION="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        --universal) BUILD_UNIVERSAL=true; BUILD_INTEL=false; BUILD_ARM=false; ARCH_OPTION_SET=true; shift ;;
        --intel-only) BUILD_INTEL=true; BUILD_UNIVERSAL=false; BUILD_ARM=false; ARCH_OPTION_SET=true; shift ;;
        --arm-only) BUILD_ARM=true; BUILD_UNIVERSAL=false; BUILD_INTEL=false; ARCH_OPTION_SET=true; shift ;;
        --separate) BUILD_UNIVERSAL=false; BUILD_INTEL=true; BUILD_ARM=true; ARCH_OPTION_SET=true; shift ;;
        --local) LOCAL_PACKAGE=true; BYPASS_NOTARY=true; shift ;;
        --bypass-notary) BYPASS_NOTARY=true; shift ;;
        --help) print_usage; exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$LOCAL_PACKAGE" = true ] && [ "$ARCH_OPTION_SET" = false ]; then
    BUILD_UNIVERSAL=false
    if [ "$(uname -m)" = "arm64" ]; then
        BUILD_ARM=true
    else
        BUILD_INTEL=true
    fi
fi

# Validate environment variables based on mode
if [ "$LOCAL_PACKAGE" = true ]; then
    warning "Local packaging mode - building unsigned DMG without signing or notarization"
elif [ "$BYPASS_NOTARY" = false ]; then
    # Full notarization requires Developer ID
    if [ -z "$TEAM_ID" ] || [ -z "$DEVELOPER_ID" ]; then
        error "Missing required environment variables for notarization!"
        echo ""
        echo "Please set the following environment variables:"
        echo "  export PETRICHOR_TEAM_ID=\"your-team-id\""
        echo "  export PETRICHOR_DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
        echo ""
        echo "Example:"
        echo "  export PETRICHOR_TEAM_ID=\"ABCD1234XY\""
        echo "  export PETRICHOR_DEVELOPER_ID=\"Developer ID Application: John Doe (ABCD1234XY)\""
        echo ""
        echo "Or run with --bypass-notary to skip notarization"
        exit 1
    fi
else
    # Bypass mode - check if we have Developer ID, otherwise use free account
    if [ -z "$TEAM_ID" ] || [ -z "$DEVELOPER_ID" ]; then
        warning "No Developer ID found - will use free Apple Developer account"
        warning "⚠️  The app will be signed with a development certificate that:"
        warning "   • Expires after 7 days"
        warning "   • May only work on this machine"
        warning "   • Cannot be distributed to other users"
        echo ""
        echo "This is suitable for personal use and testing only."
        echo ""
        read -p "Continue with development signing? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        TEAM_ID=""
        DEVELOPER_ID=""
    else
        info "Using Developer ID for signing (without notarization)"
    fi
fi

# Check for notarization credentials (skip if bypassing)
if [ "$BYPASS_NOTARY" = false ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
        error "Notarization credentials not found!"
        error "Please run: xcrun notarytool store-credentials '$NOTARY_PROFILE'"
        error "  --apple-id 'your-apple-id@email.com'"
        error "  --team-id '$TEAM_ID'"
        error "  --password 'your-app-specific-password'"
        exit 1
    fi
else
    if [ "$LOCAL_PACKAGE" = true ]; then
        warning "Bypassing signing and notarization for local package"
    else
        warning "Bypassing notarization - app will be signed but not notarized"
    fi
fi

# Check requirements
check_requirements

# Detect version if not specified
if [ -z "$VERSION" ]; then
    # Get the last tag
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    
    if [ -n "$LAST_TAG" ]; then
        # Check if HEAD is at the tag
        TAG_COMMIT=$(git rev-list -n 1 "$LAST_TAG" 2>/dev/null)
        HEAD_COMMIT=$(git rev-parse HEAD 2>/dev/null)
        
        if [ "$TAG_COMMIT" = "$HEAD_COMMIT" ]; then
            # No commits since tag, use tag version
            VERSION="${LAST_TAG#v}"  # Remove 'v' prefix if present
            log "At tag $LAST_TAG, using version: $VERSION"
        else
            # Commits exist after tag, use dev version
            SHORT_SHA=$(git rev-parse --short=8 HEAD)
            VERSION="dev-${SHORT_SHA}"
            log "Commits found after $LAST_TAG, using development version: $VERSION"
        fi
    else
        # No tags found, use dev version
        SHORT_SHA=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        VERSION="dev-${SHORT_SHA}"
        log "No tags found, using development version: $VERSION"
    fi
fi

# Calculate production build number from version string
get_production_build_number() {
    local version="$1"
    # Remove any 'v' prefix and extract numbers
    local clean_version="${version#v}"
    IFS='.' read -r major minor patch <<< "$clean_version"
    # Default to 0 if patch is empty
    patch=${patch:-0}
    echo "$((major * 100 + minor * 10 + patch))"
}

# Determine build number from version
if [[ "$VERSION" == *"beta"* ]]; then
    # For beta versions, use build number 1-99
    # Extract beta number if present (e.g., 1.0.0-beta-4 becomes 4)
    if [[ "$VERSION" =~ beta-([0-9]+) ]]; then
        BUILD_NUMBER="${BASH_REMATCH[1]}"
    else
        BUILD_NUMBER="1"
    fi
    log "Beta version detected, using build number: $BUILD_NUMBER"
elif [[ "$VERSION" == "dev"* ]]; then
    # For dev versions, use last production build number
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    if [ -n "$LAST_TAG" ]; then
        BUILD_NUMBER=$(get_production_build_number "$LAST_TAG")
        log "Development version, using build number from tag $LAST_TAG: $BUILD_NUMBER"
    else
        # No tags found, fallback to build 1
        BUILD_NUMBER="1"
        log "Development version, no tags found, using build number: $BUILD_NUMBER"
    fi
else
    # For stable versions, use production build number based on latest tag
    BUILD_NUMBER=$(get_production_build_number "$VERSION")
    log "Stable version detected, calculated build number: $BUILD_NUMBER"
fi

# Setup paths
BUILD_DIR="$PWD/build"

# Prepare build directory
log "Building $APP_NAME version $VERSION (Build $BUILD_NUMBER)"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

# Build based on selected options
if [ "$LOCAL_PACKAGE" = true ]; then
    [ "$BUILD_UNIVERSAL" = true ] && create_local_installer "x86_64 arm64" "Universal" "Universal"
    [ "$BUILD_INTEL" = true ] && [ "$BUILD_UNIVERSAL" = false ] && create_local_installer "x86_64" "Intel" "Intel"
    [ "$BUILD_ARM" = true ] && [ "$BUILD_UNIVERSAL" = false ] && create_local_installer "arm64" "AppleSilicon" "Apple Silicon"
else
    [ "$BUILD_UNIVERSAL" = true ] && create_installer "x86_64 arm64" "Universal" "Universal"
    [ "$BUILD_INTEL" = true ] && [ "$BUILD_UNIVERSAL" = false ] && create_installer "x86_64" "Intel" "Intel"
    [ "$BUILD_ARM" = true ] && [ "$BUILD_UNIVERSAL" = false ] && create_installer "arm64" "AppleSilicon" "Apple Silicon"
fi

# Summary
echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Build completed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# List all created DMGs
for dmg in "$BUILD_DIR"/*.dmg; do
    if [ -f "$dmg" ]; then
        echo -e "📦 $(basename "$dmg")"
        echo -e "   📱 Version: ${GREEN}$VERSION${NC} (Build ${GREEN}$BUILD_NUMBER${NC})"
        echo -e "   📏 Size: ${GREEN}$(du -h "$dmg" | cut -f1)${NC}"
        echo -e "   📋 SHA256: ${GREEN}$(cat "$dmg.sha256" | awk '{print $1}')${NC}"
        if [ "$BYPASS_NOTARY" = true ]; then
            if [ "$LOCAL_PACKAGE" = true ]; then
                echo -e "   ⚠️  ${YELLOW}Unsigned local build${NC}"
            elif [ -n "$DEVELOPER_ID" ] && [ "$DEVELOPER_ID" != "-" ]; then
                echo -e "   ⚠️  ${YELLOW}Signed but not notarized${NC}"
            else
                echo -e "   ⚠️  ${YELLOW}Development build (expires in 7 days)${NC}"
            fi
        else
            echo -e "   ✅ Notarized and ready for distribution"
        fi
        echo ""
    fi
done

# Show bypass instructions if applicable
if [ "$LOCAL_PACKAGE" = true ]; then
    print_local_instructions
elif [ "$BYPASS_NOTARY" = true ]; then
    print_bypass_instructions
fi

# GitHub Actions outputs (for the first DMG found)
if [ -n "$GITHUB_ACTIONS" ]; then
    for dmg in "$BUILD_DIR"/*.dmg; do
        if [ -f "$dmg" ]; then
            {
                echo "dmg-path=$dmg"
                echo "dmg-name=$(basename "$dmg")"
                echo "version=$VERSION"
                echo "sha256=$(cat "$dmg.sha256" | awk '{print $1}')"
            } >> "$GITHUB_OUTPUT"
            break
        fi
    done
fi

log "Done!"
