# Speech IPC Probe

Disposable, dependency-free Swift proof of the `speech-stack` protocol-version 2 Unix-socket boundary. It validates framing, bounded socket operations, typed control errors, an exact nonempty selftest echo round-trip, unary requests, and close-after-first-audio cancellation behavior. It is deliberately separate from future Wilted production code.

The probe requires an explicit socket path. Progress stages go to stderr; one final machine-readable JSON object goes to stdout.

```sh
swift run --package-path Probes/SpeechIPCProbe speech-ipc-probe selftest --socket "$HOME/Documents/Projects/speech-stack/.state/speechd.sock"
swift run --package-path Probes/SpeechIPCProbe speech-ipc-probe status --socket "$HOME/Documents/Projects/speech-stack/.state/speechd.sock"
swift run --package-path Probes/SpeechIPCProbe speech-ipc-probe protocol-mismatch --socket "$HOME/Documents/Projects/speech-stack/.state/speechd.sock"
swift run --package-path Probes/SpeechIPCProbe speech-ipc-probe tts-cancel --socket "$HOME/Documents/Projects/speech-stack/.state/speechd.sock" --text "This is a short cancellation probe."
```

`tts-cancel` validates the first nonempty AUDIO frame as explicitly decoded little-endian Float32: its byte count must be divisible by four and every sample must be finite. It closes the socket and reports only byte count, sample count, and peak absolute amplitude; it never outputs audio content. Socket close is the cancellation signal; the output intentionally does not claim daemon acknowledgement because no acknowledgement is returned on that connection.

Run deterministic fake-socket tests without the live daemon:

```sh
swift test --package-path Probes/SpeechIPCProbe
bash tests/test-speech-ipc-probe.sh
```

Passing local tests or live commands does not resolve signed-runtime, hardened-runtime, App Sandbox, App Group/XPC, entitlements, or notarization proof. Those remain Phase 0 owner/captain gates.
