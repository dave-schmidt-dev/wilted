# Wilted motif incorporation guide

**Date:** 2026-10-12. **Status:** owner-approved; nothing in this package is integrated into the app yet.

The package holds two approved Wilted designs as flattened SVGs with contact-strip frames and machine data. Motion, colors, sizes and acceptance data live in [`approved.json`](approved.json); pixel-match evidence lives in the package's `verify.json`. Approval came from the 2026-10-12 design comparison gallery.

**Supersedes:** where this package overlaps the untracked `docs/loading-motif/` draft (2026-10-11), this package wins; that draft is not authoritative.

## Approved elements

| id | title | approved option | kind | sizes | multicolor | primary asset |
| --- | --- | --- | --- | --- | --- | --- |
| `loading-larder-serpentine` | Loading / retry: Larder shelf serpentine | A, Larder shelf serpentine | animated | 20, 64 px | no | `assets/loading-larder-serpentine-64-dark.svg` |
| `feed-refresh-circular-arrow` | Feed refresh action: Circular arrow | A, Circular arrow | static | 20, 64 px | no | `assets/feed-refresh-circular-arrow-64-dark.svg` |

No stock/SF Symbol picks; both elements ship assets. The primary column names the dark 64 px file; the light pair and both sizes are listed in the inventory at the end.

## Where each element goes

### loading-larder-serpentine

Replaces the current W-path startup artwork in `Shared/WiltedLoadingMotif.swift:87`. The only two motif call sites in this checkout are startup loading:

- Mac: `WiltedMac/Views/WiltedMacRootView.swift:208`, inside `startupLoading` (`:204`).
- iOS: `WiltediOS/Library/LibraryListView.swift:59`, gated by `!model.localStateLoaded` (`:57`).

Retry actions are separate controls that today use SF Symbols, for example `WiltedMac/Views/WiltedMacLarderView+Rows.swift:178`; the motif itself appears only in the two waits above. Tests that pin the current implementation and call shapes: `WiltedMacTests/WiltedLoadingMotifTests.swift:8`, `WiltedMacTests/WiltedMacStartupProgressTests.swift:39`, `WiltediOSTests/LibraryLoadingMotifTests.swift:32`.

### feed-refresh-circular-arrow

Host: the Feeds page refresh action, `refreshHeader` in `WiltedMac/Views/WiltedMacFeedsView.swift:241`, mounted at `:90`. It is text-only today:

- action: `Button("Refresh") { model.refreshPodcastFeeds() }` at `WiltedMac/Views/WiltedMacFeedsView.swift:257`, identifier `wilted-podcast-refresh` at `:258`;
- in-flight: `ProgressView()` at `:246`, which stays the activity indicator.

Put the 20 px glyph on that Refresh control. The iOS list pull-to-refresh (`WiltediOS/Library/LibraryListView.swift:165`) is a system control and cannot take custom artwork, so it is not a call site. Other refresh/retry controls keep their SF Symbols for now, for example `WiltedMac/Views/WiltedMacLarderView+Rows.swift:205` and `WiltediOS/Library/LibraryRowControls.swift:65`.

## How to implement

Stack: SwiftUI. `Shared/` is compiled into both the Mac and iOS apps (`project.yml:43`, `project.yml:127`), which is where the shared motif lives.

### feed-refresh-circular-arrow (static, single ink)

- Import the template SVGs as imagesets in a catalog both targets compile, for example `Shared/WiltedSymbols.xcassets`, with `"preserves-vector-representation": true` and `"template-rendering-intent": "template"`. The existing `Wordmark` imageset is the pattern (`WiltediOS/Assets.xcassets/Wordmark.imageset/Contents.json:23`) and `Shared/WiltedWordmark.swift:45` shows how it is read.
- Use `assets/feed-refresh-circular-arrow-20-template.svg` for the header; keep the 64 px asset for standalone placements. Never scale the 64 px art down to 20.
- Every `colors[]` layer is `--accent`, an exact match for the existing `.wiltedLeaf` token (`Shared/WiltedTheme.swift:20`; dark `#7FD48C` at `:90`, light `#4D6B22` at `:106`). No layer lacks a token. The Mac's global accent already carries this pair (`project.yml:72`); iOS tints explicitly as `WiltediOS/Library/LibraryListView.swift:98` does.
- Accessibility: when the glyph is the only visible label, use `a11yLabel` (`Feed refresh action: Circular arrow`; the SVG has no `aria-label`, so the call site must supply it); when it sits beside the visible "Refresh" title, hide it as decorative. Icon-only buttons need `.help` on Mac (`WiltedMacTests/WiltedMacIconHelpTests.swift:5`) and `.accessibilityLabel` on iOS (`WiltediOSTests/LibraryIconLabelTests.swift:9`).

### loading-larder-serpentine (animated, single ink)

- The SVGs are the flattened settled frame; the animation is not baked in. Draw the serpentine natively as a `Shape`, per size: the 20 px form has its own geometry and heavier strokes, so do not scale the 64 px path down.
- Static layers (larder rect, shelves, slats) sit at 0.58 opacity in `.wiltedLeaf` as above.
- Motion from `approved.json`: one 18-unit dash with an 82-unit gap on a `pathLength=100` closed outline; `strokeDashoffset` 0 to -100 linearly over `cycleMs` 1600, infinite. Drive it from the platform timeline as the current motif does: `TimelineView(.animation(paused: reduceMotion))` at `Shared/WiltedLoadingMotif.swift:95`, with `dashPhase = -fraction * length` like the existing dash at `Shared/WiltedLoadingMotif.swift:76-79`.
- Indeterminate only. Do not route the Mac's counted `startupMotifProgress` (`WiltedMac/Views/WiltedMacRootView.swift:197`) through the dash, and do not announce a percentage as the current `accessibilityValue` does (`Shared/WiltedLoadingMotif.swift:101`). The phase text at `WiltedMac/Views/WiltedMacRootView.swift:209` already names counted recovery in words.
- Reduce motion: show the settled frame exactly (cycle time 0, dash at the path start at the top-left corner, larder at 0.58 opacity). The settled SVG assets are that frame.
- Use `a11yLabel` (`Loading / retry: Larder shelf serpentine`); the page SVG has no `aria-label` (`a11yLabelSource` is the title), so the call site must supply the label. Where surrounding copy already names the wait (`Text("Opening your larder…")` at `WiltediOS/Library/LibraryListView.swift:60`), the artwork can be decorative.
- Use the 20 px asset for compact placements and the 64 px asset in the startup well. The element is `drivenBy` `js`, but both exported forms are SVG, so no HTML/CSS form needs reproducing (`notExportedAsSvg` is absent); neither size is resized markup.

Caveats that do not apply: neither element has `outsideViewBox` geometry, so no standalone padding is required; both ship dark and light, so there is no single-theme surface; both are single ink, which is why templates exist.

## Acceptance checks

Framework: XCTest. Mac unit tests live in `WiltedMacTests/`, iOS unit tests in `WiltediOSTests/`. Offscreen render helpers: `WiltedMacHeadless.render` (`WiltedMacTests/WiltedMacHeadlessJourneySupport.swift:62`) for the Mac and `ImageRenderer` (`WiltediOSTests/LibraryLoadingMotifTests.swift:41`) for iOS.

1. Render each element at both sizes and both appearances. Use `frames/loading-larder-serpentine-<theme>.png` and `frames/feed-refresh-circular-arrow-<theme>.png` as the visual acceptance reference; `verify.json` records the settled-asset tolerance (2 channel levels).
2. Reduced motion: render the motif with reduce motion on and assert it matches the settled frame. Precedent: `WiltedMacTests/WiltedLoadingMotifTests.swift:51` and `WiltediOSTests/LibraryLoadingMotifTests.swift:56`.
3. Accessibility: assert the chosen labels. The icon-button audits at `WiltedMacTests/WiltedMacIconHelpTests.swift:5` and `WiltediOSTests/LibraryIconLabelTests.swift:9` scan the views.
4. Animated frames: render the serpentine at least at a few `sampleTimesMs` (`0, 200, 400, 800, 1200, 1550, 1599, 1600`), assert waiting frames differ (precedent `WiltedMacTests/WiltedLoadingMotifTests.swift:48`), and that 1600 equals 0. Frames were captured with `seek(t, 0)`, so seek time equals cycle time.
5. Baselines: the Feeds page pixel baseline (`WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests/testFeedsRowPixelBaselines.mac-shell-feeds-row-light.png`, with the `-dark` pair) includes `refreshHeader`, so re-record it with `scripts/record-mac-snapshots.sh` (`WILTED_RECORD_SNAPSHOTS=1` at `scripts/record-mac-snapshots.sh:74`). iOS pixel baselines use `scripts/record-ios-snapshots.sh:85`.
6. Update source-string tests that pin the old motif: `WiltedMacTests/WiltedMacStartupProgressTests.swift:39`, `WiltediOSTests/LibraryLoadingMotifTests.swift:32`, and the geometry assertions in `WiltedMacTests/WiltedLoadingMotifTests.swift:8`.
7. Per change run `make native` (`Makefile:34`, which runs `scripts/test-gate.sh`). Screen-seizing UI automation is a release-milestone step only: `make native-ui` (`Makefile:47`) drives real HID events and is not part of a per-change run.

## Asset inventory

`loading-larder-serpentine`

- `assets/loading-larder-serpentine-20-dark.svg`, `assets/loading-larder-serpentine-20-light.svg`
- `assets/loading-larder-serpentine-64-dark.svg`, `assets/loading-larder-serpentine-64-light.svg`
- `assets/loading-larder-serpentine-20-template.svg`, `assets/loading-larder-serpentine-64-template.svg`
- `frames/loading-larder-serpentine-dark.png`, `frames/loading-larder-serpentine-light.png`

`feed-refresh-circular-arrow`

- `assets/feed-refresh-circular-arrow-20-dark.svg`, `assets/feed-refresh-circular-arrow-20-light.svg`
- `assets/feed-refresh-circular-arrow-64-dark.svg`, `assets/feed-refresh-circular-arrow-64-light.svg`
- `assets/feed-refresh-circular-arrow-20-template.svg`, `assets/feed-refresh-circular-arrow-64-template.svg`
- `frames/feed-refresh-circular-arrow-dark.png`, `frames/feed-refresh-circular-arrow-light.png`

Package files: `approved.json` (element data), `verify.json` (SVG-swap pixel match).
