validate_pixel_snapshot_baselines() {
  local root="$1"
  local snapshot_dir="$root/WiltedMacTests/__Snapshots__/WiltedPixelSnapshotTests"
  local expected_count expected_state_ids actual_state_ids state_id state_count
  local expected_variants actual_variants variant_count shell_name bad_pngs
  local expected_selectors actual_selectors duplicate_selectors empty_pngs
  local window_baselines window_name png_path png_name
  local snapshot_test_source snapshot_render_source method

  require_tool file
  [[ -d "$snapshot_dir" ]] || fail "missing Mac pixel snapshot directory: $snapshot_dir"
  snapshot_test_source="$root/WiltedMacTests/WiltedPixelSnapshotTests.swift"
  [[ -f "$snapshot_test_source" ]] || fail "missing Mac pixel snapshot test source: $snapshot_test_source"
  grep -Fq 'assertSnapshot' "$snapshot_test_source" ||
    fail 'Mac pixel snapshot test has no image assertions'
  snapshot_render_source="$root/WiltedMacTests/WiltedPixelSnapshotTests+Rendering.swift"
  [[ -f "$snapshot_render_source" ]] || fail "missing Mac pixel rendering helper: $snapshot_render_source"
  grep -Fq 'NSHostingView' "$snapshot_render_source" ||
    fail 'Mac pixel snapshot test does not render real AppKit views'
  grep -Fq 'WILTED_RECORD_SNAPSHOTS' "$root/WiltedMacTests/WiltedSnapshotContract.swift" ||
    fail 'Mac pixel snapshots have no explicit recording mode'
  grep -Fq 'expectedPixelBaselineCount' "$snapshot_test_source" ||
    fail 'Mac pixel test does not declare its expected baseline count'
  for method in \
    testEveryPreviewStateHasLightAndDarkPixelBaselines \
    testPixelSnapshotSelectorsAreUniqueAndComplete \
    testLibraryAndPreparingBaselinesContainRenderedControls \
    testMacLibraryShellPixelBaselines \
    testMacPlayerShellPixelBaselines \
    testMacSidebarFullPixelBaselines \
    testMacSidebarRailPixelBaselines \
    testMacSidebarCountsPixelBaselines \
    testMacToolbarPixelBaselines; do
    grep -Eq "^[[:space:]]*func[[:space:]]+$method\\(" "$snapshot_test_source" ||
      fail "Mac pixel snapshot test method is missing: $method"
  done
  grep -Fq 'WiltedMacCompactPlayer(model: model)' "$snapshot_test_source" ||
    fail 'Mac player baselines do not render the shipping compact player'
  for identifier in \
    wilted-compact-player wilted-player-speed wilted-player-rewind \
    wilted-player-play-pause wilted-player-forward \
    wilted-player-transcript wilted-player-notes wilted-player-menu wilted-player-route-recovery \
    wilted-player-volume wilted-player-scrubber wilted-player-previous \
    wilted-player-next wilted-player-restart wilted-player-keyboard-transports \
    wilted-player-status wilted-player-transcript-expanded \
    wilted-mac-larder-detail wilted-larder-clear-ready wilted-larder-clear-downloaded \
    wilted-larder-clear-available wilted-larder-mark-completed- wilted-larder-remove- wilted-larder-row-; do
    grep -Fq "$identifier" \
      "$root"/WiltedMac/Views/*.swift "$root/Shared/WiltedRootView.swift" ||
      fail "Mac compact player identifier is missing: $identifier"
  done
  grep -Fq '@FocusState private var keyboardFocus' "$root"/WiltedMac/Views/*.swift ||
    fail 'Mac compact player does not own keyboard focus restoration'
  grep -Fq '@AccessibilityFocusState private var accessibilityFocus' "$root"/WiltedMac/Views/*.swift ||
    fail 'Mac compact player does not own accessibility focus restoration'
  # The sidebar draws its own selected row. A List that also tracks selection
  # stacks AppKit's blue capsule under the leaf-tinted background, and no pixel
  # baseline can catch it: the offscreen renderer does not draw List selection,
  # which is why re-recording every baseline after the fix changed nothing.
  if grep -Eq 'List\(selection:' "$root"/WiltedMac/Views/*.swift; then
    fail 'Mac sidebar List tracks selection, which double-draws the selected row'
  fi
  grep -Fq '.accessibilityAddTraits(isSelected ? [.isSelected] : [])' \
    "$root"/WiltedMac/Views/*.swift ||
    fail 'Mac sidebar does not announce its selected destination to accessibility'
  grep -Fq 'testPodcastPlaybackStaysOutOfArticleSyncAcrossArticleTransition' \
    "$root/WiltedMacTests/WiltedVisualSystemTests.swift" ||
    fail 'Mac podcast/article sync-isolation model selector is missing'
  grep -Fq 'testPodcastPlaybackJourneyAcrossDestinations' \
    "$repo_root/WiltedMacTests/WiltedMacPlaybackJourneyTests.swift" ||
    fail 'Mac persistent compact-player journey selector is missing'

  expected_count=221
  [[ "$(find "$snapshot_dir" -type f -name '*.png' | wc -l | tr -d ' ')" -eq "$expected_count" ]] ||
    fail "Mac pixel baseline count is not $expected_count"
  empty_pngs="$(find "$snapshot_dir" -type f -name '*.png' -size 0c -print)"
  [[ -z "$empty_pngs" ]] || fail "Mac pixel baselines contain empty PNG files: $empty_pngs"

  expected_state_ids=$'cancelling\ncompleted\ndeletedRemotely\ndownloadFailure\nemptyLibrary\nextractionFailure\niCloudUnavailable\nincompatibleRevision\nofflineCached\npaused\nplaying\npreparing-assembling\npreparing-extracting\npreparing-fetching\npreparing-saving\npreparing-synthesizing\nready\nspeechUnavailable\nsyncPending'
  actual_state_ids="$(find "$snapshot_dir" -type f -name '*.png' -print |
    sed -E -n 's/.*\.state-(.*)-(light|dark)-(standard|xxxLarge)-motion-(full|reduced)\.png/\1/p' | sort -u)"
  [[ "$actual_state_ids" == "$(printf '%s\n' "$expected_state_ids" | sort)" ]] ||
    fail 'Mac pixel baselines do not cover exactly the required preview states'
  while IFS= read -r state_id; do
    [[ -n "$state_id" ]] || continue
    state_count="$(printf '%s\n' "$actual_state_ids" | grep -Fxc "$state_id")"
    [[ "$state_count" -eq 1 ]] || fail "duplicate preview state selector: $state_id"
    [[ "$(find "$snapshot_dir" -type f -name "*.state-$state_id-*.png" | wc -l | tr -d ' ')" -eq 8 ]] ||
      fail "preview state does not have the full visual variant matrix: $state_id"
  done <<<"$actual_state_ids"

  expected_variants=$'dark-standard-motion-full\ndark-standard-motion-reduced\ndark-xxxLarge-motion-full\ndark-xxxLarge-motion-reduced\nlight-standard-motion-full\nlight-standard-motion-reduced\nlight-xxxLarge-motion-full\nlight-xxxLarge-motion-reduced'
  actual_variants="$(find "$snapshot_dir" -type f -name '*.png' -print |
    sed -E -n 's/.*\.state-.*-(light|dark)-(standard|xxxLarge)-motion-(full|reduced)\.png/\1-\2-motion-\3/p' | sort -u)"
  [[ "$actual_variants" == "$(printf '%s\n' "$expected_variants" | sort)" ]] ||
    fail 'Mac pixel baselines do not cover exactly the required visual variants'
  while IFS= read -r variant; do
    [[ -n "$variant" ]] || continue
    variant_count="$(find "$snapshot_dir" -type f -name "*.state-*$variant.png" | wc -l | tr -d ' ')"
    [[ "$variant_count" -eq 19 ]] || fail "visual variant is missing preview states: $variant"
  done <<<"$actual_variants"

  expected_selectors=""
  while IFS= read -r state_id; do
    [[ -n "$state_id" ]] || continue
    while IFS= read -r variant; do
      [[ -n "$variant" ]] || continue
      expected_selectors+="state-$state_id-$variant\n"
    done <<<"$expected_variants"
  done <<<"$expected_state_ids"
  expected_selectors+=$'mac-shell-library-light\nmac-shell-library-dark\nmac-shell-player-light\nmac-shell-player-dark\nmac-shell-navigation-selection-light\nmac-shell-navigation-selection-dark\nmac-shell-producer-library-light\nmac-shell-producer-library-dark\nmac-shell-producer-url-focus-light\nmac-shell-producer-url-focus-dark\nmac-shell-sidebar-full-light\nmac-shell-sidebar-full-dark\nmac-shell-sidebar-rail-light\nmac-shell-sidebar-rail-dark\nmac-shell-sidebar-counts-light\nmac-shell-sidebar-counts-dark\nmac-shell-toolbar-light\nmac-shell-toolbar-dark\nmac-shell-add-sheet-link-light\nmac-shell-add-sheet-link-dark\nmac-shell-add-sheet-results-light\nmac-shell-add-sheet-results-dark\nmac-shell-add-sheet-followed-light\nmac-shell-add-sheet-followed-dark\nmac-shell-add-sheet-error-light\nmac-shell-add-sheet-error-dark\nmac-shell-add-sheet-import-progress-light\nmac-shell-add-sheet-import-progress-dark\nmac-shell-add-sheet-import-refusal-light\nmac-shell-add-sheet-import-refusal-dark\nmac-shell-feed-policy-article-light\nmac-shell-feed-policy-article-dark\nmac-shell-feeds-article-row-light\nmac-shell-feeds-article-row-dark\nmac-shell-feeds-row-light\nmac-shell-feeds-row-dark\nmac-shell-larder-kind-filter-light\nmac-shell-larder-kind-filter-dark\nmac-shell-larder-real-size-minimum-light\nmac-shell-larder-real-size-minimum-dark\nmac-shell-larder-real-size-full-light\nmac-shell-larder-real-size-full-dark\nmac-shell-larder-book-row-light\nmac-shell-larder-book-row-dark\nmac-shell-player-chapters-light\nmac-shell-player-chapters-dark\nmac-shell-sidebar-playlists-light\nmac-shell-sidebar-playlists-dark\nmac-shell-playlist-manual-light\nmac-shell-playlist-manual-dark\nmac-shell-playlist-rules-light\nmac-shell-playlist-rules-dark\nmac-shell-settings-reports-light\nmac-shell-settings-reports-dark\nmac-shell-player-bulletin-banner-light\nmac-shell-player-bulletin-banner-dark\nmac-shell-larder-report-row-light\nmac-shell-larder-report-row-dark\nmac-shell-now-playing-pane-light\nmac-shell-now-playing-pane-dark\nmac-shell-section-devices-synthetic-rows-light\nmac-shell-direct-downloads-device-menu-light'
  local section
  for section in general new-episodes preparing ads reports devices about; do
    expected_selectors+="\nmac-shell-section-$section-light"
  done
  expected_selectors="$(printf '%b' "$expected_selectors" | sort)"
  actual_selectors="$(find "$snapshot_dir" -type f -name '*.png' -exec basename {} \; |
    sed -E 's/^.*\.(state-[^.]+|mac-shell-[^.]+)\.png$/\1/' | sort)"
  [[ "$actual_selectors" == "$expected_selectors" ]] ||
    fail 'Mac pixel baseline selectors have missing or unexpected names'
  duplicate_selectors="$(printf '%s\n' "$actual_selectors" | uniq -d)"
  [[ -z "$duplicate_selectors" ]] || fail "Mac pixel baseline selectors are not unique: $duplicate_selectors"

  for shell_name in \
    testMacLibraryShellPixelBaselines.mac-shell-library-light.png \
    testMacLibraryShellPixelBaselines.mac-shell-library-dark.png \
    testMacPlayerShellPixelBaselines.mac-shell-player-light.png \
    testMacPlayerShellPixelBaselines.mac-shell-player-dark.png \
    testMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-light.png \
    testMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-dark.png \
    testShippingMacProducerPixelBaselines.mac-shell-producer-library-light.png \
    testShippingMacProducerPixelBaselines.mac-shell-producer-library-dark.png \
    testShippingMacURLFocusPixelBaselines.mac-shell-producer-url-focus-light.png \
    testShippingMacURLFocusPixelBaselines.mac-shell-producer-url-focus-dark.png \
    testMacSidebarFullPixelBaselines.mac-shell-sidebar-full-light.png \
    testMacSidebarFullPixelBaselines.mac-shell-sidebar-full-dark.png \
    testMacSidebarRailPixelBaselines.mac-shell-sidebar-rail-light.png \
    testMacSidebarRailPixelBaselines.mac-shell-sidebar-rail-dark.png \
    testMacSidebarCountsPixelBaselines.mac-shell-sidebar-counts-light.png \
    testMacSidebarCountsPixelBaselines.mac-shell-sidebar-counts-dark.png \
    testMacToolbarPixelBaselines.mac-shell-toolbar-light.png \
    testMacToolbarPixelBaselines.mac-shell-toolbar-dark.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-link-light.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-link-dark.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-results-light.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-results-dark.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-followed-light.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-followed-dark.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-error-light.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-error-dark.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-import-progress-light.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-import-progress-dark.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-import-refusal-light.png \
    testMacAddSheetPixelBaselines.mac-shell-add-sheet-import-refusal-dark.png \
    testArticleFeedPolicyPopoverPixelBaselines.mac-shell-feed-policy-article-light.png \
    testArticleFeedPolicyPopoverPixelBaselines.mac-shell-feed-policy-article-dark.png \
    testArticleFeedInboxRowPixelBaselines.mac-shell-feeds-article-row-light.png \
    testArticleFeedInboxRowPixelBaselines.mac-shell-feeds-article-row-dark.png \
    testLarderKindFilterPixelBaselines.mac-shell-larder-kind-filter-light.png \
    testLarderKindFilterPixelBaselines.mac-shell-larder-kind-filter-dark.png \
    testLarderBookRowPixelBaselines.mac-shell-larder-book-row-light.png \
    testLarderBookRowPixelBaselines.mac-shell-larder-book-row-dark.png \
    testPlayerChaptersPixelBaselines.mac-shell-player-chapters-light.png \
    testPlayerChaptersPixelBaselines.mac-shell-player-chapters-dark.png \
    testSidebarPlaylistsSectionPixelBaselines.mac-shell-sidebar-playlists-light.png \
    testSidebarPlaylistsSectionPixelBaselines.mac-shell-sidebar-playlists-dark.png \
    testManualPlaylistPixelBaselines.mac-shell-playlist-manual-light.png \
    testManualPlaylistPixelBaselines.mac-shell-playlist-manual-dark.png \
    testPlaylistRuleEditorPixelBaselines.mac-shell-playlist-rules-light.png \
    testPlaylistRuleEditorPixelBaselines.mac-shell-playlist-rules-dark.png \
    testReportsSettingsPixelBaselines.mac-shell-settings-reports-light.png \
    testReportsSettingsPixelBaselines.mac-shell-settings-reports-dark.png \
    testBulletinBannerPixelBaselines.mac-shell-player-bulletin-banner-light.png \
    testBulletinBannerPixelBaselines.mac-shell-player-bulletin-banner-dark.png \
    testLarderReportRowPixelBaselines.mac-shell-larder-report-row-light.png \
    testLarderReportRowPixelBaselines.mac-shell-larder-report-row-dark.png \
    testFeedsRowPixelBaselines.mac-shell-feeds-row-light.png \
    testFeedsRowPixelBaselines.mac-shell-feeds-row-dark.png \
    testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-minimum-light.png \
    testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-minimum-dark.png \
    testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-full-light.png \
    testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-full-dark.png \
    testNowPlayingPanePixelBaselines.mac-shell-now-playing-pane-light.png \
    testNowPlayingPanePixelBaselines.mac-shell-now-playing-pane-dark.png \
    testDevicesSettingsWithSyntheticDeviceRowsPixels.mac-shell-section-devices-synthetic-rows-light.png \
    testDirectDownloadsDeviceMenuPixels.mac-shell-direct-downloads-device-menu-light.png; do
    [[ -s "$snapshot_dir/$shell_name" ]] || fail "missing Mac shell baseline: $shell_name"
  done
  # Component baselines render at card scale. Window compositions render at
  # window scale so the detail region is not cropped, and each size is pinned
  # here so a silent shrink back to the card canvas cannot pass the gate.
  window_baselines=$'testShippingMacProducerPixelBaselines.mac-shell-producer-library-light.png\ntestShippingMacProducerPixelBaselines.mac-shell-producer-library-dark.png\ntestMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-light.png\ntestMacNavigationSelectionPixelBaselines.mac-shell-navigation-selection-dark.png'
  window_baselines+=$'\ntestDevicesSettingsWithSyntheticDeviceRowsPixels.mac-shell-section-devices-synthetic-rows-light.png'
  for window_name in \
    testGeneralSettingsPixels.mac-shell-section-general-light.png \
    testNewEpisodesSettingsPixels.mac-shell-section-new-episodes-light.png \
    testPreparingSettingsPixels.mac-shell-section-preparing-light.png \
    testAdsSettingsPixels.mac-shell-section-ads-light.png \
    testReportsSettingsPixels.mac-shell-section-reports-light.png \
    testDevicesSettingsPixels.mac-shell-section-devices-light.png \
    testAboutSettingsPixels.mac-shell-section-about-light.png; do
    method="${window_name%%.*}"
    grep -Fq "func $method()" "$root/WiltedMacTests/WiltedPixelSnapshotTests+Reports.swift" ||
      fail "missing Mac Settings snapshot method: $method"
    window_baselines+=$'\n'"$window_name"
  done
  while IFS= read -r window_name; do
    [[ -n "$window_name" ]] || continue
    grep -Fq 'PNG image data, 1100 x 700' <<<"$(file "$snapshot_dir/$window_name")" ||
      fail "Mac window-scale baseline is not 1100 x 700: $window_name"
  done <<<"$window_baselines"
  bad_pngs=0
  while IFS= read -r png_path; do
    [[ -n "$png_path" ]] || continue
    png_name="$(basename "$png_path")"
    # Here-strings, not pipes: under pipefail an early-exiting grep -q SIGPIPEs the writer and fails the test at random.
    grep -Fxq "$png_name" <<<"$window_baselines" && continue
    local expected_size='520 x 260'
    case "$png_name" in
      testMacSidebarFullPixelBaselines.mac-shell-sidebar-full-*.png) expected_size='202 x 260' ;;
      testMacSidebarRailPixelBaselines.mac-shell-sidebar-rail-*.png) expected_size='56 x 260' ;;
      testMacSidebarCountsPixelBaselines.mac-shell-sidebar-counts-*.png) expected_size='202 x 260' ;;
      testMacToolbarPixelBaselines.mac-shell-toolbar-*.png) expected_size='224 x 56' ;;
      testMacAddSheetPixelBaselines.mac-shell-add-sheet-*.png) expected_size='520 x 420' ;;
      testArticleFeedPolicyPopoverPixelBaselines.mac-shell-feed-policy-article-*.png) expected_size='520 x 460' ;;
      testArticleFeedInboxRowPixelBaselines.mac-shell-feeds-article-row-*.png) expected_size='520 x 90' ;;
      testFeedsRowPixelBaselines.mac-shell-feeds-row-*.png) expected_size='760 x 440' ;;
      testLarderKindFilterPixelBaselines.mac-shell-larder-kind-filter-*.png) expected_size='760 x 560' ;;
      testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-minimum-*.png) expected_size='520 x 560' ;;
      testRealSizeLarderHeaderPixelBaselines.mac-shell-larder-real-size-full-*.png) expected_size='1000 x 560' ;;
      testLarderBookRowPixelBaselines.mac-shell-larder-book-row-*.png) expected_size='760 x 110' ;;
      testPlayerChaptersPixelBaselines.mac-shell-player-chapters-*.png) expected_size='900 x 480' ;;
      testNowPlayingPanePixelBaselines.mac-shell-now-playing-pane-*.png) expected_size='640 x 740' ;;
      testSidebarPlaylistsSectionPixelBaselines.mac-shell-sidebar-playlists-*.png) expected_size='202 x 180' ;;
      testManualPlaylistPixelBaselines.mac-shell-playlist-manual-*.png) expected_size='760 x 420' ;;
      testPlaylistRuleEditorPixelBaselines.mac-shell-playlist-rules-*.png) expected_size='520 x 620' ;;
      testReportsSettingsPixelBaselines.mac-shell-settings-reports-*.png) expected_size='760 x 560' ;;
      testDirectDownloadsDeviceMenuPixels.mac-shell-direct-downloads-device-menu-*.png) expected_size='360 x 150' ;;
      testBulletinBannerPixelBaselines.mac-shell-player-bulletin-banner-*.png) expected_size='760 x 150' ;;
      testLarderReportRowPixelBaselines.mac-shell-larder-report-row-*.png) expected_size='760 x 110' ;;
    esac
    grep -Fq "PNG image data, $expected_size" <<<"$(file "$png_path")" || {
      bad_pngs=$((bad_pngs + 1))
      printf 'native.snapshots.unexpected-size name=%s\n' "$png_name" >&2
    }
  done < <(find "$snapshot_dir" -type f -name '*.png' -print)
  [[ "$bad_pngs" -eq 0 ]] || fail "pixel baselines contain invalid or zero-size images: $bad_pngs"
  printf 'native.snapshots.baselines count=%s states=19 variants=8 shells=69 window_shells=12\n' "$expected_count"
}
