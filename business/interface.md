# Interface and local review

The menu opens immediately, without a growing/fading popover animation. Settings,
Statistics and child help/options popovers also open without window animation.
Reset hover swaps content without animation or a change in cell geometry.

## Menu

One compact header contains the monitoring dot/status, measured/total connection
count, the guide (i), Refresh, and the options button. There is no separate
Providers/Lowest summary block. Routine quota refresh keeps Active stable.
Agents is expanded below the provider connections in the same 320-point menu.
The arrow-free borderless panel uses adaptive system blur, rounded corners and
instant presentation. Session titles use smaller text; the separate colored
provider label stays at the start of the second row when a title or model truncates.
The first row reserves its full width for the session title. The second row shows
provider/model and one monochrome state label. Working includes elapsed turn time
in parentheses and a moving gray strip beneath the row (static with Reduced
Motion). The timer uses explicit elapsed work from the validated terminal, then the bound
provider's current request timestamp; without either, ≥ denotes continuous
observed duration, reset when monitoring stops. Polls and
assistant messages do not reset that observed clock. Idle maps opened/untracked
idle observations; Ready maps a newly completed reply not opened since arrival.
Opening is not proof of reading. Question/Approval preserve required input, Error
maps an agent-reported blocker, and Unknown/Stale/Unlinked remain explicit.
The last-message line uses bound provider-log time, never polling time or process
creation time; unavailable times are dashes. Source titles and logs are retained.
The menu grows to at most 75% of available screen height, then only agents scroll.
Measured fixed sections, the Agents header and footer remain in place.
All location groups start open and collapse independently. Paths use their last
two components; the home directory is ~ and a direct child is ~/project.
The separate filter icon includes Working, Idle, Ready, Question, Error and Unknown.
Command-R refreshes providers and agents; Command-A returns from Processes.

The compact options panel contains Statistics, Settings, Processes, then Quit.
Last refresh: HH:MM:SS sits at the bottom left of the main menu, with version at the right.
Refresh stays beside options in the header. Update is not a visible command.

Account actions show exactly one authentication command: Sign out when signed in,
otherwise Sign in. Switch follows it. Saving a native Codex login remains available
when an independent saved login is absent; Switch stays disabled until connected.
Provider names retain Greek badges in parentheses. Account identities appear only
in the hover/click legend. All account-action buttons use a small key, separated
from provider-adjacent selection text. A vertical divider after the provider name
introduces a small checkmark, which marks the selected account independently for
each tool. Its meaning lives in the legend; no Default/Next launch text is shown. The key at the right carries no selection status;
only the small lowest-positive-quota down arrow remains. No leading status gutter
or account-name hover popup competes with the names.

The legend separates monitoring/counts, accounts, remaining limits, reset times
and live agents. Reset date hover changes the same fixed cell to a clock and
nonzero day/hour/minute/second parts (for example, `23h 24m 26s` or `1h 5s`),
with no zero components or leading zero padding. A permanent baseline prevents
layout changes on hover. Missing dates
read Not reported, never an invented reset time; expired dates read Reset due.

## Settings

Two native tabs, General and Accounts, fit a compact 560 × 410-point window.
Application options and Command-comma open the same window, avoiding the separate
SwiftUI Settings-scene presentation. Window section titles use 15-point semibold
text; form labels/body use 13-point regular text and secondary notes use 11-point.
General groups menu behavior/shortcut, alphabetic providers, Statistics schedule
and Notifications with shared label/control columns. Content scrolls; there is no
repeated page heading, sidebar or Quit command. Native tabs use their entire hit
target. Quit remains in application options. Provider visibility affects the main
menu only; Statistics keeps its independent selection. Enabled providers remain
visible even without an installed CLI or a login. Unavailable connections use ×
and quota/reset dashes, with known 5h/7d periods only where supported. They do not
show a sign-in paragraph or invent percentages. Names/limits use a shared left
column; a full-height vertical rule precedes the clock/date column for every row.

Accounts lists independent account blocks, each with its own provider connectors.
Add/remove account and add/remove provider are distinct actions. Removal confirms
that credentials, logs and running processes survive. Explicitly removed native
bindings stay removed until Import login is requested. Terminal identities with a
confirmed email import automatically to the unique matching account; different
emails create distinct accounts. Pending private homes never borrow a native
home's identity or quota. Unknown identity is unverified and Switch is disabled.
A command launch rechecks named provider identity rather than trusting an earlier
UI choice. Kimi browser login checks /me against the expected email before writing
private credentials; denial, cancellation, mismatch and unavailable identity do
not overwrite them. Unsupported native login flows explain terminal login and
refresh rather than offering a circular Switch-then-sign-in instruction.

The legend uses short separate lines for every mark, state and unit, with grouped
headings and separators; account emails get their own line. Only the Agents block is monochrome. Provider quota colors, the monitoring
status dot, and normal system control accents retain their original colors. Shared compact typography remains 12-point headings, 11-point body,
10-point secondary data and centered 12-point symbols in 28-point click targets.


## Statistics

Statistics is a combined local selection labeled Local usage · This Mac.
Codex/Claude/Kimi/Qwen inclusion buttons filter every metric, model/day table and
Activity together, independent of main-menu provider visibility. Selection is
stored in analytics.selectedProviders. All-off is a supported empty state.
Gemini is explicitly unavailable until a local token reader exists.

The aggregate derives from provider caches without rewriting them; remote Codex
account totals never enter it, including All. Model names retain their provider
prefix. Day aggregation follows the computer's calendar/time zone. Unknown prices
suppress the selected estimate, never token counts or known individual model
estimates. Empty unsupported-price providers do not invalidate existing costs.
Numbers promote a thousand millions to billions everywhere, with two decimals;
the rounding boundary cannot produce 1000.00M. Buttons have no blue focus ring. Hovering token values or their info icon shows
rotating book comparisons with quantity/title in bold and explanation in normal text.

Codex model identity comes only from structured session/turn metadata or explicit
usage model fields, in log order. Prompt examples cannot select a model. Unknown
metadata stays Unknown model, and unknown model prices remain unavailable. Parser
revision 2 invalidates earlier Codex per-file records, rebuilt on first Statistics
open, while retaining source logs,
other-provider caches and stored account snapshots. Repeated identical cumulative
usage snapshots do not count as another model request.

Provider reports are a separate panel with identity-bound account token/quota
reports. The integrations do not supply a monetary provider estimate; no local
rate is multiplied by an account-wide total. Filters apply to this panel too.

UI review covers options, hover help, reset countdown,
authentication menu choices, Settings destinations and Statistics filters in
both appearances without signing in/out, switching real accounts, or stopping
user processes.

The guide sits beside the shared status/count because it explains the whole menu.
This is a product layout choice informed by contextual-help guidance, not a claim
that Apple mandates one exact position for an info icon. Reference:
[Apple HIG: Offering help](https://developer.apple.com/design/human-interface-guidelines/offering-help).
