#!/bin/bash
# Fire the proposed notification texts as real macOS banners, so the system's
# own truncation, line count and font weights can be judged before any app code
# changes. Banners come from "Script Editor": no Fleet icon, no jump; a click on
# one opens Script Editor.
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

agent() { # glyph+provider+project, session name, text-body ending with the place
  if [ "$text" = on ]; then
    notify "$1" "$2" "$3"
  else
    notify "$1" "$2" "${3##*$'\n'}" # without text the body is the place line alone
  fi
}

show() {
  case "$1" in
    approval) agent "✋ Codex" "Check BMW 90 documents" \
      "The activation code is ready. Next I want to write config.nfm to the mounted USB DISK volume; nothing else on the drive changes."$'\n'"› Prepare the USB drive for the map update"$'\n'"tab 1" ;;
    question) agent "💬 Claude · ai-fleet" "jump-latency" \
      "Should I pre-warm the helper when the menu opens, or keep one warm helper for the whole app lifetime? The first Jump pays for a cold helper start (about 2.8 s); later ones reuse it."$'\n'"› Find out why Jump sometimes takes 3+ seconds on the first click"$'\n'"tab 2 · pane 2" ;;
    blocked) agent "⛔ Codex · hop" "release-notes" \
      "I cannot continue: gh is not authenticated in this shell (HTTP 401), so I cannot read the merged PR list. Run gh auth login and tell me to retry."$'\n'"› Draft release notes for v0.9 from the merged PRs"$'\n'"tab 5" ;;
    done) agent "✅ Claude" "Restructure the harness and skills" \
      "Done. The kernel now holds one short approval rule and guides/approvals.md has the step format with a table per client. Locks are set where the client supports them; I checked each against its documentation. Two trial runs on the…"$'\n'"› Fold the approval rules into one kernel rule and list what each…"$'\n'"tab 4 · Personal AI" ;;
    quota) notify "🪫 Codex A · 10% left" "5h window" "Resets in 2h 10m · Nov 22 at 18:30" ;;
    test) notify "🔔 AI Fleet · test" "" "Notifications are working." ;;
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
