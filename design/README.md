# Design

Visual and interaction design for AI Fleet lives here, next to the code it
describes, so a design change and its implementation can land together.

Each surface gets a folder with a self-contained `index.html` board: no build
step, no external assets, opened straight from disk. A board shows every state
of the surface on realistic data, names the rules that produce those states,
and lists the decisions still open.

A board is a proposal until the user accepts it. Implementation starts only
after acceptance; the accepted behavior is then recorded in `business/*` or
`docs/features/*`, which remain the source of truth. The board stays as the
visual reference and is updated when the design changes.

| Surface | Board | Status |
| --- | --- | --- |
| App prototype | [`app/index.html`](app/index.html) | Proposal for workflow review |
| Notifications | [`notifications/index.html`](notifications/index.html) | Revision 4 accepted 2026-11-22 |
| Quota history | [`quota-history/index.html`](quota-history/index.html) | Click in Providers or select the Quota History tab in Statistics. VPM-40 is the chart styling reference. |

## App prototype

Open [the prototype](app/index.html) in a browser. The review bar switches
screens, themes, and fixtures. **Reset demo** restores the example data.
Example accounts, sign-in, terminal jumps, process actions, and notification
banners run inside the page. Changes live in memory until reset or reload.

- From **Providers**, click the chart icon on Claude. Inspect a value on the
  weekly line, reveal the legend with the info button, choose a model and
  **Output**, then use **Open in Statistics**. The model and series carry
  over to [Quota History](app/index.html?screen=history).
- In **Token Spend**, switch the provider and period and check the totals and
  provider shares. In **Quota History**, select Codex to see the account
  report period. The hourly charts keep the same 72-hour range.
- In **Agents**, select **Needs you**, open a session's **Context**, and jump
  to its pane. In **Processes**, cancel a stop, then confirm it on the same
  example process.
- From **Settings → Accounts**, add an example account and try its sign-in
  flow. Use a provider's status button to open scoped **Logs** or
  **Notifications** to follow a banner to its destination.

To open a fixture directly, use `?screen=quota&state=empty&theme=light`.
The [roadmap](../ROADMAP.md) tracks the proposed native changes.

## Notifications

Open the board with `open design/notifications/index.html`. Append
`?theme=light` or `?theme=dark` to force a theme.

The board approximates the macOS banner. To judge the real system rendering of
the proposed texts (truncation, line count, font weights), run
`design/notifications/preview.sh`; its header lists the options.

## Quota history

The board exercises the interaction and chart states. The chart attached to
VPM-40 sets the native visual style. The
[native renderer](../Sources/AIFleet/UI/QuotaHistoryFigure.swift) fits all three
charts in a compact stack of fixed-height plots. Chart labels and legends use
the packaged regular DejaVu Sans face at a constant size.
[DejaVu Sans release](https://github.com/dejavu-fonts/dejavu-fonts/releases/tag/version_2_37)
