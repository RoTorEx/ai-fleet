# Project Changelog

Tracks real product and release progress.

## [Unreleased]

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
- Reorganized the summary into semantic cards: Total and Dataset share the first
  row, while Input, Output, and Estimate own their details on the second row.
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
