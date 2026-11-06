#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"
cat > "$tmp/bin/codesign" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SIGN_LOG"
[ "${SIGN_FAIL:-0}" != 1 ]
STUB
cat > "$tmp/bin/uname" <<'STUB'
#!/bin/sh
printf '%s\n' x86_64
STUB
chmod +x "$tmp/bin/"*
export SIGN_LOG="$tmp/sign.log"
PATH="$tmp/bin:$PATH" sh "$root/scripts/sign-bundle.sh" "$tmp/App.app" -
test "$(wc -l < "$SIGN_LOG" | tr -d ' ')" = 3
: > "$SIGN_LOG"
if PATH="$tmp/bin:$PATH" SIGN_FAIL=1 sh "$root/scripts/sign-bundle.sh" "$tmp/App.app" missing; then
    echo 'ERROR: signing failure was hidden' >&2; exit 1
fi
test "$(wc -l < "$SIGN_LOG" | tr -d ' ')" = 1
if PATH="$tmp/bin:$PATH" make -s -C "$root" check-release-architecture > "$tmp/output" 2>&1; then
    echo 'ERROR: Intel release accepted' >&2; exit 1
fi
if PATH="$tmp/bin:$PATH" sh "$root/scripts/install.sh" > "$tmp/output" 2>&1; then
    echo 'ERROR: Intel latest accepted' >&2; exit 1
fi
rg -q 'Apple Silicon' "$tmp/output"
# Explicit historical Intel versions must still reach the download path.
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/sh
exit 42
STUB
chmod +x "$tmp/bin/curl"
if PATH="$tmp/bin:$PATH" sh "$root/scripts/install.sh" --version 1.3.12 > "$tmp/output" 2>&1; then exit 1; fi
rg -q 'Downloading AI Fleet v1.3.12 for x86_64' "$tmp/output"
echo 'Stage five signing and architecture fixtures passed.'
