# AI Fleet

A tiny macOS menu-bar app that checks Kimi and Codex status once per minute.

It sits in the menu bar as a paper-ship icon and shows a simple dropdown:

- **Kimi** — Kimi Code usage from `~/.kimi-code`, falling back to Moonshot API balance.
- **Codex** — remaining usage percent from the ChatGPT backend.

No dock icon, no separate windows, no CLI wrapper.

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9 or later

## Run from source

```bash
make run
```

## Reinstall to /Applications

```bash
make reinstall
```

This builds `~/construction_side/ai-fleet.noindex/dist/AIFleet.app`, stops any running copy, replaces `/Applications/AIFleet.app`, and launches the new app.

## Setup

### Kimi

The app first reuses Kimi Code credentials from `~/.kimi-code/credentials/kimi-code.json`.

As a fallback, it reads your Kimi API key from `~/Library/Application Support/AI Fleet/config.json`:

```bash
mkdir -p ~/Library/Application\ Support/AI\ Fleet
cat > ~/Library/Application\ Support/AI\ Fleet/config.json << 'EOF'
{
  "kimiApiKey": "sk-..."
}
EOF
chmod 600 ~/Library/Application\ Support/AI\ Fleet/config.json
```

You can also set the `KIMI_API_KEY` environment variable when running from a terminal.

### Codex

The app reads your ChatGPT OAuth token from `~/.codex/auth.json` (created automatically when you sign in with the Codex CLI). No extra setup is required.

## Refresh

Status is refreshed automatically every 60 seconds. Click **Refresh now** in the menu to poll immediately.

## Menu View

Click the menu-bar icon or press `⌘⇧I` to toggle the status view.

## Quit

Choose **Quit** from the menu.

## Releases

Published versions are available from
[GitHub Releases](https://github.com/RoTorEx/ai-fleet/releases). Each release
contains native macOS application ZIPs for Apple Silicon and Intel plus SHA-256
checksums. The application is ad-hoc signed; it is not currently notarized by
Apple.

Install or update the latest release from Terminal without `sudo`:

```bash
curl -fsSLo /tmp/ai-fleet-install.sh \
  https://github.com/RoTorEx/ai-fleet/releases/latest/download/ai-fleet-install.sh
sh /tmp/ai-fleet-install.sh
```

The default destination is `~/Applications/AIFleet.app`. Pass `--system` to
select `/Applications` when the current user can write there, or
`--version MAJOR.MINOR.PATCH` to install one exact release.

Choose **Update…** in the menu to download the newest compatible release,
verify its SHA-256 checksum, bundle identity, version, and code signature,
replace the installed application, and relaunch it. Updates do not bypass macOS
quarantine or Gatekeeper.

Maintainers prepare a release locally and publish it through the tag-triggered
GitHub Actions workflow:

```bash
make release
make release-push
```

`make release` prompts for the exact `MAJOR.MINOR.PATCH` version, verifies the
repository, updates `AppBundle/Info.plist` and `CHANGELOG.md`, creates a release
commit, and adds the annotated `vMAJOR.MINOR.PATCH` tag. `make release-push`
pushes `main` and the tag; CI builds, verifies, and attaches the release assets.

## Kernel sync

```bash
make vibe-kernel-set
make vibe-pull
```

## Security and privacy

AI Fleet reads credentials only from the local paths documented above and sends
them only over HTTPS to the corresponding Kimi, Moonshot, or ChatGPT endpoint.
It does not log tokens or include them in status messages. The Kimi fallback
configuration is restricted to the current macOS user when the app loads it.

Before publishing or contributing, run `make public-audit`. See
[`SECURITY.md`](SECURITY.md) for the credential boundary and vulnerability
reporting guidance.
