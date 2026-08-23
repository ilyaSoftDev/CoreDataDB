#!/usr/bin/env bash
#
# conventional.sh
# CoreDataDB
#
# Shared Conventional Commits parser, sourced by next-version.sh and
# release-notes.sh.
#
# It lives in one file on purpose. The version bump and the release notes are
# two readings of the same commit range, and if they were parsed separately a
# drift between them would ship a release whose notes contradict its version
# number — a "Features" section under a patch bump, say. Sourcing one parser
# makes that class of bug unrepresentable rather than merely unlikely.
#
# Written for bash 3.2, which is what /bin/bash is on macOS and therefore on
# the macos-26 runner: no associative arrays, no ${var,,} case expansion.

set -euo pipefail

# The commit types recognised in a subject line. Anything outside this list is
# not a conventional commit at all and is ignored for both purposes.
CC_TYPES="feat fix docs style refactor perf test build ci chore revert"

# ―― cc_last_tag ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# Echoes the most recent reachable tag, or nothing when the repository has none.
#
# Tags here are bare "1.2.3" with no `v` prefix. That is not a style choice: the
# podspec resolves `:tag => "#{spec.version}"`, so a `v` would make every
# `pod trunk push` look for a tag that does not exist.

cc_last_tag() {
    git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true
}

# ―― cc_commits ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# Echoes one commit SHA per line for the range, oldest first.
#
# Merge commits are excluded. Their subjects ("Merge pull request #12 from …")
# never carry a conventional prefix, and counting them would let the merge
# strategy influence the version number.

cc_commits() {
    local from="$1" to="$2"
    if [ -n "$from" ]; then
        git rev-list --reverse --no-merges "${from}..${to}"
    else
        git rev-list --reverse --no-merges "$to"
    fi
}

# ―― cc_parse_subject ―――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# Parses a subject line, plus an optional body, into
# `type|breaking|scope|description` on stdout. Echoes nothing and returns 1 when
# the subject is not a conventional commit.
#
#   feat(batch)!: drop the upsert path   ->  feat|yes|batch|drop the upsert path
#   fix: honour the merge policy         ->  fix|no||honour the merge policy
#
# Breaking changes are detected two ways, both from the Conventional Commits
# spec: a `!` before the colon, or a `BREAKING CHANGE:` / `BREAKING-CHANGE:`
# footer in the body. The footer form is the only way to describe the break at
# length, so ignoring it would quietly demote a major release to a minor one.
#
# Taking the subject as a string rather than a SHA is what lets the PR-title
# gate in ci.yml enforce exactly the grammar the release job later parses. If
# the two drifted, a PR could pass the gate and then produce no release.

cc_parse_subject() {
    local subject="$1" body="${2:-}"
    local type scope breaking description

    if [[ ! "$subject" =~ ^([a-zA-Z]+)(\(([^\)]*)\))?(!)?:[[:space:]]+(.+)$ ]]; then
        return 1
    fi

    type=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    scope="${BASH_REMATCH[3]}"
    breaking="no"
    description="${BASH_REMATCH[5]}"

    case " $CC_TYPES " in
        *" $type "*) ;;
        *) return 1 ;;
    esac

    if [ -n "${BASH_REMATCH[4]}" ]; then
        breaking="yes"
    elif [ -n "$body" ] && printf '%s' "$body" | grep -qE '^BREAKING[ -]CHANGE:'; then
        breaking="yes"
    fi

    printf '%s|%s|%s|%s\n' "$type" "$breaking" "$scope" "$description"
}

# ―― cc_parse ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# cc_parse_subject for a commit, read out of git.

cc_parse() {
    local sha="$1" subject body

    subject=$(git log -1 --format='%s' "$sha")
    body=$(git log -1 --format='%b' "$sha")

    cc_parse_subject "$subject" "$body"
}

# ―― cc_bump ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# Echoes the bump the range calls for: major, minor, patch, or none.
#
# Precedence is major > minor > patch. `none` means the range holds no feat,
# no fix and no breaking change — a docs- or chore-only range — and the caller
# is expected to skip the release rather than invent a patch bump for it.

cc_bump() {
    local from="$1" to="$2"
    local sha parsed type breaking
    local result="none"

    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        parsed=$(cc_parse "$sha") || continue

        type=$(printf '%s' "$parsed" | cut -d'|' -f1)
        breaking=$(printf '%s' "$parsed" | cut -d'|' -f2)

        if [ "$breaking" = "yes" ]; then
            echo "major"
            return 0
        fi

        if [ "$type" = "feat" ]; then
            result="minor"
        elif [ "$type" = "fix" ] && [ "$result" != "minor" ]; then
            result="patch"
        fi
    done <<< "$(cc_commits "$from" "$to")"

    echo "$result"
}

# ―― cc_apply_bump ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
#
# Echoes `version` advanced by `bump`. A base with no tag yet starts at 0.0.0,
# so the first feat release of an untagged repository is 0.1.0.

cc_apply_bump() {
    local version="$1" bump="$2"
    local major minor patch

    major=$(printf '%s' "$version" | cut -d. -f1)
    minor=$(printf '%s' "$version" | cut -d. -f2)
    patch=$(printf '%s' "$version" | cut -d. -f3)

    case "$bump" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) return 1 ;;
    esac

    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}
