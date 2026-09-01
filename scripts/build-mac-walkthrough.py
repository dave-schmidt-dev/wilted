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
    for sidecar in sidecars:
        data = json.loads(sidecar.read_text())
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
    line = (f"<code>window={w:g}x{h:g}</code>, <code>captured-pixels={cw}x{ch}</code>, "
            f"<code>embedded-pixels={ew}x{eh}</code>, <code>inset={inset}px per edge</code> "
            f"&mdash; identical across all {len(sidecars)} frames")
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
        "larder": figure(
            "fig-larder-idle", "4.1-larder-idle",
            "Wilted Larder in its idle state showing the single add box, the saved-item list, and the bottom rail",
            "<strong>4.1 Larder, idle.</strong> The always-visible bottom rail is present with nothing playing. "
            "One box takes both kinds of address: <code>wilted-mac-composer</code> holds "
            "<code>wilted-link-url</code> and <code>wilted-add-link</code>, and the card states that Wilted works "
            "out for itself whether the address is an article or a podcast feed. Below it the saved list carries "
            "its own ordering control, <code>wilted-library-order</code>. There is no feed field and no feed card "
            "on this route; both moved to Podcast feeds. The idle rail (<code>wilted-player-idle</code>) reads "
            "&ldquo;Nothing is playing&rdquo;.",
            captures),
        "feeds": figure(
            "fig-feeds-page", "5.1-feeds-page",
            "The Podcast feeds destination listing subscribed feeds with per-feed controls",
            "<strong>5.1 Podcast feeds.</strong> The destination reached by <code>wilted-navigation-feeds</code>; "
            "its detail pane is <code>wilted-mac-feeds-detail</code>. Refresh "
            "(<code>wilted-podcast-refresh</code>) sits in the Subscriptions header, on the list it "
            "refreshes, and becomes <code>wilted-podcast-refresh-cancel</code> beside a progress "
            "indicator while a refresh is running. "
            "<code>wilted-podcast-feeds</code> states the refresh and download policy in "
            "<code>wilted-podcast-feeds-policy</code> and lists one "
            "<code>wilted-podcast-feed-row-&lt;id&gt;</code> per subscription, each with a count line, a "
            "show-in-Larder switch, and an unsubscribe control.",
            captures),
        "feed-hidden": figure(
            "fig-feeds-feed-hidden", "5.2-feeds-feed-hidden",
            "The Podcast feeds destination after one show was hidden from Larder",
            "<strong>5.2 Podcast feeds, one show hidden.</strong> The switch on the first row was activated "
            "during the capture. The row's count line changes from &ldquo;1 episode in Larder&rdquo; to "
            "&ldquo;1 episode kept, hidden from Larder&rdquo; and the switch reads off. Hiding a feed does not "
            "delete anything: the episodes stay in the library and return when the switch goes back on.",
            captures),
        "rail": figure(
            "fig-playback-rail", "6.1-playback-rail",
            "The bottom rail in its playing state with the full transport row",
            "<strong>6.1 Playback, bottom rail.</strong> The rail has switched from idle to the transport row. "
            "Controls present: <code>wilted-player-status</code>, <code>wilted-player-speed</code>, "
            "<code>wilted-player-previous</code>, <code>wilted-player-rewind</code>, "
            "<code>wilted-player-play-pause</code>, <code>wilted-player-forward</code>, "
            "<code>wilted-player-next</code>, and <code>wilted-player-scrubber</code>.",
            captures),
        "transcript": figure(
            "fig-playback-transcript", "6.2-transcript-expanded",
            "The transcript panel expanded inline above the bottom rail",
            "<strong>6.2 Transcript, expanded inline.</strong> Activating <code>wilted-player-transcript</code> "
            "expands <code>wilted-player-transcript-expanded</code> in place above the rail rather than opening "
            "a sheet or a new route; the toggle renders selected while expanded. What the panel shows depends on "
            "the item: an episode whose feed publishes a timed transcript reads &ldquo;synced from the feed&rdquo; "
            "and follows the audio, and the fixture article here carries no transcript at all.",
            captures),
        "upnext": figure(
            "fig-playback-upnext", "6.3-up-next-expanded",
            "The Up Next panel expanded inline above the bottom rail",
            "<strong>6.3 Up Next, expanded inline.</strong> Activating <code>wilted-player-up-next</code> expands "
            "<code>wilted-player-up-next-expanded</code> in the same inline position, with the rail's transport "
            "row still reachable. The queue reads &ldquo;Nothing queued&rdquo; because the fixture queues nothing.",
            captures),
        "notes": figure(
            "fig-playback-notes", "6.4-notes-expanded",
            "The show notes panel expanded inline above the bottom rail while a fixture episode plays",
            "<strong>6.4 Notes, expanded inline.</strong> With the fixture episode playing, "
            "<code>wilted-player-notes</code> appears between Transcript and Up Next (it is absent for an "
            "article, which has its own text) and expands <code>wilted-player-notes-expanded</code>: the feed's "
            "show notes as plain text at <code>wilted-player-notes-text</code>, every address a link. The Larder "
            "row for the same episode leads with these notes' opening sentence instead of the author.",
            captures),
        "prep": figure(
            "fig-prep-frame", "7.1-prep-with-playback",
            "The Prep destination with the bottom rail still carrying its playing state",
            "<strong>7.1 Prep, with playback retained.</strong> Switching destination did not remove the rail or "
            "its current-item state, which is the behaviour the always-visible bottom rail is meant to produce. "
            "Prep reports &ldquo;Nothing is preparing&rdquo; and &ldquo;0 recorded&rdquo;: no fixture starts a "
            "run, so this is the empty Prep route, not an idle one.",
            captures),
        "settings": figure(
            "fig-settings-frame", "8.1-settings-with-playback",
            "The Settings destination with the bottom rail still carrying its playing state",
            "<strong>8.1 Settings, with playback retained.</strong> As on Prep, the rail survives the route "
            "change with its current-item state intact. Sync reads Disabled with the detail &ldquo;Sync is not "
            "configured.&rdquo;, producer identity Unavailable, and last fetch and last send Not yet. Refresh and "
            "Upload are rendered disabled in this state.",
            captures),
        "download": figure(
            "fig-download-recovery", "9.1-download-failure-retry",
            "An episode row reporting a failed download and offering retry",
            "<strong>9.1 Download failure and retry.</strong> The download-failure fixture drives "
            "<code>wilted-episode-download-item-&lt;hash&gt;</code> to fail. The status line reads "
            "&ldquo;Download failed. Retry when you are online.&rdquo; and the episode row offers "
            "<code>wilted-episode-retry-item-&lt;hash&gt;</code>.",
            captures),
        "quarantine": figure(
            "fig-settings-recovery", "9.2-sync-quarantine",
            "Settings showing sync quarantined with an account-review recovery control",
            "<strong>9.2 Sync quarantine and account recovery.</strong> The quarantined fixture puts sync into "
            "its blocked state: status reads Quarantined in amber and the detail explains that sync is held "
            "until the current iCloud account is reviewed. "
            "<code>wilted-use-current-account</code> is the recovery control, and it is the only enabled action "
            "in that state.",
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
<p>It supersedes the {previous} report, which predates the single address box in Larder and the Podcast feeds destination. Every frame here was retaken; none is carried over.</p>
<nav class="toc" aria-label="Contents"><a href="#current">Current state</a><a href="#method">Method</a><a href="#onboarding">Onboarding</a><a href="#library">Larder</a><a href="#feeds">Podcast feeds</a><a href="#playback">Playback</a><a href="#prep">Prep</a><a href="#settings">Settings</a><a href="#recovery">Recovery</a><a href="#roles">Roles</a><a href="#system-boundaries">System boundaries</a><a href="#limits">Coverage limits</a><a href="#non-claims">Non-claims</a><a href="#owner-checklist">Owner checklist</a></nav>
</header>

<section id="current"><h2>1. Current state</h2>
<p class="meta">Candidate commit: <code>{commit}</code> &middot; gate receipt: <code>current-native-ui-receipt</code> &middot; capture status: <code>verified-content-viewport</code> &middot; {frame_count} content-viewport PNGs embedded</p>
<table><thead><tr><th>Property</th><th>Observed value</th></tr></thead><tbody>
<tr><td>Bundle identifier</td><td><code>com.zerodelta.wilted.mac</code></td></tr>
<tr><td>Signature</td><td><code>CODE_SIGN_IDENTITY=Apple Development</code>, <code>DEVELOPMENT_TEAM=4CJ49V6QHW</code>; the gate verifies the runner with <code>codesign --verify --deep --strict</code> and refuses quarantine or FinderInfo metadata on either bundle</td></tr>
<tr><td>Captured processes</td><td>Six launches across five capture scenarios &mdash; the recovery scenario launches twice, once for the download failure and once for the quarantine notice. Each frame is scoped to its own launch's window.</td></tr>
<tr><td>Window geometry</td><td>{geometry_line}</td></tr>
<tr><td>Reproducing this report</td><td><code>scripts/record-walkthrough-frames.sh</code> writes the frames and a geometry sidecar beside each one, by setting <code>WILTED_WALKTHROUGH_CAPTURE=1</code> inside the generated scheme's TestAction and running <code>-only-testing:WiltedMacUITests/WiltedMacWalkthroughCapture</code>; <code>scripts/build-mac-walkthrough.py</code> assembles this document from that directory</td></tr>
</tbody></table>
<div class="warning"><strong>What changed since the {previous} report.</strong> Larder had two address boxes, one for articles and one for feeds, and carried the whole Podcast feeds card besides. It now has one box that reads the pasted document and decides for itself which kind it is, and feed upkeep has moved to its own destination. Frames 4.1, 5.1, and 5.2 are the evidence for both changes. The remaining frames were retaken at this commit rather than reused, because the sidebar gained a fourth destination and appears in all of them.</div>
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
<p>Wilted has no account creation, sign-in, or welcome sequence. First run opens directly on Larder with the add box and an empty saved list; the app is usable without configuring anything. Sync is opt-in and lives in Settings; it is not part of first run and does not gate any Larder function.</p>
<p>Subscribing to a podcast is likewise not an onboarding step, and it is not a separate skill to learn: the same box that saves an article takes a feed address. The Podcast feeds destination is empty until the listener adds one, and it says so in place rather than hiding.</p>
<p class="muted">No separate onboarding screen exists in this build, so none is captured. If one is added, this report must be refreshed.</p>
</section>

<section id="library"><h2>4. Larder</h2>
<p>Larder is the primary library destination and the default route at launch. The sidebar (<code>wilted-mac-sidebar</code>) holds the wordmark and four destinations: <code>wilted-navigation-library</code>, <code>wilted-navigation-feeds</code>, <code>wilted-navigation-processor</code>, and <code>wilted-navigation-settings</code>. The detail pane is <code>wilted-mac-library-detail</code>.</p>
<p>Larder is for the things worth reading and listening to. Adding something is one field and one button; there is no second box, and nothing asks the reader to say in advance whether an address is an article or a podcast. An address ending <code>.xml</code>, <code>.rss</code>, or <code>.atom</code> is taken as a feed without a fetch. Anything else is fetched once, bounded, and read: a document whose root element is <code>&lt;rss&gt;</code>, <code>&lt;feed&gt;</code>, or <code>&lt;rdf:RDF&gt;</code> is a feed, and a page is an article. A page that publishes a feed of its own is still saved as the article that was pasted, with the feed offered as an explicit Subscribe action rather than followed silently. While the fetch is in flight the box says so in <code>wilted-link-status</code>, and an address that cannot be reached is reported there rather than guessed at.</p>
{figures["larder"]}
<p>Per-item controls carry a stable content hash in their identifier: <code>wilted-article-row-item-&lt;hash&gt;</code> and <code>wilted-episode-row-item-&lt;hash&gt;</code> for the rows, with <code>wilted-article-actions-item-&lt;hash&gt;</code> and <code>wilted-episode-actions-item-&lt;hash&gt;</code> for their action menus. These identifiers are present in the Accessibility tree for every captured route.</p>
</section>

<section id="feeds"><h2>5. Podcast feeds</h2>
<p>Feed upkeep is its own destination. It answers a different question from Larder &mdash; which sources supply the library, rather than what is in it &mdash; and while it sat on top of Larder it pushed the saved items below the fold.</p>
{figures["feeds"]}
<p>Nothing on this page runs on a schedule, and the card says so rather than letting an absent schedule read as a hidden one: feeds refresh when Refresh is chosen, and no feed downloads audio on its own. Download on an individual episode is what keeps it offline. When a refresh keeps fewer episodes than the feed published &mdash; because the feed exceeds the client's episode ceiling, or because they predate the subscription &mdash; the withheld count is stated in <code>wilted-podcast-feeds-withheld</code>, so a truncated back catalogue is never presented as the whole feed.</p>
{figures["feed-hidden"]}
<p>Unsubscribing is the destructive action on this page and is driven, not merely rendered, by the shipping UI suite: <code>testFeedsPageListsPodcastFeedsWithPerFeedControls</code> clicks it and asserts the row count drops.</p>
</section>

<section id="playback"><h2>6. Always-visible bottom rail</h2>
<p>Now Playing is not a destination. It is an always-visible bottom rail below the detail pane, so playback state is never more than a glance away and never costs a route change.</p>
{figures["rail"]}
{figures["transcript"]}
{figures["upnext"]}
{figures["notes"]}
<p>Keyboard handling: the transport row is reachable by Tab, the expanded panels return focus to their toggle on collapse, and Escape collapses an expanded panel rather than leaving it open behind a route change.</p>
</section>

<section id="prep"><h2>7. Prep</h2>
<p>Prep is where preparation runs are reported: what is running now, and what has been recorded. Preparation is the step that removes advertisements from a downloaded episode and produces the audio the player uses.</p>
{figures["prep"]}
</section>

<section id="settings"><h2>8. Settings</h2>
<p>Settings holds sync, which is opt-in, and the account-review recovery path.</p>
{figures["settings"]}
</section>

<section id="recovery"><h2>9. Download and recovery states</h2>
<p>Two states are captured here rather than described: a failed download that offers retry, and sync held in quarantine with the recovery control that releases it.</p>
{figures["download"]}
{figures["quarantine"]}
</section>

<section id="roles"><h2>10. Roles and permission differences</h2>
<p>Wilted has one local role on the Mac: the producer. There is no second account type, no administrator mode, and no per-user permission surface, so no role-dependent route or control differs between users of the same machine. The one role-shaped distinction in the product is between the Mac producer and the iPhone listener, and it is a device distinction rather than a permission one: the Mac prepares audio and owns the library, and the listener reads it. That boundary is not exercised in this report.</p>
<p>The permissions that do vary are system-granted, not app-granted: iCloud account availability decides whether sync is offered or quarantined, and the file-access consent the system grants the app decides whether a chosen folder can be read. Both are captured as states, in sections 8 and 9, rather than as roles.</p>
</section>

<section id="system-boundaries"><h2>11. System-owned boundaries</h2>
<p>Three system-owned surfaces can appear over the app, none of which Wilted draws or controls: the open panel used when choosing a file, the Finder reveal that a retained-artifact action performs, and the system share and permission prompts. Each is an OS surface; the app's own state at the moment of handoff is what this report can evidence, and it does not capture the system sheets themselves.</p>
</section>

<section id="limits"><h2>12. Coverage limits</h2>
<p>What this report does not cover, stated rather than implied:</p>
<ul>
<li>No frame shows a real feed. Every capture runs against a UI fixture, so titles, counts, and durations are fixture values.</li>
<li>The single add box is captured idle. Its three outcomes &mdash; feed, article, and article-advertising-a-feed &mdash; are covered by automated tests rather than by pixels here, because each needs a live fetch the capture session does not perform.</li>
<li>Preparation is captured empty. No frame shows advertisement removal running or a prepared summary.</li>
<li>Transcript synchronisation against real audio is not captured. The panel is shown expanded; a timed transcript following the playback clock is covered by tests, not by a frame.</li>
<li>The sidebar in these frames is the real one, but pixel snapshot baselines cannot see it: a <code>NavigationSplitView</code> navigation column is hosted in a separate AppKit hierarchy that offscreen rendering does not draw. Sidebar behaviour is owned by the XCUITest suite instead.</li>
<li>No system-owned sheet is captured, as section 11 states.</li>
</ul>
</section>

<section id="non-claims"><h2>13. Non-claims</h2><div class="card">Production CloudKit is not claimed. physical-device is not claimed. App Store Connect is not claimed. TestFlight is not claimed. deployment is not claimed. publication is not claimed. owner acceptance remains pending. This report is candidate evidence produced from a local signed build; it establishes what the app rendered on this machine at this commit and nothing beyond that.</div></section>

<section id="owner-checklist"><h2>14. Owner acceptance checklist</h2><ol>
<li>Paste an article address into Larder's one box and confirm it is saved as an article.</li>
<li>Paste a podcast address into the same box and confirm it subscribes, and that the feed appears on Podcast feeds.</li>
<li>Download an episode, prepare it, and confirm the prepared audio plays from the position you were at.</li>
<li>Expand Transcript on a prepared episode and confirm the text follows the audio.</li>
<li>Hide a feed from Larder, confirm its episodes leave the list, and switch it back on.</li>
<li>Unsubscribe from a feed and confirm the row goes.</li>
<li>Switch destinations while playing and confirm the rail keeps its state.</li>
<li>Quit and relaunch mid-episode and confirm playback resumes where it stopped.</li>
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
    args.out.write_text(html)
    print(f"walkthrough.written path={args.out} bytes={len(html)}", file=sys.stderr)


if __name__ == "__main__":
    main()
