#!/usr/bin/env bash
#
# check-subject.sh
# CoreDataDB
#
# Validates one subject line against the Conventional Commits grammar.
#
#   .github/scripts/check-subject.sh "feat(combine): add observe publishers"
#
# Used by the pr-title job in ci.yml. It shares conventional.sh with the release
# job on purpose: the gate has to enforce exactly the grammar the release job
# parses, or a PR could pass review and then silently produce no release.
#
# Exits 0 when the subject conforms, 1 with an explanation when it does not.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=conventional.sh
. "$script_dir/conventional.sh"

subject="${1:-}"

if [ -z "$subject" ]; then
    echo "usage: check-subject.sh <subject>" >&2
    exit 1
fi

if parsed=$(cc_parse_subject "$subject"); then
    type=$(printf '%s' "$parsed" | cut -d'|' -f1)
    breaking=$(printf '%s' "$parsed" | cut -d'|' -f2)

    case "$type" in
        feat) effect="a minor release" ;;
        fix)  effect="a patch release" ;;
        *)    effect="no release on its own" ;;
    esac

    if [ "$breaking" = "yes" ]; then
        effect="a major release"
    fi

    echo "OK: '$subject'"
    echo "This will produce $effect."
    exit 0
fi

cat >&2 <<MESSAGE
Not a conventional commit subject:

    $subject

Expected: <type>[(scope)][!]: <description>

  Types:    $CC_TYPES
  Bang (!): marks a breaking change, as does a 'BREAKING CHANGE:' body footer

Examples:

  feat(combine): add live observation publishers
  fix: merge batch object IDs into live contexts
  feat!: require a SQLite-backed store for the batch tier
  docs: expand the migration notes

The release job derives the next version from these subjects, so a PR title
outside this grammar produces no release at all.
MESSAGE
exit 1
