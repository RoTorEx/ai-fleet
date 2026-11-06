# Switch policies and recovery

Codex and Claude use one switch coordinator. Other providers retain their existing
next-launch adapters. The selected identity, authentication and quota availability
are separate observations. A quota transport failure does not establish logout.

## Policies

Each provider stores its policy in `switch.policy.<provider>`; missing or invalid
values use graceful stop. Next launch changes only the command selection. Wait
sends no signal and waits at most 60 seconds. Graceful stop confirms the process
list, sends SIGTERM and waits at most 10 seconds. Force quit confirms separately,
sends SIGKILL and waits at most 3 seconds. Graceful stop never escalates itself.
These application-defined bounds prevent an unresponsive process from leaving
Switch waiting indefinitely; they are not provider deadlines.

Automatic stopping is restricted to the outgoing account's validated ownership
sidecars. They identify provider/account/profile and PID/start time, retaining the
older PID marker format for authentication guards. A process without a verified
binding blocks a stopping/waiting transition; project paths and executable names
cannot establish an account. The user may select that exact process manually in
Processes. Provider-wide manual actions explicitly warn about other accounts.
PID, UID, executable and start time are revalidated before each signal.

Two empty scans separated by 0.5 seconds are required, followed by a final scan
after target revalidation. Respawn, unreadable inventory or unknown ownership
prevents committing the selection. Stopping an in-flight request is irreversible;
saved credentials and conversation history are not removed. Cancellation preserves
the selection but cannot restart stopped work.

The supported `--fleet-select-codex ACCOUNT_UUID` command remains a synchronous,
noninteractive next-launch selection; it never stops sessions or opens a dialog.

## Concurrency and credentials

A per-provider advisory file lock excludes new Fleet-managed launches while a
transition is active. Launches hold a shared lock until exec; descriptors close
on exec or process exit. Direct native, custom-home and remote invocations remain
outside Fleet's lock. An external process discovered before commit blocks it.
Fleet's pending quota scans are cancelled and joined before validation; new status
refreshes and conflicting authentication actions are gated until the operation
ends. The target is checked again immediately before committing. Restart does not
resume a pending stop; OS locks release automatically on process exit.

Codex checks saved email/workspace and native login status with the exact file
credential home. Claude checks native structured auth status and matching email
with the profile's exact environment/Keychain selector. Failure requests Sign in
without changing selection or stopping old processes. This is not proof of a
successful paid request or server acceptance of cached credentials.

## Verification and remaining acceptance

SwitchRecoveryTests covers account isolation, unknown ownership, stale/ambiguous
markers, lock exclusion/release, respawn and cancellation. Existing process tests
exercise real owned fixtures with SIGTERM and SIGKILL. Quota parser, cooldown,
identity and authentication regression suites remain required through make check.

The stage still requires joint acceptance on real Codex and Claude accounts:
closed-terminal surviving process, switch in an already open terminal, correct
quota identity, and CLI resume of a saved conversation. No model request or user
process termination is authorized merely by preparing the implementation.

Inventory recognizes native codex and codex-code-mode-host, native Claude including
its version-named installed binaries, and Node processes whose entry script exactly
matches an installed provider executable. Other generic runtimes are not attributed
by their name. Detached helpers without a validated ownership marker remain unknown
and require explicit manual selection, as required by the account-only policy.
