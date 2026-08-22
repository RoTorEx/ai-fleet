#!/usr/bin/env sh
set -eu

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Prepare one AI Fleet release.

Usage:
  make release

The command requires a clean main branch, prompts for the exact
MAJOR.MINOR.PATCH version, runs make check, updates AppBundle/Info.plist and
CHANGELOG.md, creates one release commit, and creates the matching annotated
tag.

After review, run:
  make release-push
EOF
}

read_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppBundle/Info.plist
}

validate_version() {
    version="$1"
    printf '%s\n' "$version" \
        | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
        || fail "version must be MAJOR.MINOR.PATCH"
}

version_is_greater() {
    awk -v current="$1" -v target="$2" 'BEGIN {
        split(current, c, "."); split(target, t, ".")
        for (i = 1; i <= 3; i++) {
            if (t[i] > c[i]) exit 0
            if (t[i] < c[i]) exit 1
        }
        exit 1
    }'
}

update_metadata() {
    target="$1"
    release_date="$(date +%Y-%m-%d)"
    temp_dir="${TMPDIR:-/tmp}/ai-fleet-release-$$"
    mkdir -p "$temp_dir"

    grep -qx '## \[Unreleased\]' CHANGELOG.md \
        || fail "CHANGELOG.md must contain an exact ## [Unreleased] heading"
    ! grep -Eq "^## \[$target\] - " CHANGELOG.md \
        || fail "CHANGELOG.md already contains release $target"
    awk '
        $0 == "## [Unreleased]" { active = 1; next }
        active && /^## / { active = 0 }
        active && /[^[:space:]]/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' CHANGELOG.md || fail "CHANGELOG.md has no Unreleased entries"

    cp AppBundle/Info.plist "$temp_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $target" "$temp_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $target" "$temp_dir/Info.plist"

    awk -v version="$target" -v release_date="$release_date" '
        !done && $0 == "## [Unreleased]" {
            print
            print ""
            print "## [" version "] - " release_date
            done = 1
            next
        }
        { print }
        END { if (!done) exit 1 }
    ' CHANGELOG.md > "$temp_dir/CHANGELOG.md" \
        || fail "could not update CHANGELOG.md"

    cp "$temp_dir/Info.plist" AppBundle/Info.plist
    cp "$temp_dir/CHANGELOG.md" CHANGELOG.md
}

case "${1:-}" in
    "") ;;
    -h|--help)
        usage
        exit 0
        ;;
    *) fail "make release does not accept arguments" ;;
esac

trap 'rm -rf "${TMPDIR:-/tmp}/ai-fleet-release-$$"' EXIT HUP INT TERM

branch="$(git branch --show-current)"
[ "$branch" = "main" ] || fail "release must run from main, not $branch"
[ -z "$(git status --porcelain)" ] || fail "commit or remove local changes before releasing"

git fetch origin main --tags
git merge-base --is-ancestor origin/main HEAD \
    || fail "local main is behind or diverged from origin/main"

current="$(read_version)"
[ -n "$current" ] || fail "could not read version from AppBundle/Info.plist"
printf 'Current version: %s\n' "$current"
printf 'Release version (MAJOR.MINOR.PATCH): '
read -r target
[ -n "$target" ] || fail "release version is required"
validate_version "$target"
version_is_greater "$current" "$target" \
    || fail "release version must be greater than current version $current"

tag="v$target"
! git rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1 \
    || fail "tag $tag already exists"

make check
update_metadata "$target"
make check

git add AppBundle/Info.plist CHANGELOG.md
git diff --cached --quiet && fail "release produced no metadata changes"
git commit -m "build: release v$target"
git tag -a "$tag" -m "Release $target"

echo "Prepared $tag"
echo "Run: make release-push"
