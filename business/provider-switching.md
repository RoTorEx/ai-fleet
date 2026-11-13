# Provider-independent account switching

## User contract

Switch selects the account for the next ordinary provider command. Codex and
Claude additionally support explicit wait, graceful-stop and force-quit policies;
[Switch recovery](switch-recovery.md) owns their scope, defaults and deadlines.
Next-launch-only mode retains existing sessions and credential homes. Other
providers retain next-launch-only behavior. No policy migrates an in-flight
request, opens a terminal or starts a conversation. Sign in connects a login and
Sign out remains separate.

The default selection and lowest-quota recommendation are independent. Neither
quota measurement nor account sign-in changes the selection automatically.

## Command integration and adapters

Fleet installs only its own command shims in ~/.local/bin. They invoke the
installed app's terminal entry point and read the current selection on every
invocation. Native executables remain intact and receive normal package-manager
updates. Detection skips Fleet shims. ~/.local/bin must precede the native CLI in
PATH. Already-open zsh terminals need rehash once after initial installation;
subsequent Switch operations need no command or terminal restart. Install the
known provider command names together so choosing another provider does not
require separate shell setup. A conflicting executable or redirected path is
refused. Without a selection, the shim delegates unchanged to the native CLI.

The Codex adapter is owned by [Codex authorization](codex-profiles.md). Other
adapters store no-secret selection records under
~/Library/Application Support/AI Fleet/ProviderLaunch/<provider>.json and profile
metadata under terminal.providerProfiles/terminal.providerSelections preferences.
Account IDs must be UUIDs or the reserved legacy `default` ID. A migrated
labelled account can retain `default`; its Sign in and Switch use the same
validation as other accounts. Directories are derived locally, never accepted
from a selection file. Arbitrary names and path fragments remain invalid.
The configuration root for an independent account is
~/Library/Application Support/AI Fleet/ProviderProfiles/<provider>/<account-ID>.

- Claude uses CLAUDE_CONFIG_DIR directly. Native Claude handles the matching
  profile-specific Keychain login; Fleet never clones another Keychain entry.
  Its original default home keeps the selector unset: explicitly supplying even
  ~/.claude changes the Keychain service and would hide the existing login.
- Kimi uses KIMI_CODE_HOME directly. Config and OAuth storage remain native.
- Qwen uses QWEN_HOME directly. Explicit QWEN_RUNTIME_DIR stays an intentional
  override; normal profile launches keep their native runtime under that home.
- Gemini uses GEMINI_CLI_HOME as a parent directory: its actual files are under
  <parent>/.gemini. The quota reader uses that same actual directory.

If an observed signed-in native email uniquely matches the account, its existing
home can remain that account's source. Otherwise a separate profile is prepared.
No existing credential is copied and Switch does not claim that a fresh profile
is signed in. Native CLI sign-in may be required on its first launch. A native
Claude account identity that has changed externally is rejected before dispatch.
Other integrations retain their own identity-validation limits.

Explicit authentication/directory environment overrides and explicit server
management commands retain native scope; Fleet never silently replaces a user's
chosen custom backend or remote-server connection. Help/version/update commands
remain available independently of account selection. Ordinary API-key overrides
are intentional native authentication, not another Fleet subscription login.

## Login, history and measurements

Claude and Kimi browser login run the unmodified native CLI with the selected
private home and sanitized authentication overrides. The current default is not
changed. A failed login cannot replace an existing profile association. Gemini
and Qwen complete interactive native sign-in on the first command after Switch;
Fleet does not create a terminal for that step. Real browser/SSO completion is
not established by fixture tests.

Known session/history/skills paths reference existing native data when available.
Existing independent files are preserved. Authentication files, Claude's mixed
account settings, and provider-specific authentication configuration are never
linked or copied across accounts. Independent account settings remain native;
this is not a promise that every provider-specific preference is shared. Codex
has the broader explicit shared-state contract documented in its adapter.

The existing quota loop measures private connections independently. Claude's
native status and Gemini's server identity must match an expected email before
quota is attributed. Qwen remains local-auth-only with quota unsupported. Kimi's
reader retains its documented format/identity limits; isolated launch support
alone does not establish compatibility with every new credential format.
Measurements for another identity are suppressed, never reassigned. A global
refresh or sign-out cannot overwrite an independently measured account's limits.
Authentication changes join earlier refreshes so a token refresh cannot restore
credentials after a private sign-out.

Terminal session markers bind PID and start identity. Private login/logout refuses
while that home has a registered live consumer; ordinary Switch remains allowed.
Sign-out clears only the selected profile. Removing an account clears its default
selection before forgetting metadata, while preserving credentials/history.

## Verification and sources

ProviderTerminalLaunchTests runs the same Switch contract for all four adapters
with synthetic accounts and a live task-owned process, verifies unchanged old
process environment, per-provider persistence, Gemini's parent-home distinction,
explicit overrides, unchanged credentials/settings and identity-safe measurement.
CodexTerminalLaunchTests covers the Codex adapter. Installed checks verify command
resolution, native version passthrough and the Switch action. These do not prove
cross-account model execution or browser sign-in for every provider. Qwen is not
installed on the current verification Mac.

Primary contracts:

- [Claude environment variables](https://code.claude.com/docs/en/env-vars)
- [Kimi environment variables](https://moonshotai.github.io/kimi-code/en/configuration/env-vars.html)
- [Qwen settings and directories](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/settings/)
- [Gemini configuration](https://geminicli.com/docs/reference/configuration/)

The installed Claude, Kimi and Gemini entry points were inspected. Gemini's
getGlobalGeminiDir appends .gemini to its environment-selected parent; treating
GEMINI_CLI_HOME as the credential directory itself would monitor the wrong login.
