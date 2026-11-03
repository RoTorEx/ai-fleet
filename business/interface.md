# Interface and local review

The menu opens immediately, without a growing/fading popover animation. Settings,
Statistics and child help/options popovers also open without window animation.
Hover transitions inside a reset cell remain separate and respect Reduced Motion.

## Menu

One compact header contains the monitoring dot/status, measured/total connection
count, the guide (i), Refresh, and the options button. There is no separate
Providers/Lowest summary block. Routine quota refresh keeps Active stable.
Agents is expanded below the provider connections in the same 400-point menu.
All location groups start open and collapse independently. Paths use their last
two components; the home directory is ~ and a direct child is ~/project.
The separate filter icon contains All/Needs you/Working/Idle/Unknown.
Command-R refreshes providers and agents; Command-A returns from Processes.

The options panel contains Statistics, Settings, Processes, then Quit, followed
by Last checked and version as its final secondary line. Refresh is a header
button, not an options entry. Every option row has a full-width hit area and
larger vertical padding. Icons can be small without making targets hard to hit.
Update is not a visible command.

Account actions show exactly one authentication command: Sign out when signed in,
otherwise Sign in. Switch follows it. Saving a native Codex login remains available
when an independent saved login is absent; Switch stays disabled until connected.
Provider rows use readable account names; Greek badge/email mappings remain in
the guide. The local review intentionally uses different small action icons
(Claude key, Codex alpha grouped cards, Codex beta switches, other variants)
so the user can compare them. These icons are not authentication indicators.

The info button reveals the legend on hover or click. Account name hover shows
email/plan in an opaque native child popover, never an overlay drawn behind later
rows. The same reset cell changes from absolute date to a live countdown on hover;
↻ changes to a clock. All countdowns use total HH:MM:SS, even across days.
Missing/blocked dates do not invent a timer, and expired dates read Reset due.
The guide explains status, connection-count meaning, quota colors/access/marks,
account identities, reset times, live agent states, animations and filters.

## Settings

A sidebar separates General (shortcut and refresh schedule), Accounts (identity,
login and future-launch selection), Providers (menu visibility), and Notifications
(thresholds and system permission controls). Version/check metadata stays in options; account and visibility forms remain separate.

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
