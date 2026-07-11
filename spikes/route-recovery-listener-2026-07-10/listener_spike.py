#!/usr/bin/env python3
"""Spike: can a pure-ctypes CoreAudio property listener detect a default-output-device
change reliably enough to justify a future "follow the device" playback mode?

Answers a go/no-go question for an ADR. Does NOT touch sounddevice/PortAudio and NEVER
opens an audio output stream — this script only reads/writes the
kAudioHardwarePropertyDefaultOutputDevice property and enumerates device metadata.

Pure ctypes only (stdlib + ctypes). No pip/uv dependency added. Run via:

    uv run --group dev python spikes/route-recovery-listener-2026-07-10/listener_spike.py

Design notes (see FINDINGS.md Section 1 for the exact grep evidence):
  - This SDK's AudioHardwareBase.h defines kAudioObjectPropertyElementMain = 0 as the
    current (macOS 12+) selector name; kAudioObjectPropertyElementMaster is the
    deprecated synonym, numerically identical (both 0). We use
    kAudioObjectPropertyElementMain throughout since it is the non-deprecated name,
    per Apple's own header (API_DEPRECATED_WITH_REPLACEMENT points Master -> Main).
  - kAudioDevicePropertyDeviceNameCFString is itself a deprecated alias for
    kAudioObjectPropertyName ('lnam') per AudioHardwareDeprecated.h, so we query
    kAudioObjectPropertyName directly instead.
"""

from __future__ import annotations

import ctypes
import queue
import shutil
import subprocess
import sys
import threading
import time
from ctypes import (
    CFUNCTYPE,
    POINTER,
    Structure,
    byref,
    c_int32,
    c_uint32,
    c_void_p,
    create_string_buffer,
    sizeof,
)
from datetime import UTC, datetime

# --------------------------------------------------------------------------------------
# Load frameworks (pure ctypes, no pyobjc)
# --------------------------------------------------------------------------------------

try:
    CoreAudio = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    CoreFoundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
except OSError as exc:  # pragma: no cover - environment-dependent
    print(f"FATAL: could not dlopen a required framework: {exc}")
    sys.exit(1)

# --------------------------------------------------------------------------------------
# Types / constants
# --------------------------------------------------------------------------------------

UInt32 = c_uint32
AudioObjectID = UInt32
OSStatus = c_int32


class AudioObjectPropertyAddress(Structure):
    _fields_ = [
        ("mSelector", UInt32),
        ("mScope", UInt32),
        ("mElement", UInt32),
    ]


class AudioBuffer(Structure):
    _fields_ = [
        ("mNumberChannels", UInt32),
        ("mDataByteSize", UInt32),
        ("mData", c_void_p),
    ]


def make_audio_buffer_list(n_buffers: int):
    """AudioBufferList is a variable-length struct (mBuffers[1] in the C header, but
    it's really mNumberBuffers-many). Build a ctypes type sized for n_buffers."""

    class AudioBufferList(Structure):
        _fields_ = [
            ("mNumberBuffers", UInt32),
            ("mBuffers", AudioBuffer * max(n_buffers, 1)),
        ]

    return AudioBufferList


def fourcc(code: str) -> int:
    """Pack a 4-char string into the UInt32 FourCharCode CoreAudio uses for selectors."""
    assert len(code) == 4, code
    return (ord(code[0]) << 24) | (ord(code[1]) << 16) | (ord(code[2]) << 8) | ord(code[3])


def fourcc_to_str(value: int) -> str:
    """Best-effort decode of a FourCC-shaped OSStatus/selector back to ASCII for logs."""
    try:
        chars = [
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF,
        ]
        if all(32 <= c < 127 for c in chars):
            return "".join(chr(c) for c in chars)
    except Exception:
        pass
    return ""


def describe_status(status: int) -> str:
    if status == 0:
        return "0 (noErr)"
    fc = fourcc_to_str(status)
    if fc:
        return f"{status} ('{fc}')"
    return str(status)


# Constants (per Step 1: kAudioObjectPropertyElementMain is current; value 0 either way)
kAudioObjectSystemObject = 1
kAudioObjectPropertyElementMain = 0  # current selector name; == deprecated ...Master
kAudioHardwarePropertyDefaultOutputDevice = fourcc("dOut")
kAudioHardwarePropertyDevices = fourcc("dev#")
kAudioObjectPropertyScopeGlobal = fourcc("glob")
kAudioObjectPropertyScopeOutput = fourcc("outp")
kAudioObjectPropertyName = fourcc("lnam")
kAudioDevicePropertyStreamConfiguration = fourcc("slay")

# --------------------------------------------------------------------------------------
# CoreAudio function bindings (argtypes/restype are load-bearing for ctypes correctness)
# --------------------------------------------------------------------------------------

AudioObjectGetPropertyDataSize = CoreAudio.AudioObjectGetPropertyDataSize
AudioObjectGetPropertyDataSize.restype = OSStatus
AudioObjectGetPropertyDataSize.argtypes = [
    AudioObjectID,
    POINTER(AudioObjectPropertyAddress),
    UInt32,
    c_void_p,
    POINTER(UInt32),
]

AudioObjectGetPropertyData = CoreAudio.AudioObjectGetPropertyData
AudioObjectGetPropertyData.restype = OSStatus
AudioObjectGetPropertyData.argtypes = [
    AudioObjectID,
    POINTER(AudioObjectPropertyAddress),
    UInt32,
    c_void_p,
    POINTER(UInt32),
    c_void_p,
]

AudioObjectSetPropertyData = CoreAudio.AudioObjectSetPropertyData
AudioObjectSetPropertyData.restype = OSStatus
AudioObjectSetPropertyData.argtypes = [
    AudioObjectID,
    POINTER(AudioObjectPropertyAddress),
    UInt32,
    c_void_p,
    UInt32,
    c_void_p,
]

# The classic (non-block) C-callback signature, per AudioHardware.h:
#   typedef OSStatus (*AudioObjectPropertyListenerProc)(
#       AudioObjectID inObjectID,
#       UInt32 inNumberAddresses,
#       const AudioObjectPropertyAddress *inAddresses,
#       void *inClientData);
AudioObjectPropertyListenerProc = CFUNCTYPE(
    OSStatus, AudioObjectID, UInt32, POINTER(AudioObjectPropertyAddress), c_void_p
)

AudioObjectAddPropertyListener = CoreAudio.AudioObjectAddPropertyListener
AudioObjectAddPropertyListener.restype = OSStatus
AudioObjectAddPropertyListener.argtypes = [
    AudioObjectID,
    POINTER(AudioObjectPropertyAddress),
    AudioObjectPropertyListenerProc,
    c_void_p,
]

AudioObjectRemovePropertyListener = CoreAudio.AudioObjectRemovePropertyListener
AudioObjectRemovePropertyListener.restype = OSStatus
AudioObjectRemovePropertyListener.argtypes = [
    AudioObjectID,
    POINTER(AudioObjectPropertyAddress),
    AudioObjectPropertyListenerProc,
    c_void_p,
]

# CoreFoundation: CFStringRef -> UTF-8. We use CFStringGetCStringPtr (fast path, may
# return NULL) and fall back to CFStringGetCString (copies into our buffer).
CFStringGetCStringPtr = CoreFoundation.CFStringGetCStringPtr
CFStringGetCStringPtr.restype = c_void_p
CFStringGetCStringPtr.argtypes = [c_void_p, c_uint32]

CFStringGetCString = CoreFoundation.CFStringGetCString
CFStringGetCString.restype = ctypes.c_bool
CFStringGetCString.argtypes = [c_void_p, ctypes.c_char_p, ctypes.c_long, c_uint32]

CFStringGetLength = CoreFoundation.CFStringGetLength
CFStringGetLength.restype = ctypes.c_long
CFStringGetLength.argtypes = [c_void_p]

CFRelease = CoreFoundation.CFRelease
CFRelease.restype = None
CFRelease.argtypes = [c_void_p]

CFRunLoopRunInMode = CoreFoundation.CFRunLoopRunInMode
CFRunLoopRunInMode.restype = c_int32
CFRunLoopRunInMode.argtypes = [c_void_p, ctypes.c_double, ctypes.c_bool]

# kCFRunLoopDefaultMode is a CFStringRef exported as data symbol from CoreFoundation.
kCFRunLoopDefaultMode = c_void_p.in_dll(CoreFoundation, "kCFRunLoopDefaultMode")

kCFStringEncodingUTF8 = 0x08000100


def cfstring_to_str(cfstring_ref: int) -> str:
    """Convert a CFStringRef (as a raw pointer value) to a Python str."""
    if not cfstring_ref:
        return ""
    ptr = CFStringGetCStringPtr(cfstring_ref, kCFStringEncodingUTF8)
    if ptr:
        return ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8", "replace")
    # Fast path returned NULL (common for non-ASCII-backed CFStrings) -> copy out.
    length = CFStringGetLength(cfstring_ref)
    buf_size = max(length * 4 + 1, 64)
    buf = create_string_buffer(buf_size)
    ok = CFStringGetCString(cfstring_ref, buf, buf_size, kCFStringEncodingUTF8)
    if ok:
        return buf.value.decode("utf-8", "replace")
    return "<unreadable CFString>"


def log(msg: str) -> None:
    ts = datetime.now(UTC).astimezone().isoformat(timespec="milliseconds")
    print(f"[{ts}] {msg}", flush=True)


# --------------------------------------------------------------------------------------
# CoreAudio helpers
# --------------------------------------------------------------------------------------


def get_default_output_device() -> int:
    addr = AudioObjectPropertyAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
    device_id = AudioObjectID(0)
    size = UInt32(sizeof(AudioObjectID))
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, byref(addr), 0, None, byref(size), byref(device_id))
    if status != 0:
        log(f"ERROR: AudioObjectGetPropertyData(DefaultOutputDevice) failed: {describe_status(status)}")
        return -1
    return device_id.value


def set_default_output_device(device_id: int) -> int:
    addr = AudioObjectPropertyAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
    new_id = AudioObjectID(device_id)
    status = AudioObjectSetPropertyData(
        kAudioObjectSystemObject, byref(addr), 0, None, UInt32(sizeof(AudioObjectID)), byref(new_id)
    )
    return status


def list_all_device_ids() -> list[int]:
    addr = AudioObjectPropertyAddress(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
    size = UInt32(0)
    status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, byref(addr), 0, None, byref(size))
    if status != 0:
        log(f"ERROR: AudioObjectGetPropertyDataSize(Devices) failed: {describe_status(status)}")
        return []
    n = size.value // sizeof(AudioObjectID)
    arr = (AudioObjectID * n)()
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, byref(addr), 0, None, byref(size), arr)
    if status != 0:
        log(f"ERROR: AudioObjectGetPropertyData(Devices) failed: {describe_status(status)}")
        return []
    return [arr[i] for i in range(n)]


def device_output_channel_count(device_id: int) -> int:
    """Sum of mNumberChannels across the output-scope stream configuration's buffers.
    A device with 0 here has no output capability (e.g. an input-only mic)."""
    addr = AudioObjectPropertyAddress(
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    )
    size = UInt32(0)
    status = AudioObjectGetPropertyDataSize(device_id, byref(addr), 0, None, byref(size))
    if status != 0 or size.value == 0:
        return 0
    # size is the byte size of a variable-length AudioBufferList; figure out mNumberBuffers
    # by reading the struct with a generously-sized buffer type, then trust mNumberBuffers.
    raw = create_string_buffer(size.value)
    status = AudioObjectGetPropertyData(device_id, byref(addr), 0, None, byref(size), raw)
    if status != 0:
        return 0
    n_buffers = ctypes.cast(raw, POINTER(UInt32))[0]
    if n_buffers == 0:
        return 0
    ABL = make_audio_buffer_list(n_buffers)
    if sizeof(ABL) > len(raw):
        # Shouldn't happen (size.value already accounts for n_buffers), but guard anyway.
        return 0
    abl = ABL.from_buffer_copy(raw.raw)
    return sum(abl.mBuffers[i].mNumberChannels for i in range(n_buffers))


def device_name(device_id: int) -> str:
    addr = AudioObjectPropertyAddress(
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
    cfstr = c_void_p(0)
    size = UInt32(sizeof(c_void_p))
    status = AudioObjectGetPropertyData(device_id, byref(addr), 0, None, byref(size), byref(cfstr))
    if status != 0 or not cfstr.value:
        return f"<unknown device {device_id}, status={describe_status(status)}>"
    name = cfstring_to_str(cfstr.value)
    CFRelease(cfstr.value)
    return name


# --------------------------------------------------------------------------------------
# Listener plumbing
# --------------------------------------------------------------------------------------

event_queue: queue.Queue[tuple[str, int]] = queue.Queue()

# Module-level reference so the CFUNCTYPE closure is never garbage collected while
# registered with CoreAudio (a GC'd callback here would crash the callback thread).
_listener_proc_ref = None


def _make_listener_callback():
    def _callback(in_object_id, in_number_addresses, in_addresses, in_client_data):
        # Read the new default output device id back out from inside the callback.
        new_id = get_default_output_device()
        ts = datetime.now(UTC).astimezone().isoformat(timespec="milliseconds")
        name = device_name(new_id)
        print(f"[{ts}] CALLBACK FIRED: default output device changed -> id={new_id} ({name})", flush=True)
        event_queue.put((ts, new_id))
        return 0  # noErr

    return AudioObjectPropertyListenerProc(_callback)


def install_listener() -> int:
    global _listener_proc_ref
    _listener_proc_ref = _make_listener_callback()
    addr = AudioObjectPropertyAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
    status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, byref(addr), _listener_proc_ref, None)
    return status


def remove_listener() -> int:
    if _listener_proc_ref is None:
        return 0
    addr = AudioObjectPropertyAddress(
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    )
    status = AudioObjectRemovePropertyListener(kAudioObjectSystemObject, byref(addr), _listener_proc_ref, None)
    return status


def run_loop_pump(stop_event: threading.Event) -> None:
    """Pump a CFRunLoop on this (background) thread so queued property-listener
    callbacks actually get delivered. CoreAudio's HAL notification mechanism posts
    callbacks onto whatever run loop was running at registration time (historically
    the run loop the process was registered against internally); pumping the CURRENT
    thread's run loop in short slices here is the documented, simplest way to make
    sure *some* run loop is spinning so the callback has a chance to be delivered.
    We use CFRunLoopRunInMode in a loop (rather than CFRunLoopRun, which never
    returns) so we can check stop_event between spins and shut down cleanly.
    """
    while not stop_event.is_set():
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, True)


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------


def main() -> int:
    log("=== route-recovery-listener spike starting ===")
    log("This script NEVER opens an audio output stream. No sounddevice/PortAudio import. No audio will play.")

    # --- Register the listener -------------------------------------------------------
    status = install_listener()
    if status != 0:
        log(f"FATAL: AudioObjectAddPropertyListener failed: {describe_status(status)}")
        return 1
    log(f"AudioObjectAddPropertyListener returned OSStatus={describe_status(status)} -> listener registered OK")

    # --- Start the CFRunLoop pump on a background thread ------------------------------
    stop_event = threading.Event()
    runloop_thread = threading.Thread(target=run_loop_pump, args=(stop_event,), daemon=True)
    runloop_thread.start()
    log(
        "CFRunLoop pump thread started (CFRunLoopRunInMode, 0.2s slices, background thread) "
        "-- property listener callbacks require a run loop pumping to be delivered."
    )

    try:
        # --- Enumerate output devices --------------------------------------------
        all_ids = list_all_device_ids()
        log(f"Enumerated {len(all_ids)} total AudioObject device ids: {all_ids}")

        output_devices: list[tuple[int, str, int]] = []
        for dev_id in all_ids:
            chans = device_output_channel_count(dev_id)
            if chans > 0:
                name = device_name(dev_id)
                output_devices.append((dev_id, name, chans))

        log(f"Found {len(output_devices)} real output-capable device(s):")
        for dev_id, name, chans in output_devices:
            log(f"  - id={dev_id} name={name!r} output_channels={chans}")

        original_default_id = get_default_output_device()
        original_default_name = device_name(original_default_id)
        log(f"Current default output device: id={original_default_id} name={original_default_name!r}")

        switcher = shutil.which("SwitchAudioSource")
        log(f"SwitchAudioSource on PATH: {switcher!r}")

        if len(output_devices) >= 2:
            # --- Real switch test ------------------------------------------------
            target = next((d for d in output_devices if d[0] != original_default_id), None)
            if target is None:
                log("Unexpected: >=2 output devices but no candidate != current default. Skipping switch test.")
            else:
                target_id, target_name, _ = target
                log(
                    f">=2 output devices present -> attempting a REAL switch test: "
                    f"{original_default_name!r} (id={original_default_id}) -> {target_name!r} (id={target_id})"
                )

                if switcher:
                    log(f"Using SwitchAudioSource -s {target_name!r}")
                    proc = subprocess.run([switcher, "-s", target_name], capture_output=True, text=True, timeout=10)
                    out, err = proc.stdout.strip(), proc.stderr.strip()
                    log(f"SwitchAudioSource exit={proc.returncode} stdout={out!r} stderr={err!r}")
                else:
                    log("SwitchAudioSource not found; falling back to AudioObjectSetPropertyData directly.")
                    set_status = set_default_output_device(target_id)
                    log(
                        f"AudioObjectSetPropertyData(->{target_name!r}) returned OSStatus={describe_status(set_status)}"
                    )

                # Give the run loop a moment to deliver the callback.
                time.sleep(1.5)
                fired = False
                while True:
                    try:
                        ts, new_id = event_queue.get_nowait()
                        fired = True
                        log(f"Drained queue event: ts={ts} new_device_id={new_id} name={device_name(new_id)!r}")
                    except queue.Empty:
                        break
                log(f"Listener fired during switch-away: {fired}")

                # Switch back.
                log(f"Restoring original default output device: {original_default_name!r} (id={original_default_id})")
                if switcher:
                    proc = subprocess.run(
                        [switcher, "-s", original_default_name], capture_output=True, text=True, timeout=10
                    )
                    out, err = proc.stdout.strip(), proc.stderr.strip()
                    log(f"SwitchAudioSource restore exit={proc.returncode} stdout={out!r} stderr={err!r}")
                else:
                    set_status = set_default_output_device(original_default_id)
                    log(f"AudioObjectSetPropertyData(restore) returned OSStatus={describe_status(set_status)}")

                time.sleep(1.5)
                fired_on_restore = False
                while True:
                    try:
                        ts, new_id = event_queue.get_nowait()
                        fired_on_restore = True
                        nm = device_name(new_id)
                        log(f"Drained queue event (restore): ts={ts} new_device_id={new_id} name={nm!r}")
                    except queue.Empty:
                        break
                log(f"Listener fired during restore-back: {fired_on_restore}")

                verify_id = get_default_output_device()
                verify_name = device_name(verify_id)
                restored_ok = verify_id == original_default_id
                log(
                    f"RESTORATION CHECK: current default id={verify_id} name={verify_name!r}; "
                    f"matches original id={original_default_id}: {restored_ok}"
                )
                if not restored_ok:
                    log("WARNING: restoration verification FAILED -- default output device does not match original!")
        else:
            # --- Only one real output device: cannot do a real switch test ------
            log("Only 1 real output-capable device present -- cannot perform a real 2-device switch test.")
            log("Attempting a set-to-self (no-op) call to confirm the Set API path itself doesn't error.")
            set_status = set_default_output_device(original_default_id)
            log(f"AudioObjectSetPropertyData(set-to-self) returned OSStatus={describe_status(set_status)}")
            log(
                "NOTE: a set-to-self is not expected to fire the listener (CoreAudio should suppress "
                "notifications when the value doesn't actually change) -- draining queue to confirm."
            )
            time.sleep(1.0)
            fired = False
            while True:
                try:
                    ts, new_id = event_queue.get_nowait()
                    fired = True
                    log(f"Drained queue event: ts={ts} new_device_id={new_id}")
                except queue.Empty:
                    break
            log(f"Listener fired on set-to-self: {fired} (expected False)")
            log("Could not test a REAL device switch -- only one output device present on this machine.")
            log(
                "listener installed; now manually switch output device -- e.g. toggle AirPods -- "
                "and watch for fire events; Ctrl-C to exit"
            )
            log("(For this automated spike run, only running briefly rather than blocking indefinitely.)")

        # --- Brief drain window so a human running this interactively could see fires ---
        log("Draining queue for a few more seconds in case of delayed callback delivery...")
        deadline = time.time() + 3
        while time.time() < deadline:
            try:
                ts, new_id = event_queue.get(timeout=0.5)
                log(f"Late-drained queue event: ts={ts} new_device_id={new_id} name={device_name(new_id)!r}")
            except queue.Empty:
                continue

    finally:
        stop_event.set()
        runloop_thread.join(timeout=2)
        rm_status = remove_listener()
        log(f"AudioObjectRemovePropertyListener returned OSStatus={describe_status(rm_status)}")
        log("=== route-recovery-listener spike finished (no audio was ever played) ===")

    return 0


if __name__ == "__main__":
    sys.exit(main())
