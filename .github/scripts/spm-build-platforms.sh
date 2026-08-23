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
# where xcodebuild resolves it as a package and synthesises a scheme per
# product. This validates the manifest's platform declarations, which is the
# part the framework target's own iOS/visionOS builds do not cover.
#
# Every product is built, not just the first: the package declares one per tier
# — CoreDataDB and CoreDataDBCombine — and `-scheme CoreDataDB` alone would
# build the async tier and silently skip the Combine one. The list is read back
# out of xcodebuild rather than hardcoded, so adding a product extends this
# check by itself. The `<name>-Package` aggregate is dropped: it adds the test
# target, which drags XCTest onto platforms this is only meant to compile for.

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

schemes=$(xcodebuild -list | awk '/Schemes:/ { in_list = 1; next } in_list && NF { print $1 }' |
          grep -v -- '-Package$' || true)

if [ -z "$schemes" ]; then
    echo "::error::no product schemes found for the staged package." >&2
    exit 1
fi

echo "products:" $schemes

status=0
for destination in \
    'generic/platform=iOS Simulator' \
    'generic/platform=visionOS Simulator'
do
    for scheme in $schemes; do
        echo ""
        echo "――― $scheme — $destination ―――"
        if xcodebuild -scheme "$scheme" -destination "$destination" build; then
            echo "OK: $scheme — $destination"
        else
            echo "::error::$scheme failed to build for $destination"
            status=1
        fi
    done
done

exit "$status"
