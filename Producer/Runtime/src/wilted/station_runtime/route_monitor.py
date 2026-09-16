"""``RouteMonitor`` — detects a macOS default-output-device change.

The A.0.1 spike (``spikes/route-recovery-listener-2026-07-10/``) proved a
pure-ctypes ``AudioObjectAddPropertyListener`` on
``kAudioHardwarePropertyDefaultOutputDevice`` reliably detects a default
output device switch (~10ms latency, no TCC prompt, clean teardown) — see
``FINDINGS.md``'s "follow-the-device viable" verdict. This module wraps that
primitive behind an injectable :class:`RouteBackend` seam so the TUI/tests
never need to touch real CoreAudio, mirroring ``CheckpointPoller``'s
lifecycle shape: :meth:`RouteMonitor.start` raises ``RuntimeError`` on a
double-start, :meth:`RouteMonitor.stop` is idempotent, and the real backend
runs its listener-delivery loop on a daemon thread.

``_CoreAudioBackend`` ports its ctypes struct/function signatures, FourCC
constants, callback trampoline, and ``CFRunLoopRunInMode`` pump loop
directly from ``spikes/route-recovery-listener-2026-07-10/listener_spike.py``
(that spike's argtypes/restype tables — derived from grepping the real SDK
headers before writing any Python — ran correctly on real hardware on the
first try, per ``FINDINGS.md`` section 2, so they are reused verbatim here
rather than re-derived). It queries the device name via
``kAudioObjectPropertyName`` ('lnam'), NOT the deprecated
``kAudioDevicePropertyDeviceNameCFString`` alias (``FINDINGS.md`` section 1).
It is exercised ONLY on real macOS hardware (Plan A task A.5); unit tests
use a fake :class:`RouteBackend` exclusively (see ``tests/test_route_monitor.py``)
and never construct this class or touch real CoreAudio.

``on_route_change`` fires on the backend's own delivery thread — for the
real ``_CoreAudioBackend``, its CFRunLoop pump thread — never the caller's
thread. A caller (the TUI) MUST marshal any UI/station-state work back onto
its own thread via ``post_message``, NOT ``call_from_thread`` — see
``wilted.tui.RouteChanged``'s docstring for the same deadlock lesson
``PlaybackCompleted`` already documents.
"""

from __future__ import annotations

import ctypes
import logging
import sys
import threading
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from collections.abc import Callable

logger = logging.getLogger(__name__)

_JOIN_TIMEOUT_SECONDS = 5.0
"""Bound on how long :meth:`RouteMonitor.stop`/:meth:`_CoreAudioBackend.unregister`
wait for the backend's pump thread to exit, matching ``CheckpointPoller``'s/
``StationController``'s own ``_JOIN_TIMEOUT_SECONDS`` convention."""

_RUN_LOOP_SLICE_SECONDS = 0.2
"""``CFRunLoopRunInMode`` slice duration for the pump thread — matches
``listener_spike.py``'s ``run_loop_pump`` exactly (short slices so a stop
request is noticed promptly instead of blocking in ``CFRunLoopRun``, which
never returns)."""


@dataclass(frozen=True, slots=True)
class RouteChangeEvent:
    """One default-output-device change, as delivered by a :class:`RouteBackend`."""

    device_id: int
    device_name: str


class RouteBackend(Protocol):
    """The seam :class:`RouteMonitor` depends on. Structural, not nominal.

    ``register``/``unregister`` need not be idempotent or double-start-safe
    on their own — :class:`RouteMonitor` is what enforces that discipline on
    top of a backend; a backend only needs to actually start/stop delivering
    events when asked.
    """

    def register(self, callback: Callable[[RouteChangeEvent], None]) -> None: ...

    def unregister(self) -> None: ...

    def current_device(self) -> RouteChangeEvent: ...


class RouteMonitor:
    """Lifecycle wrapper around a :class:`RouteBackend` (default: real CoreAudio).

    Modeled on ``CheckpointPoller``: :meth:`start` raises ``RuntimeError`` on
    a double-start; :meth:`stop` is idempotent and safe to call even without
    a prior :meth:`start`. ``on_route_change`` is invoked on whatever thread
    the backend delivers events on (for the real ``_CoreAudioBackend``, its
    CFRunLoop pump thread) — see the module docstring for the marshaling
    requirement this places on callers.
    """

    def __init__(
        self,
        *,
        on_route_change: Callable[[RouteChangeEvent], None],
        backend: RouteBackend | None = None,
    ) -> None:
        self._on_route_change = on_route_change
        self._backend: RouteBackend = backend if backend is not None else _CoreAudioBackend()
        self._running = False

    def start(self) -> None:
        """Register the backend's listener.

        Raises:
            RuntimeError: This monitor is already running.
        """
        if self._running:
            raise RuntimeError("RouteMonitor.start() called twice on the same instance")
        self._running = True
        self._backend.register(self._dispatch)

    def _dispatch(self, event: RouteChangeEvent) -> None:
        """Forward a backend event to ``on_route_change`` — unless stopped.

        Guards against a backend that may still hold (or race on) a callback
        reference for a brief window around :meth:`stop` — e.g. an in-flight
        CoreAudio callback already on the wire when ``unregister`` runs, or a
        test fake that doesn't drop its stored callback on ``unregister``.
        Runs on the backend's delivery thread, same as ``on_route_change``.
        """
        if not self._running:
            return
        self._on_route_change(event)

    def stop(self) -> None:
        """Unregister the backend's listener. Safe to call more than once."""
        if not self._running:
            return
        self._running = False
        self._backend.unregister()


# ---------------------------------------------------------------------------
# ctypes CoreAudio bindings — darwin only. Ported from
# spikes/route-recovery-listener-2026-07-10/listener_spike.py (argtypes/
# restype tables verified against real hardware — see FINDINGS.md section 2
# — reused verbatim rather than re-derived). Guarded behind
# ``sys.platform == "darwin"`` so importing this module never fails to load
# on a non-macOS platform.
# ---------------------------------------------------------------------------

if sys.platform == "darwin":
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

    _CoreAudio = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    _CoreFoundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

    _UInt32 = c_uint32
    _AudioObjectID = _UInt32
    _OSStatus = c_int32

    class _AudioObjectPropertyAddress(Structure):
        _fields_ = [
            ("mSelector", _UInt32),
            ("mScope", _UInt32),
            ("mElement", _UInt32),
        ]

    def _fourcc(code: str) -> int:
        """Pack a 4-char string into the UInt32 FourCharCode CoreAudio uses for selectors."""
        return (ord(code[0]) << 24) | (ord(code[1]) << 16) | (ord(code[2]) << 8) | ord(code[3])

    # listener_spike.py FINDINGS.md section 1: kAudioObjectPropertyElementMain
    # (=0) is the current, non-deprecated selector name; the deprecated
    # kAudioObjectPropertyElementMaster synonym is numerically identical.
    _kAudioObjectSystemObject = 1
    _kAudioObjectPropertyElementMain = 0
    _kAudioHardwarePropertyDefaultOutputDevice = _fourcc("dOut")
    _kAudioObjectPropertyScopeGlobal = _fourcc("glob")
    # kAudioObjectPropertyName ('lnam'), NOT the deprecated
    # kAudioDevicePropertyDeviceNameCFString alias — FINDINGS.md section 1.
    _kAudioObjectPropertyName = _fourcc("lnam")

    _AudioObjectGetPropertyData = _CoreAudio.AudioObjectGetPropertyData
    _AudioObjectGetPropertyData.restype = _OSStatus
    _AudioObjectGetPropertyData.argtypes = [
        _AudioObjectID,
        POINTER(_AudioObjectPropertyAddress),
        _UInt32,
        c_void_p,
        POINTER(_UInt32),
        c_void_p,
    ]

    # The classic (non-block) C-callback signature, per AudioHardware.h:
    #   typedef OSStatus (*AudioObjectPropertyListenerProc)(
    #       AudioObjectID inObjectID,
    #       UInt32 inNumberAddresses,
    #       const AudioObjectPropertyAddress *inAddresses,
    #       void *inClientData);
    _AudioObjectPropertyListenerProc = CFUNCTYPE(
        _OSStatus, _AudioObjectID, _UInt32, POINTER(_AudioObjectPropertyAddress), c_void_p
    )

    _AudioObjectAddPropertyListener = _CoreAudio.AudioObjectAddPropertyListener
    _AudioObjectAddPropertyListener.restype = _OSStatus
    _AudioObjectAddPropertyListener.argtypes = [
        _AudioObjectID,
        POINTER(_AudioObjectPropertyAddress),
        _AudioObjectPropertyListenerProc,
        c_void_p,
    ]

    _AudioObjectRemovePropertyListener = _CoreAudio.AudioObjectRemovePropertyListener
    _AudioObjectRemovePropertyListener.restype = _OSStatus
    _AudioObjectRemovePropertyListener.argtypes = [
        _AudioObjectID,
        POINTER(_AudioObjectPropertyAddress),
        _AudioObjectPropertyListenerProc,
        c_void_p,
    ]

    # CoreFoundation: CFStringRef -> UTF-8. Fast path (CFStringGetCStringPtr,
    # may return NULL) with a copying fallback (CFStringGetCString).
    _CFStringGetCStringPtr = _CoreFoundation.CFStringGetCStringPtr
    _CFStringGetCStringPtr.restype = c_void_p
    _CFStringGetCStringPtr.argtypes = [c_void_p, c_uint32]

    _CFStringGetCString = _CoreFoundation.CFStringGetCString
    _CFStringGetCString.restype = ctypes.c_bool
    _CFStringGetCString.argtypes = [c_void_p, ctypes.c_char_p, ctypes.c_long, c_uint32]

    _CFStringGetLength = _CoreFoundation.CFStringGetLength
    _CFStringGetLength.restype = ctypes.c_long
    _CFStringGetLength.argtypes = [c_void_p]

    _CFRelease = _CoreFoundation.CFRelease
    _CFRelease.restype = None
    _CFRelease.argtypes = [c_void_p]

    _CFRunLoopRunInMode = _CoreFoundation.CFRunLoopRunInMode
    _CFRunLoopRunInMode.restype = c_int32
    _CFRunLoopRunInMode.argtypes = [c_void_p, ctypes.c_double, ctypes.c_bool]

    # kCFRunLoopDefaultMode is a CFStringRef exported as a data symbol.
    _kCFRunLoopDefaultMode = c_void_p.in_dll(_CoreFoundation, "kCFRunLoopDefaultMode")

    _kCFStringEncodingUTF8 = 0x08000100

    def _cfstring_to_str(cfstring_ref: int) -> str:
        """Convert a CFStringRef (raw pointer value) to a Python str."""
        if not cfstring_ref:
            return ""
        ptr = _CFStringGetCStringPtr(cfstring_ref, _kCFStringEncodingUTF8)
        if ptr:
            return ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8", "replace")
        # Fast path returned NULL (common for non-ASCII-backed CFStrings) -> copy out.
        length = _CFStringGetLength(cfstring_ref)
        buf_size = max(length * 4 + 1, 64)
        buf = create_string_buffer(buf_size)
        ok = _CFStringGetCString(cfstring_ref, buf, buf_size, _kCFStringEncodingUTF8)
        if ok:
            return buf.value.decode("utf-8", "replace")
        return "<unreadable CFString>"

    def _get_default_output_device() -> int:
        addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDefaultOutputDevice,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        device_id = _AudioObjectID(0)
        size = _UInt32(sizeof(_AudioObjectID))
        status = _AudioObjectGetPropertyData(
            _kAudioObjectSystemObject, byref(addr), 0, None, byref(size), byref(device_id)
        )
        if status != 0:
            logger.error("AudioObjectGetPropertyData(DefaultOutputDevice) failed: OSStatus=%d", status)
            return -1
        return device_id.value

    def _device_name(device_id: int) -> str:
        addr = _AudioObjectPropertyAddress(
            _kAudioObjectPropertyName,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        cfstr = c_void_p(0)
        size = _UInt32(sizeof(c_void_p))
        status = _AudioObjectGetPropertyData(device_id, byref(addr), 0, None, byref(size), byref(cfstr))
        if status != 0 or not cfstr.value:
            return f"<unknown device {device_id}>"
        name = _cfstring_to_str(cfstr.value)
        _CFRelease(cfstr.value)
        return name


class _CoreAudioBackend(RouteBackend):
    """Real ctypes CoreAudio backend for :class:`RouteMonitor`.

    ``register``/``unregister`` are no-ops on non-darwin platforms and
    ``current_device`` returns a sentinel — this project runs macOS-only
    (David's hardware, macOS CI), but the guard is defensive so importing
    this module never fails to load elsewhere.

    Exercised ONLY on real macOS hardware (Plan A task A.5) — unit tests
    never construct this class; they inject a fake :class:`RouteBackend`
    (see ``tests/test_route_monitor.py``).
    """

    def __init__(self) -> None:
        self._callback: Callable[[RouteChangeEvent], None] | None = None
        # Strong Python reference to the ctypes CFUNCTYPE trampoline — MUST
        # be retained for as long as it's registered with CoreAudio, or it
        # can be garbage-collected out from under a live callback
        # registration and crash the pump thread (listener_spike.py keeps
        # this as a module-level global for the same reason; here it's an
        # instance attribute instead, scoped to this backend's lifetime).
        self._listener_proc_ref = None
        self._stop_event = threading.Event()
        self._pump_thread: threading.Thread | None = None

    def register(self, callback: Callable[[RouteChangeEvent], None]) -> None:
        if sys.platform != "darwin":
            return
        self._callback = callback
        self._listener_proc_ref = _AudioObjectPropertyListenerProc(self._on_property_changed)
        addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDefaultOutputDevice,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        status = _AudioObjectAddPropertyListener(_kAudioObjectSystemObject, byref(addr), self._listener_proc_ref, None)
        if status != 0:
            logger.error("AudioObjectAddPropertyListener failed: OSStatus=%d — route monitoring disabled", status)
            self._listener_proc_ref = None
            self._callback = None
            return

        # CFRunLoop pump thread — property listener callbacks require a run
        # loop pumping to be delivered (listener_spike.py FINDINGS.md
        # section 2).
        self._stop_event.clear()
        self._pump_thread = threading.Thread(
            target=self._run_loop_pump,
            name="route-monitor-cfrunloop",
            daemon=True,
        )
        self._pump_thread.start()

    def _on_property_changed(self, in_object_id, in_number_addresses, in_addresses, in_client_data) -> int:
        """The ``AudioObjectPropertyListenerProc`` trampoline — runs on the pump thread."""
        device_id = _get_default_output_device()
        name = _device_name(device_id)
        if self._callback is not None:
            self._callback(RouteChangeEvent(device_id=device_id, device_name=name))
        return 0  # noErr

    def _run_loop_pump(self) -> None:
        """Pump a CFRunLoop in short slices so queued callbacks get delivered.

        Ported from ``listener_spike.py``'s ``run_loop_pump``:
        ``CFRunLoopRunInMode`` in a loop (rather than ``CFRunLoopRun``, which
        never returns) so :meth:`unregister` can signal ``_stop_event`` and
        this thread exits promptly instead of blocking forever.
        """
        while not self._stop_event.is_set():
            _CFRunLoopRunInMode(_kCFRunLoopDefaultMode, _RUN_LOOP_SLICE_SECONDS, True)

    def unregister(self) -> None:
        if sys.platform != "darwin":
            return
        self._stop_event.set()
        if self._pump_thread is not None:
            self._pump_thread.join(timeout=_JOIN_TIMEOUT_SECONDS)
            if self._pump_thread.is_alive():
                logger.error(
                    "_CoreAudioBackend.unregister(): CFRunLoop pump thread did not exit within %.1fs",
                    _JOIN_TIMEOUT_SECONDS,
                )
            self._pump_thread = None
        if self._listener_proc_ref is not None:
            addr = _AudioObjectPropertyAddress(
                _kAudioHardwarePropertyDefaultOutputDevice,
                _kAudioObjectPropertyScopeGlobal,
                _kAudioObjectPropertyElementMain,
            )
            status = _AudioObjectRemovePropertyListener(
                _kAudioObjectSystemObject, byref(addr), self._listener_proc_ref, None
            )
            if status != 0:
                logger.error("AudioObjectRemovePropertyListener failed: OSStatus=%d", status)
            self._listener_proc_ref = None
        self._callback = None

    def current_device(self) -> RouteChangeEvent:
        if sys.platform != "darwin":
            return RouteChangeEvent(device_id=-1, device_name="<non-darwin>")
        device_id = _get_default_output_device()
        return RouteChangeEvent(device_id=device_id, device_name=_device_name(device_id))


__all__ = ["RouteBackend", "RouteChangeEvent", "RouteMonitor"]
