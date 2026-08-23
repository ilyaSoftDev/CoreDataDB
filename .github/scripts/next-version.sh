#!/usr/bin/env bash
#
# next-version.sh
# CoreDataDB
#
# Computes the next semantic version from the Conventional Commits in a range.
#
#   .github/scripts/next-version.sh [FROM_REF] [TO_REF]
#
# FROM_REF defaults to the most recent version tag and TO_REF to HEAD, which is
# the release job's case. Both are accepted explicitly so the calculation can be
# dry-run against any historical range without cutting a tag.
#
# Prints the version on stdout, or the literal `none` when the range holds
# nothing releasable. `none` is a successful outcome, not an error: a range of
# docs and chores should end the release job quietly, and exiting non-zero
# would paint the run red for having correctly decided to do nothing.
#
# When $GITHUB_OUTPUT is set the same values are written there as `version` and
# `bump`, so the workflow can branch on them without re-parsing stdout.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=conventional.sh
. "$script_dir/conventional.sh"

from_ref="${1:-}"
to_ref="${2:-HEAD}"

if [ -z "$from_ref" ]; then
    from_ref=$(cc_last_tag)
fi

# No tag at all means every commit is in range and the base is 0.0.0. The repo
# has tag 1.0.0 today, so this branch is for a fresh clone of a stripped history.
if [ -n "$from_ref" ]; then
    base_version="$from_ref"
else
    base_version="0.0.0"
fi

bump=$(cc_bump "$from_ref" "$to_ref")

if [ "$bump" = "none" ]; then
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            echo "version=none"
            echo "bump=none"
        } >> "$GITHUB_OUTPUT"
    fi
    echo "none"
    exit 0
fi

next=$(cc_apply_bump "$base_version" "$bump")

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$next"
        echo "bump=$bump"
        echo "previous=${from_ref:-none}"
    } >> "$GITHUB_OUTPUT"
fi

echo "$next"
