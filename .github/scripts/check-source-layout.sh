#!/usr/bin/env bash
#
# check-source-layout.sh
# CoreDataDB
#
# Asserts that every Swift source ships in exactly one subspec.
#
# Splitting Core from Combine replaced one glob that matched everything under
# CoreDataDB/ with two that match only CoreDataDB/Core/ and CoreDataDB/Combine/,
# and Package.swift's targets are rooted at those same two folders. That opened
# a hole nothing else can see: a file added directly under CoreDataDB/, or under
# a third folder beside those two, is still compiled by the Xcode framework
# target — its synchronized group is rooted at CoreDataDB/ and takes everything
# below — while belonging to no subspec and no SPM target at all.
#
# The result builds green locally and ships from neither package. `pod lib lint`
# and `swift build` only catch it when the missing file breaks a compile; new
# public API in an orphaned file compiles clean everywhere and simply does not
# exist for anyone who consumes this as a pod or a package.
#
# The globs are read out of the podspec rather than hardcoded, so re-cutting the
# subspecs updates this check with them. Package.swift's target paths are the
# same two folders by construction — the note above `targets:` there says so —
# which is why checking one file settles both.
#
# Also fails on a file matched by two globs, which would compile it twice in a
# build taking both subspecs, and on a reference from Core into Combine. The
# latter is what the isolated `[CoreDataDB/Core]` lint proves properly; this is
# a fail-fast that names the cause in seconds instead of minutes.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

podspec="CoreDataDB.podspec"
sources="CoreDataDB"

# "CoreDataDB/Core/**/*.swift" -> "CoreDataDB/Core". Only the recursive form is
# understood; a glob spelled any other way is reported rather than ignored,
# because silently skipping one would defeat the whole check.
prefixes=""
while IFS= read -r glob; do
    case "$glob" in
        */\*\*/\*.swift)
            prefixes="$prefixes ${glob%/\*\*/\*.swift}"
            ;;
        *)
            echo "::error::$podspec has a source_files glob this check cannot read: $glob"
            echo "Teach check-source-layout.sh the new spelling, or the subspec it covers is unguarded."
            exit 1
            ;;
    esac
done < <(grep -oE '\.source_files[[:space:]]*=[[:space:]]*"[^"]+"' "$podspec" |
         sed -E 's/.*"([^"]+)"/\1/')

if [ -z "$prefixes" ]; then
    echo "::error::no source_files globs found in $podspec"
    exit 1
fi

echo "subspec source roots:$prefixes"
echo ""

status=0

while IFS= read -r file; do
    matches=0
    for prefix in $prefixes; do
        case "$file" in
            "$prefix"/*) matches=$((matches + 1)) ;;
        esac
    done

    case "$matches" in
        1) ;;
        0)
            echo "::error file=$file::$file is in no subspec and no SPM target — the Xcode framework compiles it, the pod and the package do not ship it."
            status=1
            ;;
        *)
            echo "::error file=$file::$file is matched by $matches subspec globs and would be compiled more than once."
            status=1
            ;;
    esac
done < <(find "$sources" -name '*.swift' -type f | sort)

# Direction of the dependency. Core is the default subspec and has to build
# with Combine absent; Combine depends on Core, never the reverse.
if grep -rlE '^[[:space:]]*(@[a-zA-Z_(), ]+[[:space:]]+)?import[[:space:]]+Combine' "$sources/Core" 2>/dev/null; then
    echo "::error::the files above are in Core but import Combine — the Core subspec cannot build alone."
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "Every Swift source is covered by exactly one subspec, and Core does not depend on Combine."
fi

exit "$status"
