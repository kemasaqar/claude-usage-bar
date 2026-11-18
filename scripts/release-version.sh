#!/usr/bin/env bash
# The tag to release a merged pull request as, or nothing for no release.
# Used by .github/workflows/build.yml on every push to main.
#
#   TAGS    the repo's tags, one per line (the highest vX.Y.Z is the last release)
#   LABELS  the pull request's labels, one per line
#   FILES   the files it changed, one per line
#
# Labels: "no release" skips it, "major" and "minor" bump those, anything
# else is a patch. A pull request that only changes docs (*.md, docs/,
# LICENSE) isn't released. The reason goes to stderr.
set -euo pipefail

has_label() { grep -qxF "$1" <<<"${LABELS:-}"; }

if has_label "no release"; then
    echo "Labeled \"no release\"" >&2
    exit 0
fi

if [ -z "${FILES:-}" ]; then
    echo "No changed files given" >&2
    exit 1
fi
if ! grep -qvE '^([^/]*\.md|docs/.*|LICENSE)$' <<<"$FILES"; then
    echo "Only docs changed" >&2
    exit 0
fi

LAST="$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"${TAGS:-}" | sort -t. -k1.2,1n -k2,2n -k3,3n | tail -1 || true)"
LAST="${LAST:-v0.0.0}"
IFS=. read -r MAJOR MINOR PATCH <<<"${LAST#v}"

if has_label major; then
    echo "v$((MAJOR + 1)).0.0"
elif has_label minor; then
    echo "v$MAJOR.$((MINOR + 1)).0"
else
    echo "v$MAJOR.$MINOR.$((PATCH + 1))"
fi
