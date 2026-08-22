#!/usr/bin/env sh
set -eu

repository=RoTorEx/ai-fleet
install_dir="$HOME/Applications"
requested_version=latest

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Install AI Fleet from GitHub Releases.

Usage:
  sh ai-fleet-install.sh [--version MAJOR.MINOR.PATCH] [--install-dir PATH]
  sh ai-fleet-install.sh --system [--version MAJOR.MINOR.PATCH]

The default destination is ~/Applications/AIFleet.app. --system selects
/Applications and never invokes sudo; the current user must have write access.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            requested_version="$2"
            shift 2
            ;;
        --install-dir)
            [ "$#" -ge 2 ] || fail "--install-dir requires a value"
            install_dir="$2"
            shift 2
            ;;
        --system)
            install_dir=/Applications
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "unknown option: $1" ;;
    esac
done

case "$(uname -m)" in
    arm64) architecture=aarch64 ;;
    x86_64) architecture=x86_64 ;;
    *) fail "unsupported Mac architecture: $(uname -m)" ;;
esac

if [ "$requested_version" = latest ]; then
    release_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$repository/releases/latest") \
        || fail "could not resolve the latest GitHub Release"
    tag=${release_url##*/}
    version=${tag#v}
else
    version=$requested_version
    tag="v$version"
fi

printf '%s\n' "$version" \
    | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || fail "release version must be MAJOR.MINOR.PATCH"
[ "$tag" = "v$version" ] || fail "GitHub returned an invalid release tag"

archive="AIFleet-$tag-macos-$architecture.zip"
download_base="https://github.com/$repository/releases/download/$tag"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-fleet-install.XXXXXX")
stage_app="$install_dir/.AIFleet.install.$$"
backup_app="$install_dir/.AIFleet.backup.$$"
destination="$install_dir/AIFleet.app"

cleanup() {
    if [ -e "$backup_app" ] && [ ! -e "$destination" ]; then
        mv "$backup_app" "$destination" || true
    fi
    rm -rf "$work_dir" "$stage_app"
}
trap cleanup EXIT HUP INT TERM

echo "Downloading AI Fleet $tag for $architecture…"
curl -fL --retry 3 --connect-timeout 15 \
    -o "$work_dir/$archive" "$download_base/$archive"
curl -fL --retry 3 --connect-timeout 15 \
    -o "$work_dir/$archive.sha256" "$download_base/$archive.sha256"

(
    cd "$work_dir"
    shasum -a 256 -c "$archive.sha256"
) || fail "release checksum verification failed"

mkdir -p "$work_dir/extracted"
ditto -x -k "$work_dir/$archive" "$work_dir/extracted"
source_app="$work_dir/extracted/AIFleet.app"
source_plist="$source_app/Contents/Info.plist"
[ -x "$source_app/Contents/MacOS/AIFleet" ] || fail "release does not contain AIFleet.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_plist")" = "dev.ai-fleet" ] \
    || fail "release bundle identifier is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_plist")" = "$version" ] \
    || fail "release bundle version is invalid"
codesign --verify --deep --strict "$source_app" \
    || fail "release code signature verification failed"

mkdir -p "$install_dir"
[ -w "$install_dir" ] || fail "install directory is not writable: $install_dir"
rm -rf "$stage_app" "$backup_app"
ditto "$source_app" "$stage_app"

osascript -e 'tell application id "dev.ai-fleet" to quit' >/dev/null 2>&1 || true
attempt=0
while pgrep -x AIFleet >/dev/null 2>&1 && [ "$attempt" -lt 20 ]; do
    sleep 0.2
    attempt=$((attempt + 1))
done
pgrep -x AIFleet >/dev/null 2>&1 && fail "quit the running AI Fleet app and retry"

if [ -e "$destination" ]; then
    mv "$destination" "$backup_app"
fi
if mv "$stage_app" "$destination"; then
    rm -rf "$backup_app"
else
    [ ! -e "$backup_app" ] || mv "$backup_app" "$destination"
    fail "could not install AI Fleet"
fi

open "$destination"
echo "Installed AI Fleet $tag at $destination"
