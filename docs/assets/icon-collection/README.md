# AI Fleet icon collection

## Preserved: ship-v4

Used in v1.2.10; retained here for reuse. The front-facing ship has curved sides, a visible bridge, and a hull
clipped at the wave. The app icon uses a dark blue tile and turquoise water.

- `ship-v4/Preview.png`: approved comparison sheet.
- `ship-v4/app-icon.svg` and `ship-v4/menu-bar.svg`: editable vectors.
- `ship-v4/design.json`: drawing geometry.
- `ship-v4/draw.swift`: standalone AppKit renderer. Run
  `swift docs/assets/icon-collection/ship-v4/draw.swift /path/to/output`
  with `design.json` copied into that output directory to regenerate the PNGs.

To reuse ship-v4, regenerate its PNGs from the preserved renderer and restore
its geometry in the native menu-bar drawing. Keep both sets in the collection.

## Current: clipper-v1.2.9

The original clipper is restored in v1.2.11 for both the app and the menu bar.
Its complete archived set remains in the collection.

- `AppIcon.appiconset`: original application icon PNGs and size mapping.
- `MenuBarIcon.swift`: exact original native menu-bar drawing, including its
  template flag. This was the actual menu-bar producer through v1.2.9.
- `menu-bar-18.png`, `menu-bar-36.png`, `menu-bar-512.png`: exports of that native
  drawing for inspection and recovery.
- `FleetIcon.imageset` and `SwiftPM-FleetIcon.imageset`: unchanged original
  asset directories. They were retained in the project but the runtime menu
  used the native drawing above.

Active app PNGs live in `AppBundle/Assets.xcassets/AppIcon.appiconset`.
`Sources/AIFleet/FleetIcon.swift` restores the archived native drawing as an
18-point template; macOS supplies its light/dark appearance color. The two
existing `FleetIcon.imageset` directories also contain their original PNGs.
Do not delete the collection when switching active icons.
