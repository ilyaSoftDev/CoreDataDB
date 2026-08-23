#!/usr/bin/env bash
#
# check-platform-sync.sh
# CoreDataDB
#
# Asserts that the three declarations of the deployment floor agree.
#
# Adding Package.swift made a third copy of a number that already existed twice:
# the Xcode target's *_DEPLOYMENT_TARGET settings and the podspec's
# deployment_target entries. Nothing links them, and a drift is close to
# invisible — the build that uses the stale copy simply targets a different OS,
# and only a consumer on that OS finds out.
#
# Compares iOS, macOS and visionOS across all three and exits non-zero on any
# disagreement.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

pbxproj="CoreDataDB.xcodeproj/project.pbxproj"
podspec="CoreDataDB.podspec"
manifest="Package.swift"

# Each build configuration repeats the setting, so take the unique set and
# object if a file disagrees with itself as well.
from_pbxproj() {
    grep -oE "$1 = [0-9.]+;" "$pbxproj" | sed -E "s/$1 = ([0-9.]+);/\1/" | sort -u
}

from_podspec() {
    grep -oE "spec\.$1\.deployment_target[[:space:]]*=[[:space:]]*\"[0-9.]+\"" "$podspec" |
        sed -E 's/.*"([0-9.]+)"/\1/' | sort -u
}

from_manifest() {
    grep -oE "\.$1\(\"[0-9.]+\"\)" "$manifest" | sed -E 's/.*"([0-9.]+)".*/\1/' | sort -u
}

single() {
    local label="$1" value="$2"
    local count
    count=$(printf '%s\n' "$value" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
        echo "::error::$label declares $count different values: $(printf '%s' "$value" | tr '\n' ' ')"
        return 1
    fi
    printf '%s' "$value"
}

status=0
printf '%-10s %-12s %-12s %-12s %s\n' PLATFORM XCODE PODSPEC PACKAGE ""

check() {
    local name="$1" pbx_key="$2" pod_key="$3" pkg_key="$4"
    local x p k

    x=$(single "$pbx_key" "$(from_pbxproj "$pbx_key")") || { status=1; return; }
    p=$(single "podspec $pod_key" "$(from_podspec "$pod_key")") || { status=1; return; }
    k=$(single "Package.swift $pkg_key" "$(from_manifest "$pkg_key")") || { status=1; return; }

    if [ "$x" = "$p" ] && [ "$p" = "$k" ]; then
        printf '%-10s %-12s %-12s %-12s %s\n' "$name" "$x" "$p" "$k" "ok"
    else
        printf '%-10s %-12s %-12s %-12s %s\n' "$name" "$x" "$p" "$k" "MISMATCH"
        echo "::error::$name deployment target differs: Xcode=$x podspec=$p Package.swift=$k"
        status=1
    fi
}

check iOS      IPHONEOS_DEPLOYMENT_TARGET ios      iOS
check macOS    MACOSX_DEPLOYMENT_TARGET   osx      macOS
check visionOS XROS_DEPLOYMENT_TARGET     visionos visionOS

if [ "$status" -eq 0 ]; then
    echo ""
    echo "All three declarations agree."
fi

exit "$status"
