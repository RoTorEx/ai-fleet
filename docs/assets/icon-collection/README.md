# AI Fleet icon collection

## Current: ship-v4

The approved front-facing ship has curved sides, a visible bridge, and a hull
clipped at the wave. The app icon uses a dark blue tile and turquoise water.

- `ship-v4/Preview.png`: approved comparison sheet.
- `ship-v4/app-icon.svg` and `ship-v4/menu-bar.svg`: editable vectors.
- `ship-v4/design.json`: drawing geometry.
- `ship-v4/draw.swift`: standalone AppKit renderer. Run
  `swift docs/assets/icon-collection/ship-v4/draw.swift /path/to/output`
  with `design.json` copied into that output directory to regenerate the PNGs.
- `AppBundle/Assets.xcassets/AppIcon.appiconset`: active application PNGs.
- `Sources/AIFleet/FleetIcon.swift`: native menu-bar vector drawing with an
  18-point template image; macOS supplies the light/dark appearance color.
- The two existing `FleetIcon.imageset` directories retain matching PNG exports.

The runtime vector matches the geometry in `design.json`. When changing the
shape, update the native paths and both SVGs, rerender application/menu PNGs,
and inspect the native template at small sizes as well as the preview.

## Preserved: clipper-v1.2.9

This is the complete icon set replaced in v1.2.10. Keep it in the collection.

- `AppIcon.appiconset`: original application icon PNGs and size mapping.
- `MenuBarIcon.swift`: exact original native menu-bar drawing, including its
  template flag. This was the actual menu-bar producer through v1.2.9.
- `menu-bar-18.png`, `menu-bar-36.png`, `menu-bar-512.png`: exports of that native
  drawing for inspection and recovery.
- `FleetIcon.imageset` and `SwiftPM-FleetIcon.imageset`: unchanged original
  asset directories. They were retained in the project but the runtime menu
  used the native drawing above.

Restore the application PNGs from this archived appiconset and the menu drawing
from `MenuBarIcon.swift` if the clipper is selected again. Do not delete the
collection when switching active icons.
