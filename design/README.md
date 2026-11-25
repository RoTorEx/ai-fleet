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
| Notifications | [`notifications/index.html`](notifications/index.html) | Revision 4 accepted 2026-11-22 |
| Quota history | [`quota-history/index.html`](quota-history/index.html) | Click in Providers or select the Quota History tab in Statistics. VPM-40 defines the native plot proportions. |

## Notifications

Open the board with `open design/notifications/index.html`. Append
`?theme=light` or `?theme=dark` to force a theme.

The board approximates the macOS banner. To judge the real system rendering of
the proposed texts (truncation, line count, font weights), run
`design/notifications/preview.sh`; its header lists the options.

## Quota history

The board exercises the interaction and chart states. The chart attached to
VPM-40 sets the native visual geometry. The
[native renderer](../Sources/AIFleet/UI/QuotaHistoryFigure.swift) scales the
1300 × 910 reference and uses the packaged regular DejaVu Sans face with
minimum sizes for chart labels and legends.
[DejaVu Sans release](https://github.com/dejavu-fonts/dejavu-fonts/releases/tag/version_2_37)
