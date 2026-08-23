#!/usr/bin/env bash
#
# spm-build-platforms.sh
# CoreDataDB
#
# Builds the Swift package for the platforms `swift build` cannot reach.
#
#   .github/scripts/spm-build-platforms.sh
#
# `swift build` only ever builds for the host, so on a macOS runner it proves
# nothing about the iOS and visionOS platforms Package.swift declares. Building
# those needs xcodebuild — and xcodebuild cannot see the package while
# CoreDataDB.xcodeproj sits beside it in the repository root: given a directory
# containing both, it opens the project and the package is ignored. Passing
# -project does not help, because the goal here is specifically NOT to build the
# project.
#
# So the package is staged into a scratch directory without the .xcodeproj,
# where xcodebuild resolves it as a package and synthesises a scheme for it.
# This validates the manifest's platform declarations, which is the part the
# framework target's own iOS/visionOS builds do not cover.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

cp "$repo_root/Package.swift" "$staging/"
cp -R "$repo_root/CoreDataDB" "$repo_root/CoreDataDBTests" "$staging/"

cd "$staging"

# Fail loudly if the staging ever stops working, rather than silently building
# whatever else xcodebuild decides to find.
if ls -d ./*.xcodeproj >/dev/null 2>&1; then
    echo "error: staging directory unexpectedly contains an Xcode project." >&2
    exit 1
fi

status=0
for destination in \
    'generic/platform=iOS Simulator' \
    'generic/platform=visionOS Simulator'
do
    echo ""
    echo "――― $destination ―――"
    if xcodebuild -scheme CoreDataDB -destination "$destination" build; then
        echo "OK: $destination"
    else
        echo "::error::Swift package failed to build for $destination"
        status=1
    fi
done

exit "$status"
