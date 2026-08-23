#!/usr/bin/env bash
#
# select-xcode.sh
# CoreDataDB
#
# Pins the Xcode the CI jobs build with.
#
# The project's deployment targets are 26.5 across iOS, macOS and visionOS, so
# the toolchain has to carry at least the 26.5 SDKs. The macos-26 runner image
# ships several Xcodes and its *default* moves without warning — it changed
# twice in 2026 — so relying on whatever `xcode-select -p` happens to point at
# makes the build's floor a property of the image rather than of this repo.
#
# Preference order, first match wins. 26.6 is what the framework is developed
# against locally; 26.5 is the oldest that still carries the required SDKs.
#
# This is a plain xcode-select rather than a third-party setup action: it is two
# lines of shell, and it keeps a supply-chain dependency out of a proprietary
# repository's build.

set -euo pipefail

PREFERRED="26.6 26.5"
REQUIRED_SDK_MAJOR=26
REQUIRED_SDK_MINOR=5

selected=""
for version in $PREFERRED; do
    candidate="/Applications/Xcode_${version}.app"
    if [ -d "$candidate" ]; then
        selected="$candidate"
        break
    fi
done

if [ -n "$selected" ]; then
    echo "Selecting $selected"
    sudo xcode-select -s "$selected"
else
    echo "::warning::None of Xcode $PREFERRED found on this runner; using the image default."
    echo "Installed Xcodes:"
    ls -d /Applications/Xcode*.app 2>/dev/null || echo "  (none)"
fi

xcodebuild -version

# Fail here, with a sentence explaining why, rather than several minutes later
# inside a compile with an unavailability error that does not name the cause.
sdk=$(xcrun --sdk macosx --show-sdk-version)
sdk_major=$(printf '%s' "$sdk" | cut -d. -f1)
sdk_minor=$(printf '%s' "$sdk" | cut -d. -f2)

if [ "$sdk_major" -lt "$REQUIRED_SDK_MAJOR" ] ||
   { [ "$sdk_major" -eq "$REQUIRED_SDK_MAJOR" ] && [ "${sdk_minor:-0}" -lt "$REQUIRED_SDK_MINOR" ]; }; then
    echo "::error::macOS SDK $sdk is older than the ${REQUIRED_SDK_MAJOR}.${REQUIRED_SDK_MINOR} deployment target this project sets."
    exit 1
fi

echo "macOS SDK $sdk satisfies the ${REQUIRED_SDK_MAJOR}.${REQUIRED_SDK_MINOR} deployment target."
