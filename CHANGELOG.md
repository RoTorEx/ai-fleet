# Project Changelog

Tracks real product and release progress.

## [Unreleased]

- Added the standard tag-driven release flow: interactive version preparation,
  macOS Apple Silicon and Intel artifacts, checksums, smoke checks, and automatic
  GitHub Release publication.
- Added the application version to the menu footer.
- Added an in-app updater that downloads the latest architecture-specific GitHub
  Release, verifies its checksum and application identity, installs it, and
  relaunches AI Fleet.
- Added a terminal installer for verified latest or exact-version GitHub
  Releases, defaulting to `~/Applications` without `sudo`.
- Hardened local Kimi API key permissions and added a repository-history secret
  audit for public-source safety.
- Added the working kernel-sync Make targets and removed the fake lint target.
- Tiny macOS menu-bar app with a paper-ship icon.
- No CLI wrapper, install script, or `~/.x-cli-ai-fleet` setup.
- Polls Kimi Code (`api.kimi.com/coding/v1/usages`, with Moonshot balance fallback) and Codex (`chatgpt.com/backend-api/wham/usage`) directly every 60 seconds.
- Simple menu showing only Kimi and Codex status.
- Session Supervisor window.
