# AI Fleet

<p align="center">
  <img src="docs/assets/ai-fleet-github.png" width="220" alt="AI Fleet — a formation of ships">
</p>

A tiny macOS menu-bar app that checks Kimi and Codex status once per minute.

It sits in the menu bar as a ship icon and shows a simple dropdown:

- **Kimi** — Kimi Code usage from `~/.kimi-code`, falling back to Moonshot API balance.
- **Codex** — remaining usage percent from the ChatGPT backend.

No dock icon and no CLI wrapper.

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

## Notifications

Settings lets you manage remaining-quota thresholds such as `50`, `25`, `10`,
`5`, and `0` percent. Thresholds are sorted automatically, can be added or
removed, and fire when a provider crosses that remaining percentage from above.
Notifications identify the affected quota window, for example
`Codex reached 5% threshold (7d).` Each threshold fires once per quota window and
becomes eligible again after that window resets above it.

The menu shows the remaining quota and reset time for each limit window.
Detailed usage data remains available in **Statistics…**.

## Menu View

Click the menu-bar icon or press `⌘⇧I` to toggle the status view.

**Statistics…** provides `7d`, `30d`, `90d`, and all-time ranges.
Account-wide Total, Days, and the bottom GitHub-style Activity heatmap are read
from Codex through the signed-in ChatGPT account, so this history is not tied to
session files retained on one Mac. Input, Output, cache, reasoning, Models,
Events, and Files still come from active and archived local session logs because
Codex does not provide those account-wide breakdowns. API-equivalent Estimate
uses the selected account token total multiplied by the blended cost per token
observed in those local logs. `Account` and `Local` badges identify the source.

The dashboard scrolls vertically to the final Activity block. The heatmap uses
separate month grids with centered abbreviated labels and spacing, an exact
date/token hover popover, and horizontal scrolling for long histories. The two tables scroll their rows only
vertically without horizontal scrolling. Days omits dates with no activity. On
each hover, the total-token help
cycles through 15 approximate comparisons with well-known English fantasy and
science-fiction books or complete series. The same help explains that Total is
all model-read Input plus generated Output, including repeated cache context and
reported internal reasoning—not only text typed by the user. Total, Input, and
Output each show their own comparison in a separate paragraph. The window
resets to its compact size and opens centered on the visible screen.
The summary uses one three-column grid: Estimate sits above Sources in the first
column, while Total spans the two columns above Input and Output. Both rows use
equal card heights. The period selector sits under the refresh information at
the upper right.

Opening Statistics performs only a lightweight account-usage sync and never
starts a session-log scan. Manual refresh remains
available, and Settings can enable a low-priority daily refresh at a chosen
local time (12:00 by default). Unchanged Codex session files are reused from an
incremental local cache.

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
