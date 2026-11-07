# Menu monitoring and local builds

## Menu data

Enabled providers remain visible without an installed CLI or verified login.
Rows sort by provider name, then stable account badge. Setup rows have no saved
account, create no records and only open connection setup. Existing internal
native-default metadata remains readable without consuming a badge.

MonitoringSummary counts saved, labelled connections of enabled providers.
Setup and internal fallback rows are excluded. A current zero quota counts as
measured; stale/unavailable measurements do not. Last checked is the newest
saved-connection observation. This count is unrelated to token statistics:
local tokens remain combined across accounts with optional provider selection.

ProviderStatus carries an optional typed quotaFailure with conservative typed
fallbacks from authentication/quota state. Display text never determines the
failure kind. Account and profile adapters preserve the explicit reason. Native
Claude login remains independent of unavailable/expired usage credentials;
Gemini retains server identity verification and API/Vertex exclusions. Kimi
subscription percentages and Open Platform currency balances remain distinct.

QuotaResetState distinguishes Not reported, upcoming and Reset due. A passed
date never proves quota replenishment. Countdown helpers use injected time,
round positive fractions up to seconds and omit only leading zero d/h/m/s
components (`2h 0m 5s`, `1d 0h 0m 0s`). The menu shows Not reported as `—` and
Reset due as `due`; a reset today shows its time (`10:58`), other days add the
date (`9 Nov 10:58`). Hovering a date swaps the same fixed-width cell to a
live countdown without tooltip, animation or row movement.
MenuLegendSection provides semantic sections for future design composition.

## Stable account badges

The first ten real accounts use α β γ δ ε ζ η θ ι κ. Existing full-alphabet
support remains; ten is a tested capacity, not a maximum. Removed badges are
not recycled. Restarts and provider selection do not renumber accounts.

## Signing and permission diagnosis

`make signing-info` inspects the local bundle and /Applications/AIFleet.app:
identifier, version, architectures, signing metadata, designated requirement
and strict verification. It does not launch the app or change privacy grants.

`make bundle-app CODE_SIGN_IDENTITY='<existing identity>'` selects a signer;
the default `-` is explicitly ad-hoc. Signing proceeds inside out and errors
abort the build. There is no fallback when the selected identity is unavailable.
Certificates, Keychain trust, Developer ID and notarization are separate work.

Observed installed/local ad-hoc bundles have different cdhash-based designated
requirements. This is a plausible contributor to renewed privacy prompts, not
a reproduced explanation for the reported incident. macOS uses designated
requirements to identify signed code across versions; see Apple's
[distribution signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

File access originates in local readers of provider history and the session
engine's process-bound transcript readers. A transcript/project can resolve
inside protected Documents/Desktop paths. iTerm integration in the session
engine uses Automation. These are distinct permissions under System Settings >
Privacy & Security > Files & Folders and Automation. Build tooling running under
a terminal has a different responsible process from the installed app. No TCC
reset, direct TCC database access, quarantine removal, broad disk grant or
protected-folder probe is part of diagnosis. Actual permission persistence
must be checked after a signing identity is available and installation is authorized.

## Distribution

Future releases contain only native arm64 application and engine executables,
packaged as aarch64 ZIP plus checksum and terminal installer. Intel is rejected
before release building and latest installation. Explicit historical Intel
installer versions remain available when their published asset exists. Old
releases are not modified. The updater rejects unsupported architectures before
network access. Stage five does not run a release, publish, install or relaunch.
