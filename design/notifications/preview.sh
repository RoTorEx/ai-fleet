#!/bin/bash
# Fire the proposed notification texts as real macOS banners, so the system's
# own truncation, line count and font weights can be judged before any app code
# changes. Banners come from "Script Editor": no Fleet icon, no buttons, no jump.
#
#   ./preview.sh            all types, text on
#   ./preview.sh done       one type: approval question blocked done quota test
#   TEXT=off ./preview.sh   the "Show message text in alerts" off variant
set -euo pipefail

text="${TEXT:-on}"

notify() { # title subtitle body
  osascript - "$1" "$2" "$3" <<'OSA'
on run argv
  display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
end run
OSA
}

agent() { # glyph session meta text-body
  if [ "$text" = on ]; then
    notify "$1 $2" "$3" "$4"
  else
    notify "$1 $2" "" "$3" # without text the meta line is the body
  fi
}

show() {
  case "$1" in
    approval) agent "✋" "refactor-auth" "Approval · ai-fleet · tab 1 · Codex" \
      "› Split CodexAuthentication into a reader and a writer and keep the tests green"$'\n'"I have split the file into CodexAuthReader and CodexAuthWriter. Next I want to run the full test suite to confirm nothing regressed." ;;
    question) agent "💬" "jump-latency" "Question · ai-session-hub · tab 2 · pane 2 · Claude" \
      "Should I pre-warm the helper when the menu opens, or keep one warm helper for the whole app lifetime? The first Jump pays for a cold JXA helper start (about 2.8 s); later ones reuse it."$'\n'"› Find out why Jump sometimes takes 3+ seconds on the first click" ;;
    blocked) agent "⛔" "release-notes" "Blocked · hop · tab 5 · Codex" \
      "I cannot continue: gh is not authenticated in this shell (HTTP 401), so I cannot read the merged PR list. Run gh auth login and tell me to retry."$'\n'"› Draft release notes for v0.9 from the merged PRs" ;;
    done) agent "✅" "quota-poller" "Done · ai-fleet · tab 3 · Claude" \
      "› Make the Claude quota poller back off after a 429 instead of retrying every 2 seconds, and add a…"$'\n'"Done. The poller now backs off exponentially after a 429 (2 s, 4 s, … capped at 5 min) and resets after the first successful read. Added ClaudeQuotaPollerTests.testBackoffAfterRateLimit; make check passes. One thing to review: the cap is hard-coded, tell me if you want it in Settings. I also…" ;;
    quota) notify "🪫 Codex A · 25% left" "5h window" "Resets in 2h 10m · Nov 21 at 18:30" ;;
    test) notify "🔔 Test · AI Fleet" "" "Notifications are working." ;;
    *) echo "Unknown type: $1 (use approval, question, blocked, done, quota or test)" >&2; exit 2 ;;
  esac
}

if [ $# -gt 0 ]; then
  for type in "$@"; do show "$type"; done
else
  for type in approval question blocked done quota test; do
    show "$type"
    sleep 6 # one banner at a time, long enough to hover and expand it
  done
fi
