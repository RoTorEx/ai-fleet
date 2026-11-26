# AI Fleet Roadmap

Make it easy to see which coding account is ready, answer a waiting agent, and inspect quota or usage from the menu.

**Updated** 2026-11-26

**Next** Review the [clickable app prototype](design/app/index.html) with the
[retest paths](design/README.md#app-prototype), then choose improvements for
the [acceptance queue](TASK.md). The rows below are proposals for review.

## Daily workflow

Open the menu to check available accounts. Choose **Needs you** to find a waiting session and jump to its terminal pane. Open a provider's chart when you need its current limits and usage history. A blocked action leads to the relevant recovery step or diagnostics.

## Proposed improvements

| Status | Step | Result or next check |
| --- | --- | --- |
| Planned | Make process recovery reliable | Retain the native action menu through selection, then test Stop, Cancel, and the Force Quit confirmation on a disposable process. [Process actions](Sources/AIFleet/UI/CodexProcessesView.swift) |
| Planned | Explain each Statistics scope | Place period controls with the reports they affect and label account quota and the fixed 72-hour local token view. Exercise an account change with the same provider and model selected. [Statistics](Sources/AIFleet/UI/StatisticsView.swift) · [Quota history](Sources/AIFleet/UI/QuotaHistoryView.swift) |
| Planned | Put the next action next to provider status | Open status details by pointer or keyboard. Give each actionable state one destination for setup, sign-in, retry, or scoped Logs. Use one connection action policy for Providers and Accounts. [Provider menu](Sources/AIFleet/UI/AIFleetMenuView.swift) · [Accounts](Sources/AIFleet/UI/AccountsSettingsView.swift) |
| Planned | Keep waiting sessions visible | Expand affected groups while **Needs you** is active, restore saved group state in **All**, and provide keyboard access to the request or reply preview and the exact terminal jump. [Agents](Sources/AIFleet/UI/AgentsView.swift) |

The [existing acceptance queue](TASK.md#combined-user-acceptance-after-design) owns live account switching, session binding, statistics, and permissions checks. [Account statistics](TASK.md#account-statistics) owns multi-account reporting work.
