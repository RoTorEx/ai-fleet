# Quota and recovery investigation

## Evidence and fixes

The source review found three reproducible failure paths: a named Claude profile
could resolve quota credentials from the default directory when auth status
omitted configDirectory; CLI stdout could fill its pipe while Fleet waited for
exit before reading it; account-usage cleanup could wait forever after sending
SIGTERM to an app-server that ignored it. Regression fixtures cover exact profile
selection, 1 MiB output and bounded cleanup of an owned non-cooperative child.
A separate malformed numeric quota fixture protects against trapping Int
conversion. These findings do not prove that any one caused the reported incident.

The available local DiagnosticReports directory contained a codex report dated
31 October 2026 with EXC_CRASH/SIGABRT. Its faulting stack contains Rust panic and
stdio printing frames; no AI Fleet crash report was found in that directory.
This establishes a native CLI abort, not an automatic account change or its cause.
No credentials, transcript text or raw crash report is included here.

## Remaining acceptance

Tasks 1 and 2 remain open until the installed application's actual Claude and
corporate Codex quota state is checked and the reported failure is reproduced
or otherwise explained with evidence. Selection and running-session identity
remain separate. No repair deletes credentials/history, stops user agents or
changes selected accounts. The local app can be installed and inspected under
the user's current authorization; public release is not authorized.

## Installed observation

Commit ebc34f1 was installed at /Applications/AIFleet.app. Both installed
executables match the built bundle and strict signature verification passed.
The actual menu shows five providers and one measured connection out of six.
Native default Claude auth independently reports loggedIn=false, authMethod=none
and exit 1. A second Codex connection and Gemini remain unverified; Kimi reports
a network failure. These states are observations, not successful quota restoration.
All pre-existing provider selection values were preserved; startup added a
previously absent Gemini selection entry. No explicit login or switch occurred.
The old installed bundle is retained under construction_side/ai-fleet.noindex/
rollback-before-quota-recovery-4a for rollback until this batch is accepted.

The required suite passed with 167 Swift tests and 22 Rust tests. The actual
installed menu screenshot is retained privately on the local AI desk; it is not
part of the public repository. Future work proceeds in pairs with local app
updates and visible review, while combined recovery acceptance remains outstanding.
