#!/bin/bash
# Turns CHANGELOG.md's "## [Unreleased]" section into the release's, leaving a
# fresh empty Unreleased above it. Run it on a branch for the release's pull
# request, before tagging: release.yml won't release a version with no section.
#
#   scripts/promote-changelog.sh 1.2.0
#
# The changelog promotion from Orchard's scripts/release.sh, without its
# version bump: Gannin's version comes from the tag.
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <major>.<minor>.<patch>" >&2
    exit 1
fi
cd "$(dirname "$0")/.."

if grep -q "^## \[$VERSION\]" CHANGELOG.md; then
    echo "CHANGELOG.md already has a section for $VERSION." >&2
    exit 1
fi
if ! grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    echo "CHANGELOG.md has no \"## [Unreleased]\" section to promote." >&2
    exit 1
fi
# Something under Unreleased other than blank lines and group headings.
if ! awk '/^## \[Unreleased\]/ { on = 1; next } /^## / { on = 0 } on && NF && !/^### / { found = 1 } END { exit !found }' CHANGELOG.md; then
    echo "Nothing under \"## [Unreleased]\" yet: add the release's changes first." >&2
    exit 1
fi

temp_file=$(mktemp)
awk -v ver="$VERSION" -v date="$(date +%Y-%m-%d)" '
    /^## \[Unreleased\]/ && !done {
        print "## [Unreleased]"
        print ""
        print "## [" ver "] - " date
        done = 1
        next
    }
    { print }
' CHANGELOG.md > "$temp_file"
mv "$temp_file" CHANGELOG.md
echo "CHANGELOG.md: Unreleased is now $VERSION. Review it, open a pull request, merge, then tag v$VERSION."
