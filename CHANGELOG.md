# Project Changelog

Tracks real product and release progress.

## [Unreleased]

### Fixed

- Keep the menu compact when adding a fourth account/provider row. Measure the
  actual row content before applying the scroll-height cap, and resize when
  rows or quota windows change instead of reserving an empty 340-point area.

## [1.2.8] - 2026-10-08

### Fixed

- Stop showing Gemini as active/available solely because a refresh token exists.
  Expired or unconfirmed login is gray, with Sign in required and no active arrow;
  only verified server identity can confirm sign-in. Keep quota-only errors
  distinct from failed identity verification.

## [1.2.7] - 2026-10-07

### Added

- Gemini CLI provider with global native sign-in, email/plan, model quota and
  reset times. Detect file-backed OAuth, keep login distinct from quota errors,
  and coalesce/cache quota reads with Retry-After support. Unsupported auth and
  expired credentials show explicit states without fabricated percentages.

- Shared identities with stable α/β/γ badges, provider associations, and immediate
  email/plan hover inside the existing Settings/menu surfaces.

### Changed

- Make Sign in the only provider-row action and use the standard global native
  login. Remove Open, Use this account, and Add account from the ellipsis menu.
- Detect the current account by native email instead of legacy manual selection;
  poll only one global connection per provider. Inactive accounts are gray and
  cannot receive another account’s quota or plan. Preserve legacy isolated files
  and metadata; selective sessions are deferred.
- Keep compact parenthesized badges, tightly grouped left-side markers, and the
  Color/Auth/Selection/Quota legend. Selection now describes the global login.
- Settings → Accounts manages labels, associations, inline additions and global
  sign-in; General contains only application-wide settings. New associations
  create no isolated credential directory; cancel creates no metadata.
- Separate authentication from quota availability. Quota errors retain confirmed
  native auth; stale or unauthenticated measurements cannot drive Lowest/alerts.

### Fixed

- Stop retrying Claude usage requests on every menu open or one-minute poll;
  coalesce requests, cache successful measurements, respect Retry-After, and
  persist increasing cooldowns after HTTP 429 across app restarts.
- Keep authenticated Claude accounts visible during rate limits, explicitly
  label last-known quota, and suppress alerts based on stale measurements.

## [1.2.6] - 2026-10-06

### Fixed

- Read Claude subscription quota windows from the signed-in CLI account and
  refresh provider status when opening the menu or Settings; preserve a visible
  signed-in state when quota credentials cannot be read.

## [1.2.5] - 2026-10-06

### Fixed

- Distinguish missing login, unknown auth status, and unsupported quota retrieval
  for Claude and Qwen; stop treating settings files as proof of login and keep
  sign-in guidance visible in Settings.

### Changed

- Extended the compact menu's orange remaining-quota warning range through 25%.

## [1.2.4] - 2026-08-25

### Added

- Added a second quota-notification line with both the relative wait and exact
  local reset time when the provider supplies a reset timestamp.

### Fixed

- Kept Codex quota status limited to the main account windows and excluded
  model-specific `additional_rate_limits` such as Spark.
- Reset notification threshold history for every provider quota window, so
  editing alert thresholds reliably rearms notifications after window-scoped
  tracking was introduced.
- Standardized all Statistics numbers to use spaces for thousands and a dot for
  fractional digits, realigned the compact period control, and reduced dashboard
  height enough to expose Activity as a scroll cue.
- Displayed Total in billions while keeping Input and Output in millions, used
  two-decimal millions in heatmap hover values, and aligned metric-card typography.
- Replaced the vertically scrolling Statistics page with arrow-controlled
  `Models + Days` and `Activity` pages, eliminating table-to-page scroll chaining;
  heatmap hover now also shows the day's API-equivalent cost estimate.
- Extended Activity through the first vibecoding anniversary and thereafter
  through the current month, sized a full year to the window, opened long
  histories at the newest month, and removed unused heatmap panel height.
- Increased the aligned second summary row so Input accounting details no longer
  collide with the card boundary.

## [1.2.3] - 2026-08-23

### Changed

- Rearranged the aligned Statistics summary grid to place Estimate above
  Sources and let Total span the two columns above Input and Output.
- Clarified in Estimate help that preset ranges use Codex account daily totals
  before applying the locally observed blended rate.
- Removed the Custom period control, centered month labels over their heatmap
  cells, and replaced unreliable native cell tooltips with explicit hover
  popovers showing the exact date and token count.
- Moved the period selector beneath refresh status and replaced SwiftUI's
  uneven spanning-grid sizing with explicit three-column widths and equal card
  heights across both summary rows.

## [1.2.2] - 2026-08-23

### Changed

- Made Codex Total, Days, and period filtering use account-wide usage reported
  by Codex, while clearly labeling the local input/output/model detail scope and
  retaining local data as an offline fallback.
- Added a final GitHub-style activity heatmap with exact hover values and
  horizontal history scrolling; grouped cells into spaced months so labels stay
  horizontal and readable.
- Based headline and daily cost estimates on account tokens using the blended
  API-equivalent rate observed in local sessions, with the extrapolation stated
  directly in help text.
- Aligned both summary rows to one three-column grid so card boundaries no
  longer drift between rows.
- Forced the menu-bar popover closed before Statistics opens and when the user
  clicks an already-open Statistics window.

## [1.2.1] - 2026-08-23

### Changed

- Reset and centered the Statistics window within the visible screen on every
  open, closed the menu popover before showing it, removed Activity, and
  replaced the model/day tables with fixed-width rows that cannot scroll
  horizontally.
- Included `~/.codex/archived_sessions` in incremental analytics so all-time
  covers the complete locally retained history instead of only active sessions.
- Labeled refresh progress as session files, omitted zero-activity dates from
  Days, kept Dataset & accounting compact at larger window sizes, and made the
  total-token help cycle through 15 real-book comparisons using natural
  copy-based wording instead of a visible words-per-token formula.
- Clarified that Total tokens is all model-read Input plus generated Output,
  including cached context and reported internal reasoning—not only user text.
- Added separately calculated book-scale paragraphs to the Total, Input, and
  Output help popovers and tightened their native explanatory copy.
- Rounded book comparisons to natural whole-copy counts with no decimal tail.
- Reorganized the summary into semantic cards: Total and Dataset share the first
  row, while Input, Output, and Estimate own their details on the second row.
- Top-aligned the second-row summary content so cards with fewer detail rows no
  longer appear vertically displaced.
- Moved the app version from the menu footer into the final `Version` row of the
  top status summary.
- Flattened and tightened the Statistics layout so period controls and complete
  table headers fit without an outer scroll, while accounting values are grouped
  into clear Data, Input, Output, and Estimate columns.
- Added explanations to the four summary metrics and clarified why per-model
  reasoning is shown while keeping the daily table compact.

## [1.2.0] - 2026-08-22

### Changed

- Rebuilt Statistics as a resizable Codex/Kimi view with all-time and custom
  ranges, a no-outer-scroll compact layout, native table scrolling, per-model
  reasoning totals, adaptive panels, and a square GitHub-style activity heatmap
  that opens on the full history.
- Made Codex analytics refresh low-priority and incremental, stopped rescanning
  session logs when Statistics opens, and added a configurable daily local-time
  refresh enabled at 12:00 by default.
- Simplified quota notifications to sentences such as
  `Codex reached 5% threshold (7d).` and tracked thresholds per quota window.
- Made menu, Settings, and Statistics colors follow the macOS light/dark theme.
- Added fleet artwork with multiple ships to the GitHub README.
- Removed redundant used-quota values from the compact menu.
- Routed Swift build output to the disposable
  `~/construction_side/ai-fleet.noindex/swift-build` tree.

## [1.1.2] - 2026-08-22

- Fixed the terminal installer on macOS `sh` when printing the selected
  architecture before downloading a release.

## [1.1.1] - 2026-08-22

- Kept Statistics data visible from a local cache while Codex usage refreshes
  continue in the background after closing the Statistics window.
- Simplified the Statistics overview into direct Codex token/cost and Kimi
  quota answers, with detailed provider breakdowns kept on their own tabs.

## [1.1.0] - 2026-08-22

- Added the standard tag-driven release flow: interactive version preparation,
  macOS Apple Silicon and Intel artifacts, checksums, smoke checks, and automatic
  GitHub Release publication.
- Added the application version to the menu footer.
- Added an in-app updater that downloads the latest architecture-specific GitHub
  Release, verifies its checksum and application identity, installs it, and
  relaunches AI Fleet.
- Added a terminal installer for verified latest or exact-version GitHub
  Releases, defaulting to `~/Applications` without `sudo`.
- Added editable remaining-quota notification thresholds and burned quota stats
  in the menu.
- Hardened local Kimi API key permissions and added a repository-history secret
  audit for public-source safety.
- Added the working kernel-sync Make targets and removed the fake lint target.
- Tiny macOS menu-bar app with a ship icon.
- No CLI wrapper, install script, or `~/.x-cli-ai-fleet` setup.
- Polls Kimi Code (`api.kimi.com/coding/v1/usages`, with Moonshot balance fallback) and Codex (`chatgpt.com/backend-api/wham/usage`) directly every 60 seconds.
- Simple menu showing only Kimi and Codex status.
- Session Supervisor window.
