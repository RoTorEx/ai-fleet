#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fixture="$test_root/fixture"
origin="$test_root/origin.git"
mkdir -p "$fixture/AppBundle" "$fixture/scripts"
cp "$repo_root/AppBundle/Info.plist" "$fixture/AppBundle/Info.plist"
cp "$repo_root/scripts/release.sh" "$fixture/scripts/release.sh"
chmod +x "$fixture/scripts/release.sh"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$fixture/AppBundle/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1.0.0' "$fixture/AppBundle/Info.plist"

printf '%s\n' \
    '# Changelog' \
    '' \
    '## [Unreleased]' \
    '' \
    '- Exercise the release flow.' \
    > "$fixture/CHANGELOG.md"

cat > "$fixture/Makefile" <<'EOF'
.PHONY: check release

check:
	@:

release:
	@./scripts/release.sh
EOF

git init --bare "$origin" >/dev/null
git -C "$fixture" init -b main >/dev/null
git -C "$fixture" config user.name 'Release Test'
git -C "$fixture" config user.email 'release-test@users.noreply.github.com'
git -C "$fixture" add .
git -C "$fixture" commit -m 'fixture' >/dev/null
git -C "$fixture" remote add origin "$origin"
git -C "$fixture" push -u origin main >/dev/null

(
    cd "$fixture"
    printf '1.2.3\n' | make release >/dev/null
)

test "$(git -C "$fixture" tag --points-at HEAD)" = 'v1.2.3'
test "$(git -C "$fixture" log -1 --format=%s)" = 'build: release v1.2.3'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fixture/AppBundle/Info.plist")" = '1.2.3'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$fixture/AppBundle/Info.plist")" = '1.2.3'
grep -qx '## \[Unreleased\]' "$fixture/CHANGELOG.md"
grep -Eq '^## \[1\.2\.3\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$fixture/CHANGELOG.md"
test -z "$(git -C "$fixture" status --porcelain)"

echo 'Release flow test passed.'
