# AI Fleet

A tiny macOS menu-bar app that checks Kimi and Codex status once per minute.

It sits in the menu bar as a paper-ship icon and shows a simple dropdown:

- **Kimi** — Kimi Code usage from `~/.kimi-code`, falling back to Moonshot API balance.
- **Codex** — remaining usage percent from the ChatGPT backend.

No dock icon, no separate windows, no CLI wrapper.

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9 or later

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
```

You can also set the `KIMI_API_KEY` environment variable when running from a terminal.

### Codex

The app reads your ChatGPT OAuth token from `~/.codex/auth.json` (created automatically when you sign in with the Codex CLI). No extra setup is required.

## Refresh

Status is refreshed automatically every 60 seconds. Click **Refresh now** in the menu to poll immediately.

## Menu View

Click the menu-bar icon or press `⌘⇧I` to toggle the status view.

## Quit

Choose **Quit** from the menu.
