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
| Quota history | [`quota-history/index.html`](quota-history/index.html) | Full charts from the provider row and Statistics |

## Notifications

Open the board with `open design/notifications/index.html`. Append
`?theme=light` or `?theme=dark` to force a theme.

The board approximates the macOS banner. To judge the real system rendering of
the proposed texts (truncation, line count, font weights), run
`design/notifications/preview.sh`; its header lists the options.
