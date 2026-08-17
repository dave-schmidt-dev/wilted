# Signed Speech Runtime Probe

This credential-free Phase 0 probe assembles the existing `SpeechIPCProbe` executable into a disposable macOS `.app`, signs the copied bundle with an ad-hoc hardened-runtime signature, and executes its protocol-v2 `selftest` against a bundled fake Unix-socket harness.

```sh
bash Probes/SignedSpeechRuntimeProbe/signed-speech-runtime-probe.sh
```

An existing executable may be supplied with `--probe PATH`; otherwise the wrapper builds `SpeechIPCProbe` into its temporary workspace. The default fake mode may use a custom deterministic harness with `--harness PATH`. An attended captain may explicitly use `--live-socket /absolute/path/to/an/already-running/socket`; this mode only connects to that existing socket for the exact selftest and never starts, stops, or configures a daemon. Hermetic tests never use live mode. Fake-mode sockets are always created beneath `mktemp`, and every temporary artifact is cleaned on exit.

Progress is emitted as `stage=...` lines on stderr. The final result is one JSON object on stdout, with `socket_harness` set to either `fake-unix-socket` or `live-existing-socket`. A successful result proves the copied app executed, the signature verified with the hardened-runtime flag, the `com.apple.security.app-sandbox` entitlement is absent, and the exact `wilted-swift` echo returned through the selected socket.

This is only the recommended non-App-Sandbox personal MVP shape. Developer ID identity, notarization, and qualification of an actually installed app remain attended human gates; even live mode does not use Apple credentials, launchd, or daemon lifecycle controls.
