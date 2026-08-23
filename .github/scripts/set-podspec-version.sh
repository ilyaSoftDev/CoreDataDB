#!/usr/bin/env bash
#
# set-podspec-version.sh
# CoreDataDB
#
# Rewrites `spec.version` in a podspec.
#
#   .github/scripts/set-podspec-version.sh 1.1.0 [PODSPEC]
#
# A separate script rather than an inline sed because a silent no-op here is the
# worst failure in the release pipeline: the tag would say 1.1.0, the podspec
# would still say 1.0.0, and `pod trunk push` would publish a version whose
# source tag does not exist. So the rewrite is verified by reading the value
# back, and the script exits non-zero if it did not take.
#
# Written to a temp file and moved rather than using `sed -i`, whose in-place
# spelling differs between BSD and GNU sed.

set -euo pipefail

version="${1:-}"
podspec="${2:-CoreDataDB.podspec}"

if [ -z "$version" ]; then
    echo "usage: set-podspec-version.sh <version> [podspec]" >&2
    exit 1
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$version' is not a bare X.Y.Z version." >&2
    exit 1
fi

if [ ! -f "$podspec" ]; then
    echo "error: no such podspec: $podspec" >&2
    exit 1
fi

current=$(grep -E '^[[:space:]]*spec\.version[[:space:]]*=' "$podspec" |
          head -1 |
          sed -E 's/.*"([^"]*)".*/\1/')

if [ -z "$current" ]; then
    echo "error: no 'spec.version = \"...\"' line found in $podspec" >&2
    exit 1
fi

tmp=$(mktemp)
sed -E "s|^([[:space:]]*spec\.version[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"${version}\"|" \
    "$podspec" > "$tmp"
mv "$tmp" "$podspec"

written=$(grep -E '^[[:space:]]*spec\.version[[:space:]]*=' "$podspec" |
          head -1 |
          sed -E 's/.*"([^"]*)".*/\1/')

if [ "$written" != "$version" ]; then
    echo "error: rewrite did not take — $podspec still reads '$written', expected '$version'." >&2
    exit 1
fi

echo "$podspec: $current -> $version"
