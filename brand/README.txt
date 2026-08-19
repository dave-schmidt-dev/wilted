Wilted vector source pack
=========================

Source of truth colors:
- Dark page:        #0D110F
- Light page:       #F4F7F3
- Dark primaryText: #ECF2ED
- Light primaryText:#141815
- Dark wiltedLeaf:  #7FD48C
- Light wiltedLeaf: #4D6B22

Files:
- wilted-mark-master.svg
  Transparent balanced D6 single-stroke W mark.
- wilted-icon-dark.svg / wilted-icon-light.svg
  1024 × 1024 editable app-icon masters.
- wilted-wordmark-ios-*.svg
- wilted-wordmark-macos-*.svg
  Same outlined geometry, labeled separately for asset organization.
- wilted-vector-master.svg
  One source board with both icon and wordmark treatments.

Notes:
- The original concept boards were raster-generated, so these are clean vector
  reconstructions of the selected balanced D6 direction rather than extracted paths.
- The wordmark uses outlined EB Garamond-derived letterforms with a custom leaf
  replacing the dot on the i. No font is required to render the SVGs.
- Keep the mark solid: don't use progress/status colors inside the brand mark.
- The wordmark files are copied verbatim into WiltedMac/Assets.xcassets/Wordmark.imageset
  and WiltediOS/Assets.xcassets/Wordmark.imageset as light/dark pairs, and rendered by
  Shared/WiltedWordmark.swift. That view hard-codes the ink bounding box (623 x 230 at
  83,21 on the 1120 x 330 artboard) so it can crop the artboard's asymmetric margins.
  Re-cut the wordmark and those constants must be re-measured in the same change:
  magick -background none -density 600 <svg> -resize 1120x png:- | magick - -format %@ info:
