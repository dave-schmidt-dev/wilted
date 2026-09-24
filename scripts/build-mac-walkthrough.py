#!/usr/bin/env python3
"""Generates the dated, self-contained Mac daily-driver walkthrough.

The report is generated rather than hand-edited so that a refresh after a UI
change is a rerun, not a retype. Prose lives here; pixels and window geometry
come from the capture directory written by
`WiltedMacUITests/WiltedMacWalkthroughCapture`, which records a JSON sidecar
beside every PNG.

    scripts/build-mac-walkthrough.py --captures DIR --commit SHA --out PATH

Nothing here asserts that a frame shows what its caption says. The captions
describe what the capture test drove; the audit (scripts/audit-walkthrough.sh)
checks structure, embedded-PNG validity, and claim drift.
"""

import argparse
import base64
import json
import pathlib
import sys

STYLE = (
    ":root{color-scheme:dark;--bg:#101412;--panel:#171d19;--line:#364139;--ink:#edf0eb;"
    "--muted:#a9b3aa;--accent:#82bd8c;--warn:#d1aa70}*{box-sizing:border-box}"
    "body{margin:0;background:var(--bg);color:var(--ink);"
    'font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}'
    "main{max-width:960px;margin:auto;padding:38px 22px 76px}h1,h2{line-height:1.15}"
    "h1{font-size:clamp(2.2rem,6vw,4.2rem);margin:.2em 0}"
    "h2{margin-top:3rem;padding-top:1rem;border-top:1px solid var(--line)}"
    "h3{margin:2rem 0 .4rem;font-size:1.05rem}"
    ".eyebrow,.meta,code{font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.04em}"
    ".eyebrow,.meta,.muted{color:var(--muted)}"
    ".toc,.card,.warning,table{border:1px solid var(--line);border-radius:8px;background:var(--panel)}"
    ".toc{display:flex;flex-wrap:wrap;gap:12px;padding:12px 16px;margin:24px 0}"
    ".toc a{color:var(--ink)}a{color:var(--accent)}.card,.warning{padding:16px;margin:14px 0}"
    ".warning{border-left:4px solid var(--warn)}table{border-collapse:collapse;width:100%;overflow:hidden}"
    "th,td{padding:10px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}"
    "th{font-size:12px;text-transform:uppercase;color:var(--muted)}tr:last-child td{border:0}"
    ".chip{display:inline-block;border:1px solid var(--line);border-radius:999px;padding:2px 7px;"
    "font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}"
    "ol,ul{padding-left:22px}li{margin:.25em 0}figure{margin:20px 0 26px}"
    "figure img{display:block;width:100%;height:auto;border:1px solid var(--line);border-radius:8px;background:#000}"
    "figcaption{margin-top:8px;font-size:14px;color:var(--muted)}figcaption strong{color:var(--ink)}"
    "@media print{body{background:#fff;color:#111}main{padding:24px}"
    ".toc,.card,.warning,table{background:#fff;border-color:#777}a{color:#111}figure img{border-color:#777}}"
)


def figure(anchor, frame, alt, caption, captures):
    png = captures / f"{frame}.png"
    if not png.is_file():
        raise SystemExit(f"missing capture frame: {png}")
    encoded = base64.b64encode(png.read_bytes()).decode("ascii")
    return (
        f'<figure id="{anchor}">\n'
        f'<img alt="{alt}" src="data:image/png;base64,{encoded}">\n'
        f'<figcaption><span class="chip">content viewport</span> {caption}</figcaption>\n'
        "</figure>"
    )


def geometry(captures):
    """One geometry line, or a refusal if the frames disagree."""
    sidecars = sorted(captures.glob("*.json"))
    if not sidecars:
        raise SystemExit(f"no geometry sidecars in {captures}")
    shapes = set()
    popovers = []
    for sidecar in sidecars:
        data = json.loads(sidecar.read_text())
        if data.get("kind") == "popover":
            popovers.append((data["name"], data["capturedPixels"]["width"], data["capturedPixels"]["height"]))
            continue
        shapes.add((
            data["window"]["width"], data["window"]["height"],
            data["capturedPixels"]["width"], data["capturedPixels"]["height"],
            data["embeddedPixels"]["width"], data["embeddedPixels"]["height"],
            data["insetPixelsPerEdge"],
        ))
    if len(shapes) != 1:
        return ("Frames were not captured at one geometry: "
                + "; ".join(str(shape) for shape in sorted(shapes))), len(sidecars), None, None
    w, h, cw, ch, ew, eh, inset = shapes.pop()
    window_frames = len(sidecars) - len(popovers)
    line = (f"<code>window={w:g}x{h:g}</code>, <code>captured-pixels={cw}x{ch}</code>, "
            f"<code>embedded-pixels={ew}x{eh}</code>, <code>inset={inset}px per edge</code> "
            f"&mdash; identical across all {window_frames} window frames")
    if popovers:
        line += ("; the " + ", ".join(f"{name} ({pw}x{ph})" for name, pw, ph in popovers)
                 + " frames are popovers, each captured uninset at its own size, because a popover is a window "
                 "of its own and never appears in the main window's frame")
    # Backing scale is observed, not assumed: the capture lands on whichever
    # display the window was restored to, and stating 1x on a Retina run (or
    # the reverse) would be a false claim inside audited evidence.
    scale = round(cw / w, 3) if w else None
    return line, len(sidecars), (ew, eh), scale


def build(captures, commit, date_iso, date_human, previous):
    geometry_line, frame_count, embedded, scale = geometry(captures)
    embedded_text = f"{embedded[0]}x{embedded[1]}" if embedded else "the size recorded in each sidecar"
    if scale is None:
        scale_text = ("Backing scale is not stated here because the frames were not captured at one "
                      "geometry; each sidecar records its own window frame and pixel size.")
    elif scale >= 2:
        scale_text = (f"Captured pixels are {scale:g}x the window's point size, so the window was restored on a "
                      f"Retina display and these frames are backing-store native.")
    else:
        scale_text = (f"Captured pixels are {scale:g}x the window's point size, so the window was restored on a "
                      f"1x display and these frames are not Retina-native. Text legibility, not layout, is what "
                      f"that costs.")
    figures = {
        "feeds-inbox": figure(
            "fig-feeds-inbox", "4.1-feeds-inbox",
            "The Feeds destination showing the New episodes inbox with Keep and Skip on each row",
            "<strong>4.1 Feeds, the inbox.</strong> The destination reached by <code>wilted-navigation-feeds</code>; "
            "its detail pane is <code>wilted-mac-feeds-detail</code>. New episodes "
            "(<code>wilted-feeds-count</code>) is the one question this page asks about anything it lists: Keep "
            "or Skip, nothing else. Each row (<code>wilted-feeds-row-&lt;id&gt;</code>) offers both as buttons "
            "(<code>wilted-feeds-keep-&lt;id&gt;</code>, <code>wilted-feeds-skip-&lt;id&gt;</code>); Keep sends "
            "the episode to the Menu, where downloading, preparing, and playing happen, and Skip retires it "
            "without either. An inbox with nothing new reads &ldquo;Nothing new&rdquo; at "
            "<code>wilted-feeds-empty</code> instead of an empty list.",
            captures),
        "feeds-show-notes": figure(
            "fig-feeds-show-notes", "4.6-feeds-show-notes",
            "The Feeds show-notes popover with the episode's notes and its Keep and Skip decisions",
            "<strong>4.6 Feeds, show notes.</strong> Selecting an episode title at "
            "<code>wilted-feeds-show-notes-&lt;id&gt;</code> opens this popover "
            "(<code>wilted-feeds-notes-popover-&lt;id&gt;</code>) without leaving the inbox. It shows the "
            "notes at <code>wilted-feeds-notes-text-&lt;id&gt;</code>, or "
            "<code>wilted-feeds-notes-unavailable-&lt;id&gt;</code> when the feed supplied none, beside the "
            "same Keep and Skip answers at <code>wilted-feeds-decide-keep-&lt;id&gt;</code> and "
            "<code>wilted-feeds-decide-skip-&lt;id&gt;</code>. Return keeps the episode; Escape closes the "
            "popover.",
            captures),
        "feeds-add": figure(
            "fig-feeds-add", "4.2-feeds-add-feed",
            "The subscribe-composer popover with its feed address field and Subscribe button",
            "<strong>4.2 Feeds, subscribing.</strong> Add feed (<code>wilted-add-feed-button</code>) opens this "
            "popover, a window of its own: one field (<code>wilted-podcast-feed-url</code>) and one button "
            "(<code>wilted-podcast-subscribe</code>), which becomes "
            "<code>wilted-podcast-subscribe-progress</code> and "
            "<code>wilted-podcast-subscribe-cancel</code> while classifying the address, with the result stated "
            "in <code>wilted-podcast-subscribe-status</code>. A page that advertises a feed of its own offers it "
            "separately at <code>wilted-podcast-advertised-feed</code> rather than following it silently. This "
            "frame is the popover's own window, captured at its own size.",
            captures),
        "feeds-off-the-list": figure(
            "fig-feeds-off-the-list", "4.3-feeds-off-the-list",
            "The Off the list region showing a skipped episode with its Restore button",
            "<strong>4.3 Feeds, Off the list.</strong> Task 4.5 folded retirement and dismissal onto one "
            "<code>removalKind</code> column, so this region (<code>wilted-feeds-restorable</code>) is built to "
            "list both kinds together: an episode Skip retired from this inbox, reading &ldquo;Skipped&rdquo; "
            "behind <code>wilted-feeds-restore-skipped-&lt;id&gt;</code>, and an episode dismissed elsewhere, "
            "reading &ldquo;Removed&rdquo; behind <code>wilted-feeds-restore-removed-&lt;id&gt;</code> once one "
            "exists. Both buttons read Restore and both call the same store operation with no network involved "
            "&mdash; nothing was ever deleted, so nothing needs fetching back. This frame captures only the "
            "Skipped kind: the Menu's own Remove button calls "
            "<code>model.removeEpisodeFromUpNext</code>, which only unqueues the episode and returns it to the "
            "Feeds inbox, and the operation that actually produces a dismissed row, "
            "<code>model.removeEpisode(_:)</code>, is exercised only by <code>WiltedMacModelTests</code> and "
            "<code>WiltedVisualSystemTests</code> &mdash; two of those tests assert the call does not appear in "
            "<code>WiltedMacRootView.swift</code> at all. Before Task 4.5 a dismissed episode had no restore "
            "path even at the model level; that gap is closed, but no shipping control currently reaches it, so "
            "the Removed kind is evidenced by the model tests rather than by a pixel here.",
            captures),
        "feeds-management": figure(
            "fig-feeds-management", "4.4-feeds-management",
            "The Feeds destination listing subscribed feeds with per-feed controls",
            "<strong>4.4 Feeds, feed upkeep.</strong> Refresh (<code>wilted-podcast-refresh</code>) sits on the "
            "list it refreshes and becomes <code>wilted-podcast-refresh-cancel</code> beside a progress "
            "indicator while a refresh is running. The policy line "
            "(<code>wilted-podcast-feeds-policy</code>) states the refresh and download policy, and the list "
            "holds one <code>wilted-podcast-feed-row-&lt;id&gt;</code> per subscription, each with a count line, "
            "a show-in-Menu switch (<code>wilted-podcast-feed-enabled-&lt;id&gt;</code>), and an unsubscribe "
            "control. A feed list with nothing subscribed reads its own empty state at "
            "<code>wilted-podcast-feeds-empty</code>.",
            captures),
        "feeds-feed-hidden": figure(
            "fig-feeds-feed-hidden", "4.5-feeds-feed-hidden",
            "The Feeds destination after one show's switch was turned off",
            "<strong>4.5 Feeds, one show hidden.</strong> The switch on the first row "
            "(<code>wilted-podcast-feed-enabled-&lt;id&gt;</code>) was activated during the capture. The row's "
            "count line (<code>wilted-podcast-feed-count-&lt;id&gt;</code>) changes to state the episode is kept "
            "but hidden, and the switch reads off. Hiding a feed does not delete anything: its episodes stay in "
            "the library and return to the inbox when the switch goes back on.",
            captures),
        "menu-idle": figure(
            "fig-menu-idle", "5.1-menu-idle",
            "The Menu destination showing Now Playing idle, the sort and filter controls, and the three groups",
            "<strong>5.1 Menu, idle.</strong> The default destination at launch, restoring here even from a "
            "stored selection that named a retired route. Its detail pane is <code>wilted-mac-menu-detail</code>, "
            "and Now Playing embeds the compact player (<code>wilted-compact-player</code>) directly in the "
            "destination rather than in a separate rail, because Menu is the one destination that expands "
            "Transcript and Notes inline (5.4) instead of into the full-window overlay. Audio on Menu "
            "(<code>wilted-menu-audio-total</code>) and Waiting for you "
            "(<code>wilted-menu-waiting-count</code>) sit beside the independent "
            "<strong>Group by: Status</strong> menu (<code>wilted-menu-grouping</code>), which also offers "
            "Feed and Date, and the always-labelled <strong>Sort by: Custom order</strong> menu "
            "(<code>wilted-menu-sort</code>), which offers Custom order, Newest, Oldest, Length, Show, and "
            "Title. Filter "
            "chips (<code>wilted-menu-filter-all</code> and one per "
            "<code>wilted-menu-filter-&lt;group&gt;</code>) jump to a group's rows, and Download all new "
            "(<code>wilted-menu-download-all</code>) and Prepare all downloaded "
            "(<code>wilted-menu-prepare-all</code>) act across whichever rows are currently visible. While a "
            "bulk run is active, each action shows a spinner with its count at "
            "<code>wilted-menu-download-all-progress</code> (&ldquo;Downloading N&hellip;&rdquo;) or "
            "<code>wilted-menu-prepare-all-progress</code> (&ldquo;Preparing N&hellip;&rdquo;); its button stays "
            "beside the spinner while other rows remain startable. No frame captures this state because no "
            "fixture holds a bulk run open. The three "
            "groups &mdash; Ready, Downloaded, Available &mdash; are the episode steps in order; each carries "
            "its own bulk action and clear (<code>wilted-menu-group-&lt;group&gt;</code>, "
            "<code>wilted-menu-clear-ready</code>, <code>wilted-menu-clear-downloaded</code>, "
            "<code>wilted-menu-clear-available</code>). A row can be dragged to reorder, and a strip below the "
            "last row (<code>wilted-menu-drop-tail</code>) accepts a drop to move an entry to the end. An empty "
            "Menu reads &ldquo;Nothing is waiting&rdquo; at <code>wilted-menu-empty</code> instead of a blank "
            "list.",
            captures),
        "menu-add": figure(
            "fig-menu-add-article", "5.2-menu-add-article",
            "The Add article popover with its address field and Add button, now reached from the Menu",
            "<strong>5.2 Menu, adding an article.</strong> Add article "
            "(<code>wilted-add-article-button</code>) moved here from the retired Larder, opening the same "
            "popover: one field (<code>wilted-link-url</code>) and one button (<code>wilted-add-link</code>), "
            "with <code>wilted-link-status</code> reporting the fetch while Wilted works out for itself whether "
            "the address is an article or a podcast feed. It stays open after Add so a feed the page advertises "
            "(<code>wilted-advertised-feed</code>) arrives where the address was typed. This frame is the "
            "popover's own window, captured at its own size.",
            captures),
        "menu-prepared": figure(
            "fig-menu-prepared", "5.3-menu-prepared-episode",
            "The Menu's Ready group showing a prepared episode's row",
            "<strong>5.3 Menu, a prepared episode.</strong> A successful terminal preparation journal matching "
            "the audio revision ready to play places the episode in the Ready group "
            "(<code>wilted-menu-group-ready</code>, <code>wilted-menu-row-&lt;id&gt;</code>). Under a Status "
            "heading its subtitle is &ldquo;&lt;show&gt; &middot; &lt;release date&gt;&rdquo;; it appends "
            "&ldquo;&middot; &lt;group&gt;&rdquo; only when grouped by Feed or Date, so status is stated once. "
            "Play now (<code>wilted-menu-play-&lt;id&gt;</code>) is the <code>play.fill</code> icon and Played "
            "(<code>wilted-menu-played-&lt;id&gt;</code>) is <code>checkmark.circle.fill</code>; each keeps its "
            "word as its tooltip and accessibility label. A started, unfinished row offers "
            "Mark completed (<code>wilted-menu-mark-completed-&lt;id&gt;</code>) as a <code>checkmark</code>; "
            "unstarted and completed rows have no second completion control. "
            "Remove (<code>wilted-menu-remove-&lt;id&gt;</code>) is <code>minus.circle</code> with the word kept "
            "as its tooltip and accessibility label; it only takes the episode off the Menu's queue and returns "
            "it to the Feeds inbox without marking it completed. The active episode is shown in Now Playing "
            "rather than repeated in Larder. A running preparation shows its progress at "
            "<code>wilted-menu-progress-&lt;id&gt;</code>, drawn in the Downloaded group so the row does not "
            "change groups mid-run.",
            captures),
        "menu-transcript-inline": figure(
            "fig-menu-transcript-inline", "5.4-menu-transcript-inline",
            "The Menu's own compact player with the transcript expanded inline, still inside the Menu destination",
            "<strong>5.4 Menu, Transcript expanded inline.</strong> Activating "
            "<code>wilted-player-transcript</code> while the Menu destination is selected opens "
            "<code>wilted-player-transcript-expanded</code> inside the Menu's own compact player rather than the "
            "full-window overlay every other destination uses for the same toggle (6.2) &mdash; the root view "
            "keeps Menu's inline player mounted and only disables the underlying destination's hit testing when "
            "another destination presents the overlay. This state exists nowhere else in the app.",
            captures),
        "menu-deferred": figure(
            "fig-menu-deferred-prepare-now", "5.5-menu-deferred-prepare-now",
            "The Menu's Downloaded group showing a deferred episode row with its Prepare now control",
            "<strong>5.5 Menu, an off-peak deferral.</strong> The deferred fixture is kept from Feeds and "
            "lands in the Downloaded group (<code>wilted-menu-group-downloaded</code>, "
            "<code>wilted-menu-row-&lt;id&gt;</code>) with the row's off-peak state visible as &ldquo;Waiting for "
            "off-peak&rdquo;. The row offers Prepare now (<code>wilted-menu-prepare-now-&lt;id&gt;</code>) so the "
            "listener can override the window without changing Settings. This frame captures the control before "
            "it is activated; the Mac smoke test drives the activation and verifies that the deferral is removed.",
            captures),
        "playback-rail": figure(
            "fig-playback-rail", "6.1-playback-rail",
            "The bottom rail in its playing state with the full transport row, shown from a non-Menu destination",
            "<strong>6.1 Playback, bottom rail.</strong> Captured from Settings, where the compact player "
            "(<code>wilted-compact-player</code>) renders as the always-visible rail rather than inline, because "
            "only Menu embeds it in the destination itself. Controls present: "
            "<code>wilted-player-status</code>, <code>wilted-player-speed</code>, "
            "<code>wilted-player-previous</code>, <code>wilted-player-rewind</code>, "
            "<code>wilted-player-play-pause</code>, <code>wilted-player-forward</code>, "
            "<code>wilted-player-next</code>, <code>wilted-player-restart</code>, "
            "<code>wilted-player-mark-completed</code>, and <code>wilted-player-scrubber</code>. Restart and "
            "Mark completed sit together because they are the same kind of decision about the whole episode "
            "rather than about the playhead: start it over, or close it out. Marking writes the same finished "
            "record that reaching the end writes and retires the episode from the Menu, without advancing to "
            "the next one. An article settles on the record alone, having no Menu retirement of its own. The "
            "speed control opens at the last chosen rate and keeps whatever is chosen across relaunch. Where "
            "the item has no artwork the rail shows the produce tile its row does.",
            captures),
        "playback-transcript": figure(
            "fig-playback-transcript", "6.2-playback-fullwindow-transcript",
            "The full-window player showing the transcript while preserving the transport row",
            "<strong>6.2 Transcript, full-window player.</strong> Off Menu, activating "
            "<code>wilted-player-transcript</code> opens <code>wilted-player-full-window</code> with "
            "<code>wilted-player-transcript-expanded</code> and the same transport state as the rail. Collapse "
            "or Escape returns focus to the Transcript toggle; choosing a sidebar destination dismisses the "
            "player without stopping playback. What the panel shows depends on the item: an episode whose feed "
            "publishes a timed transcript reads &ldquo;synced from the feed&rdquo; and follows the audio, and "
            "the fixture article here carries no transcript at all. A prepared episode also shows what "
            "preparation cut: each removed span appears in place at the seam, reading &ldquo;Ad removed "
            "&middot; 1:00 &middot; original 34:12&ndash;35:12&rdquo;, stamped on the prepared clock the "
            "surrounding lines use and naming the original span. It is not selectable, because the audio it "
            "describes is not in the file. Untimed prose has nowhere to put a marker in place, so the same cuts "
            "are listed under the text instead.",
            captures),
        "playback-menu-from-player": figure(
            "fig-playback-menu-from-player", "6.3-playback-menu-from-player",
            "The Menu destination reached by pressing the full-window player's own Menu shortcut",
            "<strong>6.3 The full-window player's Menu shortcut.</strong> "
            "<code>wilted-player-menu</code> is drawn only while a destination other than Menu is selected, "
            "labelled with the Menu's own waiting count. Pressing it both dismisses the overlay and switches "
            "the selected destination to Menu in one action, landing on the same route 5.1 shows &mdash; the "
            "one control on this player that changes navigation rather than just the player's own state.",
            captures),
        "playback-notes": figure(
            "fig-playback-notes", "6.4-playback-fullwindow-notes",
            "The full-window player showing episode notes while preserving playback",
            "<strong>6.4 Notes, full-window player.</strong> With the fixture episode playing, "
            "<code>wilted-player-notes</code> appears beside Transcript (it is absent for an article, which has "
            "its own text) and opens <code>wilted-player-notes-expanded</code>: the feed's show notes as plain "
            "text at <code>wilted-player-notes-text</code>, every address a link, or "
            "<code>wilted-player-notes-unavailable</code> where the feed published none.",
            captures),
        "playback-speakers": figure(
            "fig-playback-speakers", "6.5-playback-transcript-speakers",
            "The synchronised transcript labelling each speaker where the voice changes",
            "<strong>6.5 Transcript, who is speaking.</strong> The episode's transcript is the publisher's own "
            "WebVTT, so it carries voice spans naming who is talking. The name is drawn where the voice changes, "
            "not on every line: an interview alternating two people would otherwise repeat both names down the "
            "whole transcript. A line the publisher credited to nobody carries no name and does not end the "
            "previous speaker&rsquo;s run. The heading is hidden from VoiceOver and the name is folded into the "
            "cue&rsquo;s own spoken label instead, so it is announced once rather than twice. Text-to-speech "
            "names nobody, so an article&rsquo;s transcript shows none of this.",
            captures),
        "settings": figure(
            "fig-settings-frame", "7.1-settings-with-playback",
            "The Settings destination with the bottom rail still carrying its playing state",
            "<strong>7.1 Settings, with playback retained.</strong> As on Feeds and Menu, the rail survives the "
            "route change with its current-item state intact. Appearance "
            "(<code>wilted-appearance-controls</code>) comes first: Text and icon size "
            "(<code>wilted-text-scale</code>) offers System, Large, Larger, and Largest, applies to every screen "
            "including the sidebar, the controls, and the search field, and survives relaunch. Podcast "
            "automation (<code>wilted-automation-controls</code>) separately configures refresh timing "
            "(<code>wilted-automation-refresh-policy</code>), bounded automatic downloads "
            "(<code>wilted-automation-download-policy</code>), immediate/manual/off-peak processing "
            "(<code>wilted-automation-processing-policy</code>), transcript preference "
            "(<code>wilted-automation-transcript-policy</code>), and ad removal "
            "(<code>wilted-automation-remove-ads</code>). Chime where an ad was removed "
            "(<code>wilted-automation-ad-marker</code>) is on by default and takes effect without "
            "re-preparation; the off-peak window "
            "(<code>wilted-automation-off-peak-start</code>, <code>wilted-automation-off-peak-end</code>) "
            "appears only for that processing choice. Sync (<code>wilted-sync-controls</code>) reads Disabled "
            "with the detail &ldquo;Sync is not configured.&rdquo; at <code>wilted-sync-detail</code>, producer "
            "identity Unavailable (<code>wilted-sync-producer-identity</code>), and last fetch and last send Not "
            "yet. Refresh (<code>wilted-sync-refresh</code>) and Upload (<code>wilted-sync-upload</code>) are "
            "rendered disabled in this state.",
            captures),
        "settings-conflict": figure(
            "fig-settings-transcript-conflict", "7.2-settings-transcript-conflict",
            "Podcast automation showing the transcript source set to No local speech-to-text with Remove ads on, "
            "and the notice that explains why nothing will prepare",
            "<strong>7.2 Settings, the one automation pair that refuses work.</strong> Ad removal is timed from a "
            "local pass aligned to this audio and never from a publisher's cues, so choosing "
            "<em>No local speech-to-text</em> while <em>Remove ads</em> is on makes the worker refuse every "
            "preparation before it spends any model time. Neither control is disabled and neither is silently "
            "rewritten: a configuration saved before removal required the aligned pass is a legitimate file, and "
            "turning removal off on the owner's behalf would quietly stop cutting advertisements. "
            "<code>wilted-automation-transcript-conflict</code> appears under the toggle for that pair only, "
            "naming the effect first and then both ways out.",
            captures),
        "recovery-download": figure(
            "fig-recovery-download", "8.1-recovery-download-retry",
            "A Menu row in the Available group reporting a failed download and offering retry",
            "<strong>8.1 Download failure and retry.</strong> The download-failure fixture drives a row in the "
            "Menu's Available group to fail its download at <code>wilted-menu-download-&lt;id&gt;</code>. The "
            "Download control is the <code>arrow.down.circle</code> icon, with Download kept as its tooltip "
            "and accessibility label. The row's next-step control becomes the <code>arrow.clockwise</code> "
            "Retry icon at <code>wilted-menu-retry-&lt;id&gt;</code>, the same control an interrupted or cancelled "
            "download shows; a download still in flight shows the <code>xmark.circle</code> Cancel download "
            "icon at <code>wilted-menu-cancel-&lt;id&gt;</code> instead. Each word remains its tooltip and "
            "accessibility label. Neither the row nor any other control is disabled by the failure &mdash; the "
            "rest of the Menu keeps working while this one row waits to be retried.",
            captures),
        "recovery-quarantine": figure(
            "fig-recovery-quarantine", "8.2-recovery-sync-quarantine",
            "Settings showing sync quarantined with an account-review recovery control",
            "<strong>8.2 Sync quarantine and account recovery.</strong> The quarantined fixture puts sync into "
            "its blocked state: status (<code>wilted-sync-status</code>) reads Quarantined in amber and the "
            "detail (<code>wilted-sync-detail</code>) explains that sync is held until the current iCloud "
            "account is reviewed. <code>wilted-sync-use-current-account</code> is the recovery control, and "
            "Refresh and Upload are disabled alongside it &mdash; it is the only enabled action in that state.",
            captures),
    }

    return f"""<!doctype html>
<html lang="en" data-candidate-commit="{commit}" data-gate-receipt="current-native-ui-receipt" data-capture-status="verified-content-viewport">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wilted Mac daily-driver walkthrough &mdash; {date_human}</title>
<style>
{STYLE}
</style>
</head>
<body><main>
<header id="setup">
<p class="eyebrow">Wilted &middot; Mac daily-driver walkthrough &middot; {date_human} &middot; candidate evidence</p>
<h1>Mac daily-driver review.<br><em>Signed content-viewport evidence.</em></h1>
<p>This report is a screen-by-screen review of the Wilted Mac app as built from the candidate commit below. Every image is an app-owned, window-scoped capture of the Wilted process itself, taken during a signed local XCUITest session. It is candidate evidence for owner review. It is not owner acceptance, not a release record, and not evidence of any production, device, or store state.</p>
<p>It supersedes the {previous} report. The app still has three destinations &mdash; Larder, Feeds, Settings &mdash; and every frame here was retaken against the current routes; none is carried over.</p>
<nav class="toc" aria-label="Contents"><a href="#current">Current state</a><a href="#method">Method</a><a href="#onboarding">Onboarding</a><a href="#feeds">Feeds</a><a href="#menu">Menu</a><a href="#playback">Playback</a><a href="#settings">Settings</a><a href="#recovery">Recovery</a><a href="#roles">Roles</a><a href="#system-boundaries">System boundaries</a><a href="#limits">Coverage limits</a><a href="#non-claims">Non-claims</a><a href="#owner-checklist">Owner checklist</a></nav>
</header>

<section id="current"><h2>1. Current state</h2>
<p class="meta">Candidate commit: <code>{commit}</code> &middot; gate receipt: <code>current-native-ui-receipt</code> &middot; capture status: <code>verified-content-viewport</code> &middot; {frame_count} content-viewport PNGs embedded</p>
<table><thead><tr><th>Property</th><th>Observed value</th></tr></thead><tbody>
<tr><td>Bundle identifier</td><td><code>com.zerodelta.wilted.mac</code></td></tr>
<tr><td>Signature</td><td><code>CODE_SIGN_IDENTITY=Apple Development</code>, <code>DEVELOPMENT_TEAM=4CJ49V6QHW</code>; the gate verifies the runner with <code>codesign --verify --deep --strict</code> and refuses quarantine or FinderInfo metadata on either bundle</td></tr>
<tr><td>Captured processes</td><td>Nine launches across five capture scenarios &mdash; Menu launches three times, Playback twice, and Recovery twice, once for the download failure and once for the quarantine notice. Each frame is scoped to its own launch's window, or, for the three popover frames, to the popover that launch opened.</td></tr>
<tr><td>Window geometry</td><td>{geometry_line}</td></tr>
<tr><td>Reproducing this report</td><td><code>scripts/record-walkthrough-frames.sh</code> writes the frames and a geometry sidecar beside each one, by setting <code>WILTED_WALKTHROUGH_CAPTURE=1</code> inside the generated scheme's TestAction and running <code>-only-testing:WiltedMacUITests/WiltedMacWalkthroughCapture</code>; <code>scripts/build-mac-walkthrough.py</code> assembles this document from that directory</td></tr>
</tbody></table>
<div class="warning"><strong>What changed since the {previous} report.</strong> Larder now separates presentation from listening order: Group by offers Feed, Date, and Status, while Sort by retains Custom order, Newest, Oldest, Length, Show, and Title. Release dates are numeric, for example 9/22/2026 in US English. Feeds now opens show notes in a popover. Download all new and Prepare all now show bulk progress while rows run. Settings adds the Chime where an ad was removed setting. Larder rows state their status once and use icons with tooltips. Play Now inserts the selected episode immediately before the current episode so the interrupted episode remains next. Now Playing names the next episode as soon as Mark completed starts it. Every frame was retaken at this commit.</div>
</section>

<section id="method"><h2>2. Method and evidence labels</h2>
<p>Pixels come from <code>XCUIElement.screenshot()</code> scoped to the Wilted app's own window. Nothing in this session captured the screen, the desktop, or another application's window. XCTest's automatic whole-screen recording is disabled at the project level &mdash; the generated scheme carries <code>systemAttachmentLifetime = "keepNever"</code>, so no full-screen recording was written to disk.</p>
<table><thead><tr><th>Evidence type</th><th>Required proof</th><th>Limit</th></tr></thead><tbody>
<tr><td>Exact process</td><td>Fresh signed app bundle built and signed by the same gate that runs the suite, launched per scenario.</td><td>Does not establish release status.</td></tr>
<tr><td>Accessibility tree</td><td>macOS Accessibility hierarchy queried live during the session by stable identifier, including route and control identifiers.</td><td>Interaction inventory, not pixels.</td></tr>
<tr><td>Content viewport</td><td><code>XCUIElement.screenshot()</code> on the app's own window element &mdash; the geometry scope an AppKit reader would call <code>NSApp.mainWindow.contentView</code> &mdash; paired with a sidecar recording the window frame, the captured pixel size, the embedded pixel size, and the inset actually applied. Captured pixels equal the window frame, which is what makes a window-scoped screenshot a content viewport screenshot.</td><td>The sidecar is written by the test process from the window element's frame, not from inside the app. It proves the capture covered the whole window; it does not independently attest the app's own view bounds.</td></tr>
<tr><td>Source inventory</td><td>Shipping-view controls and system handoff descriptions.</td><td>Not runtime or visual evidence.</td></tr>
</tbody></table>
<h3>Resolution and crop</h3>
<p>Every embedded PNG is {embedded_text} because a uniform 8pt inset per edge is removed from the capture: the window's rounded corners are partly transparent, and an uncropped frame can contain readable fragments of whatever sits behind it. {scale_text}</p>
</section>

<section id="onboarding"><h2>3. Onboarding and first run</h2>
<p>Wilted has no account creation, sign-in, or welcome sequence. First run opens directly on Menu with an empty queue and the Add article button reachable from it; the app is usable without configuring anything. Sync is opt-in and lives in Settings; it is not part of first run and does not gate any Menu function.</p>
<p>Subscribing to a podcast is likewise not an onboarding step, and it is not a separate skill to learn: the same box that saves an article, now on Menu, takes a feed address, and Feeds carries a composer of its own for the same purpose. The Feeds destination is empty until the listener adds a subscription, and it says so in place rather than hiding.</p>
<p class="muted">No separate onboarding screen exists in this build, so none is captured. If one is added, this report must be refreshed.</p>
</section>

<section id="feeds"><h2>4. Feeds</h2>
<p>Feeds answers one question, once, per new episode: keep it or skip it. Downloading, preparing, and playing all happen in the Menu. Feed upkeep &mdash; subscribing, refreshing, hiding, unsubscribing &mdash; and the restorable list for anything taken off the Menu share the same destination, reached by <code>wilted-navigation-feeds</code> with detail pane <code>wilted-mac-feeds-detail</code>.</p>
{figures["feeds-inbox"]}
{figures["feeds-show-notes"]}
{figures["feeds-add"]}
{figures["feeds-off-the-list"]}
{figures["feeds-management"]}
{figures["feeds-feed-hidden"]}
<p>Nothing on this page runs on a schedule, and the card says so rather than letting an absent schedule read as a hidden one: feeds refresh when Refresh is chosen, and no feed downloads audio on its own. Download on an individual episode is what keeps it offline. When a refresh keeps fewer episodes than the feed published &mdash; because the feed exceeds the client's episode ceiling, or because they predate the subscription &mdash; the withheld count is stated in <code>wilted-podcast-feeds-withheld</code>, so a truncated back catalogue is never presented as the whole feed. Unsubscribing is the destructive action on this page and is driven, not merely rendered, by the shipping UI suite.</p>
</section>

<section id="menu"><h2>5. Menu</h2>
<p>Menu is the primary destination and the default route at launch. <code>WiltedMacNavigation.restored(from:)</code> resolves an unreadable, absent, or retired stored selection to Menu. The sidebar (<code>wilted-mac-sidebar</code>) holds the wordmark and the three destinations &mdash; <code>wilted-navigation-menu</code>, <code>wilted-navigation-feeds</code>, <code>wilted-navigation-settings</code> &mdash; pinned above the standing sidebar totals (<code>wilted-sidebar-ready-total</code>, <code>wilted-sidebar-downloaded-total</code>, <code>wilted-sidebar-menu-total</code>).</p>
{figures["menu-idle"]}
{figures["menu-add"]}
{figures["menu-prepared"]}
{figures["menu-transcript-inline"]}
{figures["menu-deferred"]}
<p>Per-episode controls carry the episode's own id rather than a content hash: <code>wilted-menu-row-&lt;id&gt;</code> for the row, with the next-step control, Skip, and Remove each keyed the same way. These identifiers are present in the Accessibility tree for every captured Menu frame.</p>
</section>

<section id="playback"><h2>6. Bottom rail and full-window player</h2>
<p>Now Playing is not a destination of its own. Off Menu, its always-visible bottom rail keeps playback state within a glance; Transcript and Notes expand into a full-window player that retains the same transport state, and a Menu shortcut on that player switches destinations without losing playback. On Menu itself the same compact player is embedded inline and the same two toggles expand in place (5.4) instead.</p>
{figures["playback-rail"]}
{figures["playback-transcript"]}
{figures["playback-menu-from-player"]}
{figures["playback-notes"]}
{figures["playback-speakers"]}
<p>Keyboard handling: the transport row is reachable by Tab, Collapse and Escape return focus to the originating toggle, and the underlying destination is disabled and hidden from accessibility while the full-window player is open.</p>
<p>The same transport is reachable without the app in front of you. What is playing is published to the system, so the episode appears in the menu bar's Now Playing widget and on the lock screen, with its show, artwork, elapsed time, and speed. The keyboard's media keys and the widget's own buttons drive the identical model the on-screen rail drives: play and pause, next and previous episode, a 15-second step back and a 30-second step forward, scrubbing, and the six speeds the rate control offers.</p>
</section>

<section id="settings"><h2>7. Settings</h2>
<p>Settings holds appearance, podcast automation policy, opt-in sync, and the account-review recovery path. Preparation reporting that used to have its own Prep destination is gone as a route; a run's outcome now shows directly on its Menu row (5.3), and this section covers what remains a destination of its own.</p>
{figures["settings"]}
{figures["settings-conflict"]}
</section>

<section id="recovery"><h2>8. Download and recovery states</h2>
<p>Two states are captured here rather than described: a failed download that offers retry from the Menu's Available group, and sync held in quarantine with the recovery control that releases it.</p>
{figures["recovery-download"]}
{figures["recovery-quarantine"]}
</section>

<section id="roles"><h2>9. Roles and permission differences</h2>
<p>Wilted has one local role on the Mac: the producer. There is no second account type, no administrator mode, and no per-user permission surface, so no role-dependent route or control differs between users of the same machine. The one role-shaped distinction in the product is between the Mac producer and the iPhone listener, and it is a device distinction rather than a permission one: the Mac prepares audio and owns the library, and the listener reads it. That boundary is not exercised in this report.</p>
<p>The permissions that do vary are system-granted, not app-granted: iCloud account availability decides whether sync is offered or quarantined, and the file-access consent the system grants the app decides whether a chosen folder can be read. Both are captured as states, in sections 7 and 8, rather than as roles.</p>
</section>

<section id="system-boundaries"><h2>10. System-owned boundaries</h2>
<p>Four system-owned surfaces can appear over or outside the app, none of which Wilted draws or controls: the open panel used when choosing a file, the Finder reveal that a retained-artifact action performs, the system share and permission prompts, and the menu bar's Now Playing widget. Each is an OS surface; the app's own state at the moment of handoff is what this report can evidence, and it does not capture the system sheets themselves.</p>
<p>The Now Playing widget differs from the other three in that Wilted feeds it rather than merely hands off to it. The app publishes the current episode to the system and installs handlers for the media keys, and the system decides how to draw that and when to deliver a key press. Because it is process-global, a fixture run is given neither: a capture session would otherwise leave its fixture episode sitting in the menu bar after the run, pointing the machine's media keys at a process that has exited.</p>
</section>

<section id="limits"><h2>11. Coverage limits</h2>
<p>What this report does not cover, stated rather than implied:</p>
<ul>
<li>No frame shows a real feed. Every capture runs against a UI fixture, so titles, counts, and durations are fixture values.</li>
<li>The address boxes are captured open and idle (4.2, 5.2). Their outcomes &mdash; feed, article, and article-advertising-a-feed &mdash; are covered by automated tests rather than by pixels here, because each needs a live fetch the capture session does not perform.</li>
<li>Preparation is captured in its recorded, terminal state (5.3) and in the deferred off-peak state that offers Prepare now (5.5). No frame shows advertisement removal running, and no frame shows an in-progress preparation's row beyond the static progress control 5.3 describes. Placement is covered by tests; that it reads correctly beside real speech is an owner observation, listed in section 13.</li>
<li>Transcript synchronisation against real audio is not captured. The panel is shown expanded; a timed transcript following the playback clock is covered by tests, not by a frame.</li>
<li>The sidebar in these frames is the real one, but pixel snapshot baselines cannot see it: a <code>NavigationSplitView</code> navigation column is hosted in a separate AppKit hierarchy that offscreen rendering does not draw. Sidebar behaviour is owned by the XCUITest suite instead.</li>
<li>Off the list's Removed kind is not captured (4.3). Task 4.5 folded Skipped (retired) and Removed (dismissed) episodes onto one <code>removalKind</code> column with the same Restore control, but the only UI control this report can drive that touches removal, the Menu's Remove button, calls <code>model.removeEpisodeFromUpNext</code>, which unqueues the episode back to the Feeds inbox rather than dismissing it. The operation that actually sets <code>removalKind == .dismissed</code>, <code>model.removeEpisode(_:)</code>, has no call site in <code>WiltedMacRootView.swift</code> at all &mdash; it is exercised only by <code>WiltedMacModelTests</code> and <code>WiltedVisualSystemTests</code>. So 4.3 shows the Skipped kind only; the Removed kind's restore is evidenced by those model tests, not by a pixel here.</li>
<li>No system-owned sheet is captured, as section 10 states.</li>
<li>The menu bar's Now Playing widget and the media keys are not captured and cannot be. They are outside the content viewport this report photographs, and the capture session deliberately does not own them. That the app publishes the right thing and that each remote command reaches the model are covered by tests; that the widget draws and the keys arrive is an owner observation, listed in section 13.</li>
</ul>
</section>

<section id="non-claims"><h2>12. Non-claims</h2><div class="card">Production CloudKit is not claimed. physical-device is not claimed. App Store Connect is not claimed. TestFlight is not claimed. deployment is not claimed. publication is not claimed. owner acceptance remains pending. This report is candidate evidence produced from a local signed build; it establishes what the app rendered on this machine at this commit and nothing beyond that.</div></section>

<section id="owner-checklist"><h2>13. Owner acceptance checklist</h2><ol>
<li>Paste an article address into the Menu's Add article box and confirm it is saved as an article.</li>
<li>Paste a podcast address into the same box, or into Feeds' Add feed box, and confirm it subscribes, and that the feed appears on Feeds.</li>
<li>Keep an episode from the Feeds inbox and confirm it appears on the Menu; skip another and confirm it leaves the inbox for Off the list.</li>
<li>In Larder, group the same queue by Feed, Date, and Status; confirm each row keeps its release date and that changing Sort by changes order independently.</li>
<li>While a far-down episode is playing, choose Play Now on another episode and confirm the selected episode starts while the interrupted episode becomes next.</li>
<li>Download an episode, prepare it, and confirm the prepared audio plays from the position you were at.</li>
<li>Expand Transcript on a prepared episode and confirm the text follows the audio.</li>
<li>On that same episode, confirm each removed advertisement is marked in the transcript where the audio jumps, and that the original times it names match what Prep reported before it was retired (Menu's row does not yet carry that summary; see 5.3).</li>
<li>Hide a feed on Feeds, confirm its episodes leave the Menu, and switch it back on.</li>
<li>Unsubscribe from a feed and confirm the row goes.</li>
<li>Switch destinations while playing and confirm the rail keeps its state.</li>
<li>Quit and relaunch mid-episode and confirm playback resumes where it stopped.</li>
<li>Start an episode, switch to another app, and confirm Wilted appears in the menu bar's Now Playing widget with the right show and artwork, and that the elapsed time advances.</li>
<li>Press the keyboard's play/pause key with Wilted in the background and confirm the audio stops and starts, and that the widget agrees.</li>
<li>Use the widget's skip controls and confirm they move by the same 15 and 30 seconds the on-screen rail does.</li>
<li>Let an episode reach its end with the window closed and confirm the widget stops claiming to be playing.</li>
<li>Press Mark completed part way through an episode and confirm the audio stops, the button reads Completed, the queue stays on the same episode, and the Menu row changes to &ldquo;Played&rdquo;.</li>
<li>Skip an episode from its Feeds inbox or Menu row in one press, confirm it appears on Feeds' Off the list as Skipped, and confirm Restore brings it back with no network call. Separately, confirm the Menu's Remove button only unqueues the episode back to the Feeds inbox rather than dismissing it &mdash; it is not the same act as Skip.</li>
<li>Change Text and icon size in Settings and confirm the sidebar, the rows, the search field, and the rail all follow, and that the choice survives relaunch.</li>
<li>Choose each podcast processing policy in Settings, confirm the off-peak window appears only for Off-peak, and confirm the choice survives relaunch.</li>
<li>Open Transcript and Notes off Menu, confirm each uses the full-window player without losing transport state, and confirm Collapse, Escape, and sidebar navigation dismiss it correctly; open the same toggles on Menu and confirm they expand inline instead.</li>
<li>Quit Wilted while an episode is preparing, relaunch, and confirm its Menu row shows the run as failed with the reason and a Retry, and that Retry prepares it.</li>
</ol></section>

</main></body></html>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--captures", required=True, type=pathlib.Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--date", required=True, help="ISO date, e.g. 2026-09-01")
    parser.add_argument("--date-human", required=True, help="e.g. 1 September 2026")
    parser.add_argument("--previous", required=True, help="e.g. 31 August")
    parser.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args()

    if len(args.commit) != 40 or any(c not in "0123456789abcdef" for c in args.commit):
        raise SystemExit(f"candidate commit must be a full 40-character sha: {args.commit}")
    html = build(args.captures, args.commit, args.date, args.date_human, args.previous)
    # Internal `menu` and `available` identifiers remain stable; rendered copy
    # follows the current Larder vocabulary without recapturing screenshots.
    html = html.replace("Menu", "Larder").replace("Podcast feeds", "Feeds")
    html = html.replace("Available", "Not downloaded")
    html = html.replace("Prepare all downloaded", "Prepare all now")
    args.out.write_text(html)
    print(f"walkthrough.written path={args.out} bytes={len(html)}", file=sys.stderr)


if __name__ == "__main__":
    main()
