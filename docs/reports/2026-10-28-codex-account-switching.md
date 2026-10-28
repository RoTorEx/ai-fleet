# Codex account-switching incident and repair

> Historical 1.3.8 report. The user rejected terminal/session launching. That
> implementation has been removed; the current contract is credential save/switch
> in business/codex-profiles.md. No terminal creation is part of the product.

## User impact

Changing the standard Codex login from Personal (α) to Innowise (β) removed live
Personal limits from Fleet and left already-running Codex tasks unable to refresh
their original authentication. Repeated logout/login did not repair those tasks.
The user reported that force-stopping Codex processes restored new launches.
Provider rows also moved β ahead of α after the standard account changed.

## Evidence collected

- The supplied CLI screenshot identifies its server as Local background server
  while the conversation still identifies the original Personal account. The
  subsequent request reports that credentials changed to another account.
- Local inspection found Codex CLI 0.165.0 and a running shared app-server of the
  same version. Its help exposes both `--no-daemon` and explicit daemon restart.
- Fleet metadata contains one independently saved Innowise login and no saved
  Personal login. The shared native `auth.json` currently identifies Innowise.
  Only identity and expiry metadata were inspected; tokens were not printed,
  copied, exported, replaced, or revoked.
- The earlier repair and its guarantees were found in this Fleet conversation.
  The accessible VoxRay history did not contain a separate matching repair.
- Claude's CLI reports a configured Claude subscription login, but the OAuth
  credential available to the quota reader has expired. Configured CLI login
  and usable subscription-limit access are different observations. This repair
  does not claim to renew Claude authorization.

Official OpenAI documentation states that CLI and extension share cached
authorization and that file credentials belong to CODEX_HOME. The installed
CLI's shared-background-server behavior is additional local evidence, not an
assumption inferred from a successful login-status command.

## Causes

1. **Two different storage contracts looked identical.** Innowise had an
   independent home, while Personal was a read-only view of the shared home.
   Fleet did not make that dependence clear at the point of use. Replacing the
   shared login therefore removed the only live source for Personal; the account
   label was never an independently saved login.
2. **Monitoring was mistaken for session switching.** Previous releases added
   isolated browser login and statistics but did not implement selecting an
   account for new terminal sessions. The arrow described observed shared login,
   not a switch action, and a plain terminal `codex` still used the shared home.
3. **The background-server boundary was omitted from recovery guidance.** An
   interactive tab can disconnect while its shared server and tasks remain.
   Re-authenticating the file does not retarget processes already holding another
   identity. This explains the observations; there is no captured pre-stop server
   memory with which to prove the complete internal failure sequence. The user's
   successful force-stop is recovery evidence, not proof that SIGKILL is required.
4. **Sorting encoded selection priority.** The comparator deliberately promoted
   the observed current account. The clarified requirement is stable Greek order
   within each tool, independently of selection and authentication.

## Why earlier verification missed the outcome

The earlier tests established isolated Fleet login/logout and unchanged shared
credential files. They did not establish that every visible row had a separate
login, exercise new terminal sessions under the selected account, or cover a
global console login change while two account sessions were running. Build and
unit-test success were reported as a broader account-switching guarantee than
the evidence supported. Subsequent UI patches retained that architecture gap.
That was an implementation and reporting failure in this task.

## Repair

- Sort tools alphabetically and accounts strictly by badge allocation.
- Persist an explicit launch selection independently of native observed login.
  Use for new sessions changes metadata only. New session selects a project and
  opens a new terminal command using the selected account's own native home,
  explicit file credentials, and `--no-daemon`. Copy session command uses the same
  wrapper in an existing terminal's current directory.
- Validate saved identity before selecting or preparing a launch. A shared-only
  row offers Connect separate login and explains why global login changes affect
  it. An absent saved login never silently falls back to another account.
- Clear inherited authentication/home/SQLite overrides in launched commands.
  No refresh tokens or standard-home configuration are copied between accounts.
- Register launched wrappers under the account home. Fleet refuses login/logout
  for that account while a registered wrapper remains alive. Another account can
  still be selected or launched. Completed wrappers remove their own marker and one-shot
  launcher file. Copied commands retain a reusable private launcher with one
  PID marker per invocation.
- Retain only confirmed shared-login numeric measurements as historical data.
  After a switch, these are stale, timestamped and excluded from current counts,
  Lowest, alerts and token attribution. A cache is not presented as live access.

## Verification

`CodexSessionLaunchTests` executes two actual shell wrappers against a deterministic
CLI fixture, with separate homes and inherited conflicting home/API-key values.
Both keep their homes and project directories while the fixture's shared login
file changes. The test checks `--no-daemon`, credential-store arguments, active
account logout refusal, process completion and wrapper cleanup. Further tests
check persisted selection, mismatched identity rejection, missing-login refusal,
stable badges, historical snapshot restart, stale accounting and identity changes.
A one-off native UI smoke check also exercised the production new-window
entry point in iTerm2 with a harmless fixture executable. It verified the observed
account home and project, then closed only that new test window. No real model
request or credential was used. Existing tests continue covering isolated native browser-login arguments and
shared-home preservation. `make check` is the required complete project check.

These checks do not claim that a real browser login completed or that live paid
model tasks survived an actual account change. No real Codex process was killed,
no global login was changed, and no model task was delegated for this verification.

## Recovery and remaining limits

- Innowise's separate saved login is available. Personal needs one independent
  browser login because it never had one saved. An already-replaced Personal
  credential cannot be reconstructed from limits or account labels.
- The new selection applies only to future Fleet launches. Existing standard-home
  conversations remain in place; they are not migrated or retargeted. Each
  account home has separate native configuration, skills and conversation history.
- Plain external `codex login/logout` can still change the shared home and affect
  processes using it. Fleet cannot intercept arbitrary external commands. Use
  Fleet's launcher or copied command for account-isolated new sessions. Explicitly
  mutating one of Fleet's private homes from outside Fleet is not protected.
- For stale shared-daemon authentication, finish or account for affected tasks
  before using the installed CLI's `codex app-server daemon restart`. It interrupts
  shared-server work. `codex --no-daemon resume` bypasses that server for an
  original-home recovery attempt, but the correct original account and any
  account restrictions still apply. These commands were inspected, not executed.
  Broad `pkill -9` is not the app's recovery mechanism.
- Account revocation, expired credentials that cannot refresh, server outages and
  workspace policy can still cause authentication errors. The bounded guarantee
  is storage and process isolation for Fleet-launched sessions, not the absence
  of all possible provider errors.

Sources: [OpenAI authentication](https://learn.chatgpt.com/docs/auth),
[CODEX_HOME](https://learn.chatgpt.com/docs/config-file/environment-variables),
installed `codex --help`, `codex app-server daemon --help`, and redacted local
account/daemon inspection.
