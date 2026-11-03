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
The first row reserves its full width for the session title. One static status
icon plus its text appears on the second row: working blue, new reply green,
approval/question orange, blocked red, idle/unknown/stale/unlinked gray. Opening
a pane temporarily uses this same status slot. Separate orbit spinners, leading
state circles and bottom activity strips are removed; provider labels retain
provider colors independently of session state. Explicit provider
annotations are removed from titles without removing provider words in task text.
The menu grows to at most 75% of the available screen height, then the agents
list scrolls while providers, the Agents header and footer remain fixed. The list
budget subtracts measured fixed sections and uses the menu-bar item's screen;
errors belong inside the same viewport. Shrinking or collapsing the list reduces
the menu height again.
All location groups start open and collapse independently. Paths use their last
two components; the home directory is ~ and a direct child is ~/project.
The separate filter icon contains All/Needs you/Working/Idle/Unknown.
Command-R refreshes providers and agents; Command-A returns from Processes.

The compact options panel contains Statistics, Settings, Processes, then Quit.
Last checked sits at the bottom left of the main menu, with version at the right.
Refresh stays beside options in the header. Update is not a visible command.

Account actions show exactly one authentication command: Sign out when signed in,
otherwise Sign in. Switch follows it. Saving a native Codex login remains available
when an independent saved login is absent; Switch stays disabled until connected.
Provider names retain Greek badges in parentheses. Account identities appear only
in the hover/click legend. All account-action buttons use a small key, separated
from provider-adjacent selection text. A vertical divider after the provider name
introduces Next launch, which marks the selected account independently for each
tool. The key at the right carries no selection status;
only the small lowest-positive-quota down arrow remains. No leading status gutter
or account-name hover popup competes with the names.

The legend separates monitoring/counts, accounts, remaining limits, reset times
and live agents. Reset date hover changes the same fixed cell to a clock and
nonzero day/hour/minute/second parts (for example, `23h 24m 26s` or `1h 5s`),
with no zero components or leading zero padding. A permanent baseline prevents
layout changes on hover. Missing dates
read Not reported, never an invented reset time; expired dates read Reset due.

## Settings

A sidebar separates General (shortcut and refresh schedule), Accounts (identity,
login and future-launch selection), Providers (menu visibility), and Notifications
(thresholds and system permission controls). General explicitly controls closing the menu on outside clicks (enabled by default).
The preference applies immediately to both local and global mouse events; Escape
and the menu-bar toggle continue to close it. Account and visibility forms remain separate.

The shared window hierarchy uses 15-point section titles, 13-point body text and
11-point secondary text, with 16-point outer padding. The compact menu uses
12-point medium section/provider headings, 11-point regular content and 10-point
secondary labels. Its action symbols share an 11-point regular font, centered
inside 28-point targets; provider header text/status/actions align by center.
Selection text sits with the provider identity, not beside the key. Existing analytical numbers retain
their larger metric hierarchy and tabular digits. Row actions, form controls and
secondary data align to shared content edges rather than floating overlays.

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
