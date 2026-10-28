# AI Fleet

<p align="center">
  <img src="docs/assets/ai-fleet-github.png" width="220" alt="AI Fleet — a formation of ships">
</p>

A tiny macOS menu-bar app that checks coding-provider status once per minute.

It sits in the menu bar as a ship icon and shows a simple dropdown:

- **Kimi** — Kimi Code usage from `~/.kimi-code`, falling back to Moonshot API balance.
- **Codex** — remaining usage percent from the ChatGPT backend.
- **Claude** — remaining 5h/7d subscription quota and native sign-in.
- **Gemini** — native Google login, email/plan, and model quota with reset times.
- **Accounts** — shared α/β/γ badges across providers; email and plan on hover.

No dock icon. AI Fleet monitors and opens native sign-in for each provider’s global login.

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9 or later

## Agents

Choose **Agents** after **Refresh now**, or press **Command-A** in the open menu.
The same shortcut returns to Usage, including after Jump transfers focus to iTerm2.
The colorful list groups live Codex/Claude sessions by project, with filters,
collapsible groups, observed statuses and animated working indicators. Click a row
to open its exact iTerm2 window/tab/split; the overview stays open. Escape or an
outside click closes it. The engine ships inside the app; no separate Hub CLI or
Rust toolchain is required by installed releases. Source builds also need Rust
with the current stable toolchain. iTerm2 access may require macOS Automation permission.

Only local interactive Codex/Claude in iTerm2 are supported. Unknown states remain
explicit, and activity stripes do not claim a task-completion percentage.
See [Agents](business/agents.md).

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

### Gemini

Install the official CLI with `brew install gemini-cli`, then choose
**Gemini → … → Sign in…** in AI Fleet and **Sign in with Google** in Terminal.
The first run opens native login; subsequent sign-ins reopen its `/auth login`
dialog. The standard global login is used. Corporate accounts may need the
provider’s Google Cloud project setup.

AI Fleet reads file-backed OAuth in `~/.gemini`, checks the actual email, and
retrieves the CLI’s model quota and plan. Quota updates are spaced five minutes
apart. API-key/Vertex and encrypted OAuth storage are outside this reader.
Expired or unconfirmed credentials show a gray **Sign in required** row with
no active arrow; cached tokens alone do not count as available. Use native Sign in
to renew access; AI Fleet does not rewrite Google tokens. See [Gemini integration](business/gemini.md).

### Accounts

Each Greek letter identifies an account. The same letter follows every provider
connected to it: for example **Codex (α)** and **Claude (α)** belong to the same
account. One account can connect each provider only once.

Open **Settings → Accounts → Connect provider…**, choose the provider, then choose
**Existing account** or **New account**. Codex **Sign in…** saves authorization
for the selected account through its own browser flow. Sign in once per account
to retain each account's remaining quota while using another. Running terminal
sessions keep their current authorization. **Sign out** clears only the selected
account's saved Codex login.

The menu shows each account's remaining 5h/7d limits. A circle means current
limits are loaded, × requests sign-in, and ? with a gray row means limits are
unavailable, even if the CLI has a configured login. The row explains why.
The header separates application Status, last Checked time, and Limits loaded.
→ marks Current and ↓ marks Lowest. **Statistics → Codex →
Accounts** compares tokens and quotas under the same account letters for `7d`,
`30d`, `90d` and `All`. These account totals come from provider-reported dates;
shared local model history and cost estimates are not split between accounts.
A wrong browser email is reported instead of showing another account's quota.

Claude keeps its current standard login and appears under the associated account.
Other provider integrations retain their existing login behavior. Provider visibility
hides rows and statistics tabs without deleting logins or metadata. Hover an
account badge to see its email and plan. Removing an account preserves credential
files and history; sign out first when credentials should also be cleared.
See [Accounts](business/accounts.md) and [Codex authorization](business/codex-profiles.md).

## Refresh

Provider status is refreshed every 60 seconds. **Refresh now** also checks local
login immediately. Claude quota requests reuse measurements for five minutes;
opening views or refreshing does not bypass that interval or a server cooldown.
If Claude limits quota updates, the app keeps the login visible, shows any last
measurement with its time, and displays the next retry time.

## Notifications

Settings lets you manage remaining-quota thresholds such as `50`, `25`, `10`,
`5`, and `0` percent. Thresholds are sorted automatically, can be added or
removed, and fire when a provider crosses that remaining percentage from above.
Notifications identify the affected quota window, for example
`Codex reached 5% threshold (7d).` Each threshold fires once per quota window and
becomes eligible again after that window resets above it. When reset data is
available, the next line includes both forms: `Resets in 2h 14m · Aug 24 at 06:00.`

The menu shows the remaining quota and reset time for each limit window.
For Codex it intentionally shows only the main account limits; separate
model-specific limits such as Spark are omitted.
Detailed usage data remains available in **Statistics…**.

## Menu View

Click the menu-bar icon or press `⌘⇧I` to toggle the status view.

**Statistics…** provides `7d`, `30d`, `90d`, and all-time ranges.
Choose **Kimi** or **Qwen** for local token history with the same periods,
input/cache/output cards, models, days, and Activity. Kimi reads `wire.jsonl`
under `~/.kimi-code/sessions` and legacy `~/.kimi/sessions`; Qwen reads JSONL
chat records under `~/.qwen/projects/*/chats`. Refresh scans retained logs;
opening or switching tabs uses the cache. Missing history is labelled, and API
prices are not configured for these two tabs, so their Estimate reads `—`.
Kimi's quota summary remains available; click **Kimi quotas** for usage counts
and reset times. Local token statistics do not provide Qwen subscription quotas.
See [provider statistics](business/provider-statistics.md) for format support.

Choose **Claude** for local Claude Code tokens, input/cache/output breakdowns,
standard API-equivalent estimates, models, daily totals, and Activity. This reads
`~/.claude/projects` including subagent transcripts, with repeated content-block
usage counted once per API message in each file. It covers history retained on
this Mac, independently of your current login. Unknown model prices show no
estimate; estimates exclude tool charges and pricing premiums and are not
subscription bills. Click refresh to scan your history for the first time.

On the **Codex** tab:
The all-time Total comes from the signed-in ChatGPT account, with its Estimate
extrapolated using the blended API-equivalent cost per token in local logs.
Days, Activity, and the `7d`, `30d`, and `90d` totals and estimates use active and
archived local sessions. Each event belongs to the day from midnight to midnight
in the computer's current time zone, including daylight-saving changes. This
shows today's recorded activity even when account daily reports are delayed.
Daily history covers logs retained on this Mac. Input, Output, cache, reasoning,
Models, Events, and Files also use local logs. `Account` and `Local` badges
identify the source. Click refresh to include new activity or rebuild daily
aggregates after changing the computer's time zone.

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
local time (12:00 by default). Unchanged Codex and Claude session files are reused from an
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

Update failures appear in the top Status with a **Retry update…** action.
Version checks use the public release redirect without a GitHub API token.
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
