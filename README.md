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

The **Agents** tab groups live Codex, Claude, Kimi, Qwen, Gemini and Grok sessions
by project, with filters, collapsible groups, observed statuses and working
indicators. Its list scrolls when the menu reaches 80% of the visible screen.
Click a row to open its exact iTerm2 window/tab/split; the overview stays open.
Escape or an outside click closes it. The engine ships inside the app; no
separate Hub CLI or Rust toolchain is required by installed releases. Source
builds also need the current stable Rust toolchain. iTerm2 access may require
macOS Automation permission; project metadata may require Documents access.

Only local interactive sessions in iTerm2 are supported. Codex/Claude retain
verified activity and transcript parsing. Other providers remain explicitly
Unknown, with their own filter rather than an invented Idle state. CLI updates
that unlink an old executable no longer hide its still-running sessions.
Activity indicators do not claim a task-completion percentage.
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

The app first reuses Kimi Code credentials from the login slot and region named in `~/.kimi-code/config.toml` (`credentials/kimi-code.json` when none is named).

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
**Gemini → … → Sign in** in AI Fleet and **Sign in with Google** in Terminal.
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

Open **Settings → Accounts → Add Account**, enter the email, and optionally pick
a provider to connect; an existing account's **Connect Provider** menu adds more.
Drag accounts to reorder them; the letters follow the order. Codex **Sign in** saves authorization
for the selected account through its own browser flow. Sign in once per account
to retain each account's remaining quota while using another. Running terminal
sessions keep their current authorization. **Sign out** clears only the selected
account's saved Codex login, and is refused while its Fleet sessions are running.

Use **Save current login** to retain an already authenticated Codex account.
**Switch** selects the account for your next ordinary `codex`
or `codex resume` command, including in the same terminal. Codex and Claude use the policy selected in Settings → General: Next launch
only (default), Wait for exit, Stop gracefully, or Force quit. Stopping policies
show the affected PIDs and require confirmation. Unverified account ownership
requires manual review in Processes. See [Switch recovery](business/switch-recovery.md). After the first installation of command
integration, run `rehash` once in terminals already open; later account changes
need no extra command. The shim lives at `~/.local/bin/codex`, which must precede
the native CLI in PATH. New terminals use it automatically with that PATH order.
The original CLI installation remains intact and receives normal updates.

New interactive launches do not attach to the old shared daemon. Credentials stay
account-specific while history, settings, instructions and skills remain shared.
Explicit CODEX_HOME/remote invocations and server-management commands retain their
native scope. Fleet never opens a terminal or starts a conversation for you.
To remove command integration, delete only the Fleet-owned `~/.local/bin/codex`
shim and run `rehash`; saved accounts, history and native credentials remain.

**Processes** lists recognized Codex, Claude, Kimi, Qwen, Gemini and Grok
processes, including detached servers and helpers. Use
**Stop**, **Force Quit**, or **Stop all background processes…** after reviewing
the confirmation. The app verifies process identity and checks exit. Account
selection follows the chosen Switch policy; stopping requires confirmation.

The menu shows each account's remaining 5h/7d limits in aligned columns. One
mark leads a row when it says something: → a signed-in current account,
↓ the lowest positive quota among signed-in current accounts, × sign-in required
and ? limits unavailable (gray even with a configured CLI login). Other saved
logins have no arrow. Switch is hidden for the current signed-in account in
both the menu and Settings. Important account notes
appear in the Status section of the ⓘ card.
The header shows whether AI Fleet monitoring is Active or Paused, with Refresh
(⌘R) and Options (⋯) on the right. Tabs Providers (with a `measured/saved`
count such as `1/6`), Agents and Processes (with its count) switch by click or ← / →.
Options also opens Statistics (⌘S) and Settings (⌘,). The footer shows the
last refresh and the version. Hover ⓘ next to the status for the legend, which groups
Monitoring, Quota (normal/low/critical), Access (ready/sign in/unavailable),
Marks and Keys. **Statistics → Provider reports** compares Codex tokens and
quotas under the same account letters for the chosen period. These account totals come from provider-reported dates;
shared local model history and cost estimates are not split between accounts.
A wrong browser email is reported instead of showing another account's quota.

Claude, Kimi, Qwen and Gemini use the same **Switch** behavior: the next ordinary
provider command uses the selected account; next-launch-only mode keeps running sessions. Claude also follows the configured
stop policy. Sign in is separate. New profiles need their own native login. Gemini and Qwen may
complete that login on the first CLI launch. Explicit directory/API-key/remote
invocations keep their native scope. See [Provider switching](business/provider-switching.md)
for adapter boundaries and verification coverage. Provider visibility
hides rows and statistics tabs without deleting logins or metadata. Hover an
account badge to see its email and plan. Removing an account preserves credential
files and history; sign out first when credentials should also be cleared.
See [Accounts](business/accounts.md) and [Codex authorization](business/codex-profiles.md).

## Refresh

Provider limits are refreshed quietly every 60 seconds and on menu open; Agents update live every 2 seconds while the menu is open. **Refresh** (⌘R) also checks local
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

**Statistics** (⌘S) is one screen with `7d`, `30d`, `90d`, and all-time ranges.
Provider chips choose which local histories the totals, By provider bars, models,
days and Activity include; Option-click a chip to see only that provider. Kimi reads `wire.jsonl`
under `~/.kimi-code/sessions` and legacy `~/.kimi/sessions`; Qwen reads JSONL
chat records under `~/.qwen/projects/*/chats`. Refresh scans retained logs;
opening Statistics or changing chips uses the cache. API prices are not
configured for Kimi and Qwen, so a total that includes them shows its priced part
as `≥ $…`. Kimi's quota windows appear under **Provider reports**. Local token statistics do not provide Qwen subscription quotas.
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
will contain a native macOS application ZIP for Apple Silicon plus its SHA-256
checksum. Historical releases may also contain Intel builds. New releases require
Apple Silicon; explicit historical Intel versions remain installable when their
assets exist. The application is ad-hoc signed; it is not currently notarized by
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

## Account connections

Codex and Claude terminal logins with confirmed identities import on Refresh.
Disconnect keeps credentials and history; **Add Account → Import** explicitly
restores an intentionally removed native terminal login.
A second account's Sign in uses an isolated credential home. A wrong browser
identity or failed login preserves the previous connection. After successful
sign-in, use Switch to select that connection for ordinary commands.

Local signing and menu data contracts: [monitoring and builds](docs/contracts/menu-monitoring.md).
