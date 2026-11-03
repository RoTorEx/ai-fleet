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
provider label stays at the right of the title row when a title or model truncates. Explicit provider
annotations are removed from titles without removing provider words in task text.
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
from trailing status text by a vertical divider. Default labels future launches;
only the small lowest-positive-quota down arrow remains. No leading status gutter
or account-name hover popup competes with the names.

The legend separates monitoring/counts, accounts, remaining limits, reset times
and live agents. Reset date hover changes the same fixed cell to a clock and
`Dd HHh MMm SSs`, with a permanent baseline and no layout animation. Missing dates
read Not reported, never an invented reset time; expired dates read Reset due.

## Settings

A sidebar separates General (shortcut and refresh schedule), Accounts (identity,
login and future-launch selection), Providers (menu visibility), and Notifications
(thresholds and system permission controls). General explicitly controls closing the menu on outside clicks (enabled by default).
The preference applies immediately to both local and global mouse events; Escape
and the menu-bar toggle continue to close it. Account and visibility forms remain separate.

The shared hierarchy uses 15-point section titles, 13-point body text and 11-point
secondary text, with 16-point outer padding. Existing analytical numbers retain
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
