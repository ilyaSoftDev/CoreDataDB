#!/usr/bin/env bash
#
# release-notes.sh
# CoreDataDB
#
# Renders release notes from the same commit range the version bump was
# computed from.
#
#   .github/scripts/release-notes.sh [FROM_REF] [TO_REF] [VERSION]
#
# Emits markdown on stdout: a Breaking changes / Features / Fixes section for
# whichever of the three the range contains, then a compare link. Commits of
# other types (docs, chore, ci, …) are deliberately omitted — they are in the
# history for anyone who wants them, and listing them buries the two or three
# lines a reader actually came for.
#
# The AI summary the release workflow generates is prepended above this output,
# never merged into it, so the generated prose and the mechanical list stay
# visibly separate.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=conventional.sh
. "$script_dir/conventional.sh"

from_ref="${1:-}"
to_ref="${2:-HEAD}"
version="${3:-}"

if [ -z "$from_ref" ]; then
    from_ref=$(cc_last_tag)
fi

repo_url="https://github.com/ilyaSoftDev/CoreDataDB"

breaking=""
features=""
fixes=""

# ―― Collect ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# A breaking commit is filed under Breaking changes regardless of its type, so
# `feat!:` appears once at the top rather than twice.

while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    parsed=$(cc_parse "$sha") || continue

    type=$(printf '%s' "$parsed" | cut -d'|' -f1)
    is_breaking=$(printf '%s' "$parsed" | cut -d'|' -f2)
    scope=$(printf '%s' "$parsed" | cut -d'|' -f3)
    description=$(printf '%s' "$parsed" | cut -d'|' -f4-)

    short=$(git rev-parse --short "$sha")

    if [ -n "$scope" ]; then
        line="- **${scope}:** ${description} (${short})"
    else
        line="- ${description} (${short})"
    fi

    if [ "$is_breaking" = "yes" ]; then
        breaking="${breaking}${line}"$'\n'
    elif [ "$type" = "feat" ]; then
        features="${features}${line}"$'\n'
    elif [ "$type" = "fix" ]; then
        fixes="${fixes}${line}"$'\n'
    fi
done <<< "$(cc_commits "$from_ref" "$to_ref")"

# ―― Render ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

if [ -n "$breaking" ]; then
    printf '### Breaking changes\n\n%s\n' "$breaking"
fi

if [ -n "$features" ]; then
    printf '### Features\n\n%s\n' "$features"
fi

if [ -n "$fixes" ]; then
    printf '### Fixes\n\n%s\n' "$fixes"
fi

if [ -n "$from_ref" ] && [ -n "$version" ]; then
    printf '**Full Changelog**: %s/compare/%s...%s\n' "$repo_url" "$from_ref" "$version"
fi
