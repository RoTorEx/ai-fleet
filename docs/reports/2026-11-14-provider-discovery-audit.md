# Provider discovery audit — 14 November 2026

## Scope and result

This audit follows local provider processes through session discovery, exact
pane linkage, activity state, the Agents filters, Processes inventory and release
packaging. It covers Codex, Claude, Kimi, Qwen, Gemini and Grok. It does not claim
to audit every provider's cloud authentication, billing, GUI conversations or
all future CLI versions.

The installed 1.4.5 engine returned one Codex session. With the same live
processes, the repaired release-mode engine returned ten linked sessions:
nine Codex and one Kimi. Existing user agents were not restarted, signalled,
reauthenticated or switched. Prompts, responses, environment values and raw
terminal snapshots are not included in this report.

## Findings and repairs

1. **Live agents disappeared after CLI updates.** Eight running Codex images
   belonged to older Homebrew versions. `proc_pidpath` returned ENOENT even
   though the processes and their stdin terminals remained alive. Both the
   upstream session scanner and Fleet's Processes inventory discarded them.
   Only ENOENT now permits the kernel-recorded absolute launch executable as a
   fallback. Permission errors and relative paths remain unavailable. PID/start,
   owner, TTY and ancestry checks remain in place. Process controls re-read the
   identity before signalling, and metadata collection checks start identity.
2. **Additional providers had no session discovery.** The old core recognized
   only Codex and Claude. Discovery now covers all six named providers, known
   package entrypoints, Python launchers and rewritten runtime process names.
   The actual Kimi process uses Node with argv0 `kimi-code` and no remaining
   script entry argument; it is now discovered and linked to its real pane.
3. **Unknown was mislabelled as Idle.** The old Idle filter included every
   session not marked Working or Needs you. Unknown now has a separate filter;
   missing activity evidence cannot become an idle or working claim.
4. **The source owner and embedding boundary matter.** Discovery changes were
   made and checked in AI Session Hub, committed as
   `3100f733e67011d7384bcb2b89d5b9a19e664139`, and imported byte-for-byte with
   updated hashes. Its explicit embedded feature preserves navigation validation
   without enabling standalone Hub usage logging in Fleet.

## Evidence by provider

| Provider | Live native session observed | Automated evidence | Activity/transcript boundary |
| --- | --- | --- | --- |
| Codex | Nine real linked sessions; eight recovered | Real PTY and unlinked binary, native inventory/control, resume and helper exclusion, identity reuse and ambiguous linkage | Existing terminal parser and process-bound transcript reader |
| Claude | No live Claude session during this audit | Real PTY and unlinked binary, native/versioned executable and Node package recognition, print/auth/server exclusions, existing metadata and identity fixtures | Existing terminal parser and process-bound transcript reader; real authenticated session not checked |
| Kimi | One real Node session, recovered and linked | Real PTY and unlinked binary, rewritten title, package/Python launcher, prompt/login/server exclusions | Explicit Unknown; no borrowed Codex/Claude grammar or transcript |
| Qwen | No live Qwen session | Real PTY and unlinked binary, package/native recognition, prompt/auth/server exclusions | Explicit Unknown; authenticated model execution not checked |
| Gemini | No live Gemini session | Real PTY and unlinked binary, package/native recognition, prompt/auth/server exclusions | Explicit Unknown; authenticated model execution not checked |
| Grok | No live Grok session | Real PTY and unlinked binary, package/native recognition, prompt/auth/server exclusions | Explicit Unknown; authenticated model execution not checked |

The real-PTY acceptance check launched six task-owned interactive fixtures and
six task-owned one-shot fixtures. It then unlinked the six executable files.
All interactive identities remained stable and visible, all explicit one-shot
modes remained excluded, and Jump to an unlinked fixture was refused. Only
fixture children were terminated and all fixture files were removed.

Fleet's permanent Swift regression tests also run native fixture executables
for all six providers, remove their executable files while running, verify
continued inventory and stable owner/start identity, and exercise guarded stop
only against those owned fixtures. Tests reject permission-error fallbacks,
relative launch paths, unrelated runtimes, malformed kernel data and reading
an environment field as an argument. Existing tests retain stale snapshots after
scan failure and reject exited/reused identities and ambiguous Jump targets.

## Checks and practical limits

- AI Session Hub `make check`: 53 tests, formatting, Clippy, release build and
  delivery checks passed.
- Fleet `make check`: 199 Swift tests and 25 Rust tests, vendor pin verification,
  public-source audit, signing/release/installer fixtures and build passed.
- Real live-session comparison and six-provider real-PTY acceptance passed.
- The installed candidate’s actual menu displayed Agents 10 and Processes 13,
  including the live Kimi row and separate Unknown filter. A native macOS
  Documents-access prompt appeared after ad-hoc installation; optional project
  metadata remains subject to the user’s privacy consent. No privacy grants
  were changed automatically.
- Quota visibility remains separate from running session discovery. Qwen and
  Gemini's disabled quota preferences are preserved.
- An agent row proves a detected interactive process, not that it is currently
  producing a response. Unknown stays Unknown. Kimi/Qwen/Gemini/Grok work-state
  parsing needs separate evidence from their actual terminal grammars.
- Explicit prompt/auth/server flags are excluded when available. A runtime that
  destroys its original argv reduces mode evidence; stdin/TTY identity is still
  required and its unverified activity remains Unknown.
- SSH, tmux, other terminals, GUI conversations and unreadable process metadata
  remain outside verified coverage. This audit does not promise absence of all
  bugs or compatibility with untested future provider releases.

Primary CLI references used to cross-check headless exclusion:
[Qwen headless mode](https://github.com/QwenLM/qwen-code/blob/main/docs/users/features/headless.md),
[Gemini headless mode](https://geminicli.com/docs/cli/headless/),
[Grok CLI package](https://www.npmjs.com/package/@vibe-kit/grok-cli).
Kimi launch flags were checked against the installed CLI's `--help` output.
