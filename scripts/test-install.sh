#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
mkdir -p "$test_root/bin"

cat > "$test_root/bin/uname" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' arm64
EOF

cat > "$test_root/bin/curl" <<'EOF'
#!/usr/bin/env sh
case "$*" in
    *%\{url_effective\}*)
        printf '%s\n' 'https://github.com/RoTorEx/ai-fleet/releases/tag/v9.8.7'
        ;;
    *)
        exit 42
        ;;
esac
EOF

chmod +x "$test_root/bin/uname" "$test_root/bin/curl"

if output=$(PATH="$test_root/bin:$PATH" sh "$repo_root/scripts/install.sh" \
    --install-dir "$test_root/install" 2>&1); then
    echo 'ERROR: installer unexpectedly completed with stubbed downloads' >&2
    exit 1
fi

printf '%s\n' "$output" \
    | grep -Fq 'Downloading AI Fleet v9.8.7 for aarch64…' \
    || {
        printf '%s\n' "$output" >&2
        echo 'ERROR: installer did not reach the architecture-specific download' >&2
        exit 1
    }

echo 'Installer flow test passed.'
