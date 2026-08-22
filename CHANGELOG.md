# Project Changelog

Tracks real product and release progress.

## [Unreleased]

- Added the working kernel-sync Make targets and removed the fake lint target;
  release commands remain omitted until a real delivery process exists.
- Tiny macOS menu-bar app with a paper-ship icon.
- No CLI wrapper, install script, or `~/.x-cli-ai-fleet` setup.
- Polls Kimi Code (`api.kimi.com/coding/v1/usages`, with Moonshot balance fallback) and Codex (`chatgpt.com/backend-api/wham/usage`) directly every 60 seconds.
- Simple menu showing only Kimi and Codex status.
- Session Supervisor window.
