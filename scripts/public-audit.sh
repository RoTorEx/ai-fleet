#!/usr/bin/env sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

findings=$(mktemp)
trap 'rm -f "$findings"' EXIT HUP INT TERM

git ls-files -co --exclude-standard | while IFS= read -r path; do
  case "$path" in
    .env|.env.*|*/.env|*/.env.*|*.key|*.pem|*.p12|*.pfx|*.mobileprovision|auth.json|*/auth.json|credentials.json|*/credentials.json|config.json|*/config.json|.vibe/KERNEL_SOURCE)
      case "$path" in
        .env.example|*/.env.example) ;;
        *) printf 'sensitive filename: %s\n' "$path" >>"$findings" ;;
      esac
      ;;
  esac
done

secret_pattern='-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}|https?://[^[:space:]/]+:[^[:space:]@]+@'

rg -l -I --hidden \
  --glob '!.git/**' \
  --glob '!.build/**' \
  --glob '!scripts/public-audit.sh' \
  -e "$secret_pattern" . 2>/dev/null \
  | sed 's#^./#possible secret in working tree: #' >>"$findings" || true

for revision in $(git rev-list --all); do
  git grep -I -l -E "$secret_pattern" "$revision" -- . \
    ':(exclude)scripts/public-audit.sh' 2>/dev/null \
    | sed "s#^$revision:#possible secret in history $revision: #" >>"$findings" || true
done

if [ -s "$findings" ]; then
  sort -u "$findings" >&2
  echo 'Public-source audit failed. Remove credentials and clean affected Git history.' >&2
  exit 1
fi

echo 'Public-source audit passed: no tracked credential files or known secret formats found.'
