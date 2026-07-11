# Spike: pure-ctypes CoreAudio default-output-device listener

**Date:** 2026-07-10
**Machine:** M5 Max MacBook Pro, macOS 26.5.2 (Build 25F84), Xcode 26.6, macOS SDK 26.5
**Question:** Can a pure-ctypes listener on CoreAudio reliably detect a default-output-device
change, so a future version of wilted could actively "follow" a device switch instead of
staying bound to a stale device (the current sounddevice/PortAudio behavior)?

Both a "solid" and a "flaky" outcome were acceptable answers going in. **The result is solid.**

---

## 1. Main vs Master finding

Ran:

```
xcrun --show-sdk-path
# -> /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

Grepped `AudioHardwareBase.h` and `AudioHardware.h` under
`System/Library/Frameworks/CoreAudio.framework/Headers/` in that SDK path.

**Exact grep output** (`kAudioObjectPropertyElementMain` / `kAudioObjectPropertyElementMaster`, both headers):

```
===== AudioHardwareBase.h : kAudioObjectPropertyElementMain =====
195:    @constant       kAudioObjectPropertyElementMain
199:						The deprecated synonym for kAudioObjectPropertyElementMain
207:    kAudioObjectPropertyElementMain			= 0,
208:    kAudioObjectPropertyElementMaster API_DEPRECATED_WITH_REPLACEMENT("kAudioObjectPropertyElementMain", macos(10.0, 12.0), ios(2.0, 15.0), watchos(1.0, 8.0), tvos(9.0, 15.0))	= kAudioObjectPropertyElementMain

===== AudioHardwareBase.h : kAudioObjectPropertyElementMaster =====
198:    @constant       kAudioObjectPropertyElementMaster
208:    kAudioObjectPropertyElementMaster API_DEPRECATED_WITH_REPLACEMENT("kAudioObjectPropertyElementMain", macos(10.0, 12.0), ios(2.0, 15.0), watchos(1.0, 8.0), tvos(9.0, 15.0))	= kAudioObjectPropertyElementMain

===== AudioHardware.h : kAudioObjectPropertyElementMain =====
(no matches -- these constants are not declared in AudioHardware.h, only AudioHardwareBase.h)

===== AudioHardware.h : kAudioObjectPropertyElementMaster =====
(no matches -- these constants are not declared in AudioHardware.h, only AudioHardwareBase.h)
```

Fuller context around the enum block (`AudioHardwareBase.h`, lines 190-210):

```
    @constant       kAudioObjectPropertyScopePlayThrough
                        The AudioObjectPropertyScope for properties that apply to the play through
                        side of an object.
    @constant       kAudioObjectPropertyElementMain
                        The AudioObjectPropertyElement value for properties that apply to the main
                        element or to the entire scope.
    @constant       kAudioObjectPropertyElementMaster
						The deprecated synonym for kAudioObjectPropertyElementMain
*/
CF_ENUM(AudioObjectPropertyScope)
{
    kAudioObjectPropertyScopeGlobal         = 'glob',
    kAudioObjectPropertyScopeInput          = 'inpt',
    kAudioObjectPropertyScopeOutput         = 'outp',
    kAudioObjectPropertyScopePlayThrough    = 'ptru',
    kAudioObjectPropertyElementMain			= 0,
    kAudioObjectPropertyElementMaster API_DEPRECATED_WITH_REPLACEMENT("kAudioObjectPropertyElementMain", macos(10.0, 12.0), ios(2.0, 15.0), watchos(1.0, 8.0), tvos(9.0, 15.0))	= kAudioObjectPropertyElementMain
};
```

**Finding:** The current (non-deprecated) selector is `kAudioObjectPropertyElementMain`,
value `0`. `kAudioObjectPropertyElementMaster` is `API_DEPRECATED_WITH_REPLACEMENT` since
macOS 12.0 and is defined as a numeric alias (`= kAudioObjectPropertyElementMain`), so it is
also `0` -- both names are numerically identical, only the deprecated name will eventually
trigger deprecation warnings under stricter build settings. `listener_spike.py` uses
`kAudioObjectPropertyElementMain` throughout.

A related deprecation was also discovered and applied: `kAudioDevicePropertyDeviceNameCFString`
is itself flagged as a deprecated alias for `kAudioObjectPropertyName` ('lnam') in
`AudioHardwareDeprecated.h`:

```
674:    kAudioDevicePropertyDeviceNameCFString                  = kAudioObjectPropertyName,
```

The spike queries `kAudioObjectPropertyName` directly instead of the deprecated alias.

---

## 2. Listener registration

`AudioObjectAddPropertyListener` was called against `kAudioObjectSystemObject` (id `1`) for
`kAudioHardwarePropertyDefaultOutputDevice` in the global scope with
`kAudioObjectPropertyElementMain`. It returned OSStatus `0` (`noErr`) on the first and only
attempt -- no retries, no ctypes crashes, no signature bugs needed fixing after the initial
write (argtypes/restype were derived directly from the grepped C signatures before writing
any Python).

Captured evidence (verbatim from the real run, see Section 3 for the full transcript):

```
[2026-07-10T20:22:36.371-04:00] === route-recovery-listener spike starting ===
[2026-07-10T20:22:36.371-04:00] This script NEVER opens an audio output stream. No sounddevice/PortAudio import. No audio will play.
[2026-07-10T20:22:36.463-04:00] AudioObjectAddPropertyListener returned OSStatus=0 (noErr) -> listener registered OK
[2026-07-10T20:22:36.463-04:00] CFRunLoop pump thread started (CFRunLoopRunInMode, 0.2s slices, background thread) -- property listener callbacks require a run loop pumping to be delivered.
```

At the end of the run, `AudioObjectRemovePropertyListener` also returned OSStatus `0`
(clean teardown, no leaked callback registration):

```
[2026-07-10T20:22:42.619-04:00] AudioObjectRemovePropertyListener returned OSStatus=0 (noErr)
```

---

## 3. Firing behavior

**Devices enumerated: 5 real output-capable devices** (out of 7 total AudioObject device ids
on the system -- the other 2 are input-only, e.g. the iPhone continuity mic and the built-in
mic, and were correctly excluded by the output-channel-count check):

```
[2026-07-10T20:22:36.463-04:00] Enumerated 7 total AudioObject device ids: [120, 105, 103, 98, 91, 71, 83]
[2026-07-10T20:22:36.547-04:00] Found 5 real output-capable device(s):
[2026-07-10T20:22:36.548-04:00]   - id=120 name='ASUS PB278' output_channels=2
[2026-07-10T20:22:36.548-04:00]   - id=105 name='ASUS PB278' output_channels=2
[2026-07-10T20:22:36.548-04:00]   - id=91 name='MacBook Pro Speakers' output_channels=2
[2026-07-10T20:22:36.549-04:00]   - id=71 name='Steam Streaming Microphone' output_channels=2
[2026-07-10T20:22:36.549-04:00]   - id=83 name='Steam Streaming Speakers' output_channels=2
[2026-07-10T20:22:36.549-04:00] Current default output device: id=91 name='MacBook Pro Speakers'
```

Note: `ASUS PB278` (an HDMI monitor) appears twice under two different AudioObjectIDs. This
was double-checked out-of-band by reading `kAudioDevicePropertyDeviceUID` for both ids --
they returned two genuinely distinct UIDs (`...0F19-0103803C2278` vs `...0F19-0104A53C2278`),
confirming this is real macOS behavior (the monitor exposes two separate CoreAudio device
objects, not a bug in the spike's channel-count logic). `Steam Streaming Microphone` also
legitimately reports 2 output channels -- it's a Valve virtual loopback device with both
input and output channels, confirmed against `system_profiler SPAudioDataType`.

**SwitchAudioSource:** not installed (`shutil.which("SwitchAudioSource")` returned `None`).
The script fell back to `AudioObjectSetPropertyData` on
`kAudioHardwarePropertyDefaultOutputDevice`, as specced for that case.

**Did the listener fire on a programmatic switch? YES**, on both the switch-away and the
switch-back. Full verbatim terminal output from the real run:

```
[2026-07-10T20:22:36.371-04:00] === route-recovery-listener spike starting ===
[2026-07-10T20:22:36.371-04:00] This script NEVER opens an audio output stream. No sounddevice/PortAudio import. No audio will play.
[2026-07-10T20:22:36.463-04:00] AudioObjectAddPropertyListener returned OSStatus=0 (noErr) -> listener registered OK
[2026-07-10T20:22:36.463-04:00] CFRunLoop pump thread started (CFRunLoopRunInMode, 0.2s slices, background thread) -- property listener callbacks require a run loop pumping to be delivered.
[2026-07-10T20:22:36.463-04:00] Enumerated 7 total AudioObject device ids: [120, 105, 103, 98, 91, 71, 83]
[2026-07-10T20:22:36.547-04:00] Found 5 real output-capable device(s):
[2026-07-10T20:22:36.548-04:00]   - id=120 name='ASUS PB278' output_channels=2
[2026-07-10T20:22:36.548-04:00]   - id=105 name='ASUS PB278' output_channels=2
[2026-07-10T20:22:36.548-04:00]   - id=91 name='MacBook Pro Speakers' output_channels=2
[2026-07-10T20:22:36.549-04:00]   - id=71 name='Steam Streaming Microphone' output_channels=2
[2026-07-10T20:22:36.549-04:00]   - id=83 name='Steam Streaming Speakers' output_channels=2
[2026-07-10T20:22:36.549-04:00] Current default output device: id=91 name='MacBook Pro Speakers'
[2026-07-10T20:22:36.552-04:00] SwitchAudioSource on PATH: None
[2026-07-10T20:22:36.552-04:00] >=2 output devices present -> attempting a REAL switch test: 'MacBook Pro Speakers' (id=91) -> 'ASUS PB278' (id=120)
[2026-07-10T20:22:36.552-04:00] SwitchAudioSource not found; falling back to AudioObjectSetPropertyData directly.
[2026-07-10T20:22:36.555-04:00] AudioObjectSetPropertyData(->'ASUS PB278') returned OSStatus=0 (noErr)
[2026-07-10T20:22:36.564-04:00] CALLBACK FIRED: default output device changed -> id=120 (ASUS PB278)
[2026-07-10T20:22:38.060-04:00] Drained queue event: ts=2026-07-10T20:22:36.564-04:00 new_device_id=120 name='ASUS PB278'
[2026-07-10T20:22:38.060-04:00] Listener fired during switch-away: True
[2026-07-10T20:22:38.060-04:00] Restoring original default output device: 'MacBook Pro Speakers' (id=91)
[2026-07-10T20:22:38.060-04:00] AudioObjectSetPropertyData(restore) returned OSStatus=0 (noErr)
[2026-07-10T20:22:38.062-04:00] CALLBACK FIRED: default output device changed -> id=91 (MacBook Pro Speakers)
[2026-07-10T20:22:39.571-04:00] Drained queue event (restore): ts=2026-07-10T20:22:38.062-04:00 new_device_id=91 name='MacBook Pro Speakers'
[2026-07-10T20:22:39.571-04:00] Listener fired during restore-back: True
[2026-07-10T20:22:39.571-04:00] RESTORATION CHECK: current default id=91 name='MacBook Pro Speakers'; matches original id=91: True
[2026-07-10T20:22:39.571-04:00] Draining queue for a few more seconds in case of delayed callback delivery...
[2026-07-10T20:22:42.619-04:00] AudioObjectRemovePropertyListener returned OSStatus=0 (noErr)
[2026-07-10T20:22:42.619-04:00] === route-recovery-listener spike finished (no audio was ever played) ===
```

Key observations from this run:
- The callback fired **inside ~9-13ms** of the `AudioObjectSetPropertyData` call returning
  (`20:22:36.555` set call -> `20:22:36.564` callback fired; `20:22:38.060` set call ->
  `20:22:38.062` callback fired). This is CoreAudio's HAL notifying near-synchronously.
- The callback thread successfully handed the event off to the main-thread-drained
  `queue.Queue` (proving requirement #6 -- cross-thread hand-off) -- the "Drained queue
  event" lines are printed on the main thread after `event_queue.get_nowait()`, distinct
  from the "CALLBACK FIRED" line printed synchronously inside the callback itself.
  Timestamps confirm the callback (`:36.564`) preceded the drain (`:38.060`) as expected.
  The ~1.5s gap between fire and drain is an artifact of the script's own
  `time.sleep(1.5)` polling interval, not listener latency.
- No ctypes crashes, segfaults, or garbage values were observed at any point. The
  `argtypes`/`restype` derived from grepping the actual C headers before writing any
  Python worked correctly on the first execution -- no signature-bug iteration was needed.
- No TCC/privacy permission prompt appeared. No sudo was required. Setting the default
  output device via `AudioObjectSetPropertyData` from an unsigned/unentitled `uv run`
  Python process worked without any permission gate.

---

## 4. Restoration confirmation

A real switch **was** performed (>=2 real output devices were present, so the "only 1
device" branch was not taken). The original default (`MacBook Pro Speakers`, id `91`) was
recorded before the switch, switched away to `ASUS PB278` (id `120`), then explicitly
switched back via a second `AudioObjectSetPropertyData` call, and verified by re-reading
`kAudioHardwarePropertyDefaultOutputDevice` afterward:

```
[2026-07-10T20:22:39.571-04:00] RESTORATION CHECK: current default id=91 name='MacBook Pro Speakers'; matches original id=91: True
```

Restoration confirmed and verified -- the machine's default output device was
`MacBook Pro Speakers` before, during, and after this spike (id `91` both before the test
and after restoration).

---

## 5. Go/no-go verdict

**follow-the-device viable.**

`AudioObjectAddPropertyListener` on `kAudioHardwarePropertyDefaultOutputDevice` registered
cleanly (OSStatus 0), required no elevated permissions or TCC prompts, and fired reliably
and near-instantly (single-digit-to-low-double-digit milliseconds) on both a real
switch-away and a real switch-back between two genuinely different physical/virtual output
devices on this machine, with the event correctly handed off from the CoreAudio callback
thread to a main-thread-drained queue. A future playback-following feature built on this
mechanism (re-opening or re-routing the sounddevice/PortAudio stream when the listener
fires) is technically well-supported by this primitive; the only remaining engineering
work would be in the app's own stream-teardown/reopen logic, not in device-change
detection.

---

## 6. No audio played

Confirmed: `listener_spike.py` never imports `sounddevice`, never opens a PortAudio/CoreAudio
output stream, and never calls any playback API. It only reads and writes the
`kAudioHardwarePropertyDefaultOutputDevice` property and reads device-enumeration/name
metadata. The captured run transcript's final line states this explicitly:
`=== route-recovery-listener spike finished (no audio was ever played) ===`, and this claim
was verified by inspection of the script (only `AudioObjectGetPropertyData`,
`AudioObjectSetPropertyData`, `AudioObjectGetPropertyDataSize`,
`AudioObjectAddPropertyListener`/`RemovePropertyListener`, and CoreFoundation string/run-loop
calls are made -- no stream, no `Play`, no audio buffer submission of any kind).

---

## Blockers encountered

None that remained open. No TCC/privacy prompt appeared, no sudo was needed, and no ctypes
signature bugs surfaced at runtime (the argtypes/restype tables were built directly from the
grepped C prototypes in `AudioHardware.h`/`AudioHardwareBase.h` before the first run, and the
first execution produced a clean, correct result with no crashes). The only design decision
worth flagging for whoever reads this for the ADR: this machine happens to have >=2 real
output devices, so the "only 1 device, manual AirPods toggle" fallback path in the script
(requirement #10) was written and lint-checked but **not exercised** on this run -- it remains
available for a human to run interactively on a single-output-device machine if that
scenario ever needs separate verification.
