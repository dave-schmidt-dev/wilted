# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- Made the phone Larder populate on a real phone: the Mac now publishes an `available` media offer (revision, size, type, duration; no audio uploaded) for every prepared queued episode, and Get audio on the phone triggers the upload that flips it to `ready`. Once every requesting device has cached the audio the offer returns to `available` instead of vanishing, and offers for episodes that leave the Larder are withdrawn. An offer state an older reader does not know decodes as not ready.
- Added a `removeFromLarder` intent: the phone's Larder rows offer Remove from Larder (queue removal only, nothing deleted) instead of Skip, and the Mac applies it through the Larder row's own method with the usual once-only ledger, outcome and expiry.
- Published a compact transcript (timed cues, or plain text when the Mac has no timing, capped at 512 KB with truncation flagged) for a revision when the Mac answers that entry's media request, and withdrew it with the audio; it lives in the media zone as a named asset record, so no library fetch stages it and older readers never see it.
- Added the tracked transcript on the phone: after audio is verified the phone fetches the Mac's transcript for that revision (best effort; a missing or failed fetch never affects the audio) and caches it beside the audio, removed with it including Remove all in Settings, retried once per session when the detail opens. The episode detail and a Transcript sheet in the full player show a follow-along cue list (current cue bold with a leading marker, auto-scroll that pauses while you drag, tap a cue to seek the playing episode) or prose when the transcript has no timing.
- Published the Mac's lifetime statistics to the library as one named record the phone reads without a zone scan; the Mac republishes it on change through the existing publisher debounce.
### Changed

- Rebuilt the iPhone Larder as one list of episodes the Mac has prepared (a ready or available media offer, or audio already on the phone), with sort (custom, newest, oldest, shortest, show, title; remembered), an All / On phone / Available filter, search over title, show and notes, artwork thumbnails, publication dates, and Play that resumes from the Mac's last position. New and Removed sections and the Keep and Restore actions are gone from the phone; Remove from Larder, Mark done and reorder remain.

### Fixed

- Audited Phase 0 and native-gate temporary entries by identity before and after each owned run, so a new leak cannot hide behind shrinking totals.
- Required positive ownership and inactivity before the crash backstop removes stale Wilted scratch, and registered migration validation cleanup before copying.
