# LAN transport spike (M0, loopback), 2026-11-02

Device: MacBook Pro (M5 Max), macOS 27.2, Swift `swiftc -O`, Network.framework over 127.0.0.1 (`requiredInterfaceType = .loopback`).
Verdict: TLS 1.2 ECDHE-PSK ChaCha20 (0xCCAC) with one multi-key `NWListener`. TLS 1.3 external PSK is not usable.

The spike was throwaway code in the session scratch folder (deleted after the run). It built a listener and client with Scarecrow's options (`ScarecrowNearbyProtocol.swift:199`): min and max version pinned, the one cipher appended, resumption, tickets, false start and renegotiation off, `sec_protocol_options_add_pre_shared_key` per key, and a client `pre_shared_key_selection_block` returning its own identity. Command: `swiftc -O spike.swift -o spike && ./spike`.

## Answers

| Question | Result |
|---|---|
| Q1: one listener, several PSKs, selected by client identity | Yes. Listener holding keys A and B: client A and client B each negotiated `v=0x0303 c=0xccac`. |
| Wrong key under a known identity | Refused: client connection went to `.waiting` with `-9820 bad MAC`. |
| Q2: TLS 1.2 profile handshake on this OS | Yes, `v=0x0303 c=0xccac` every time. |
| Q2b: TLS 1.3 external PSK | No. Both single- and multi-key listeners: client `.waiting` with `-9858 handshake failed`. |
| Q3: loopback throughput, 1 MB sends | 250 MB in about 0.6 s, 416 MB/s. The 1 MB cold first run read 29.5 MB/s (setup cost). |

## Design consequences

1. One listener serves every allowed phone. `NWParameters` are fixed when the listener starts, so a change in the allowed key set restarts the listener (cheap; done only when the directory's key set changes or a phone is stopped).
2. Handshake failures surface on the client as `.waiting`, not `.failed`. The client must treat `.waiting` during the handshake as a failure and cancel at once, never wait for a retry.
3. Validate the negotiated version and cipher on every connection, both sides (`0x0303`, `0xCCAC`), and fail closed otherwise.
4. Loopback throughput is far above the 10 MB/s target, so the codec and TLS layer are not the bottleneck; Wi-Fi speed is an M5 measurement.

## Deferred to M5 (needs the real iPhone on Wi-Fi)

1. How a Local Network denial shows in `NWBrowser` state.
2. Whether `BGContinuedProcessingTask` may use the local network, how long it runs, and whether the socket survives the lock. Coded fallback if not: `beginBackgroundTask` plus offset resume.
3. iPhone-to-Mac handshake on iOS 27 and Wi-Fi MB/s.
