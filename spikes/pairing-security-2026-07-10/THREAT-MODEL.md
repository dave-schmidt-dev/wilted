# Personal-device pairing/transport threat model — 2026-07-10 (Task 0.5)

**This document is the MAC-SIDE deliverable of Task 0.5.** It informs, but
does not replace, `spikes/pairing-security-2026-07-10/pairing_spike.py`
(the disposable code spike proving the properties below) and the design
doc's "Phone handoff: local-only first" section
(`/Users/dave/Documents/Projects/.plans/wilted/mac-first-personal-radio-2026-07-10.md`
lines 141-153) and open decision #1 (lines 266-269).

Physical-iPhone local-network permission behavior (TN3179 foreground
prompt, denial/retry UX) is explicitly **out of scope** here — it defers to
David's own device and is called out again at the end of this document.

## Scope

- **In scope:** a single user's Mac (the authoritative station, per the
  design doc's `StationCore`/reducer boundary in
  `src/wilted/station/`) and that same user's own iPhone, both on one home
  LAN. One user, one trust domain, no multi-tenant or public-internet
  exposure in MVP (remote transport is an explicit later decision gate the
  design doc defers to a private tailnet/VPN, never a public listener).
- **Out of scope:** CarPlay, remote/public hosting, multi-user support,
  anything already excluded from MVP by the design doc's "Product
  decisions" section, and the physical-iPhone local-network permission
  test (David's device, not this environment).

## Assets

| Asset | Where it lives (intended) | Why it matters |
|---|---|---|
| **Station manifest** | In-memory `StationCore.get_manifest()` (`spikes/mac-substrate-2026-07-10/candidate_a/core.py:115-149`), served over the pairing transport | Reveals what David is listening to, station revision, active entry, lease/ownership state — a privacy leak and a write-oracle if paired with unauthenticated mutation commands |
| **Media assets** (prepared audio) | Local filesystem, synced to phone as immutable downloads | Personal content; also an integrity target — a tampered asset played as if authentic is a content-integrity failure |
| **Pairing secret / token** | Ephemeral, single use, never persisted outside Keychain-equivalent storage | The literal key to enrollment — its compromise lets an attacker enroll as a second "iPhone" |
| **TLS identity** (private key + self-signed cert) | Should live in Keychain (or Keychain-equivalent secure storage), never on disk in the repo/config | Its compromise lets an attacker impersonate the Mac station to a real phone, or decrypt/MITM a session |
| **Enrolled-client credential** (post-enrollment per-client secret) | Keychain-equivalent storage on both ends | Used for every subsequent authenticated request; its compromise is equivalent to full station control for that client |

## Adversaries

1. **Another device on the same LAN** (a smart-TV, a guest's laptop, an IoT
   device, a compromised neighbor device on a shared home network) —
   assumed to be able to send arbitrary TCP/UDP traffic to the Mac's LAN
   IP and to observe Bonjour/mDNS advertisements, but does **not** have
   the pairing token (that only ever appears via the QR code shown on the
   Mac's own screen at enrollment time) and does **not** have filesystem
   or Keychain access to either the Mac or the real iPhone.
2. **A replay/MITM attempt** — an adversary who can capture and resend
   traffic (e.g. via ARP spoofing on the LAN) but who does not possess the
   TLS private key and cannot forge a valid signature over a fresh nonce.
3. **An unpaired client** — a device that knows the service exists (Bonjour
   advertisement is not itself secret — the design doc calls for it to be
   "minimally identifying") and can open a TCP/TLS connection, but has
   never completed enrollment and holds no per-client credential.

**Explicitly not modeled:** a fully compromised Mac or iPhone (if the
station's own device is owned, Keychain access controls are the last line
of defense and are Apple's problem, not this protocol's); a nation-state
adversary with physical LAN tap and cert-authority compromise; supply-chain
attacks on `openssl`/`cryptography` themselves. This is a personal-radio
station for one user, not a security product — the goal is "meaningfully
harder to abuse than a plaintext, unauthenticated LAN HTTP server," which
is the design doc's explicit bar ("Until the spike proves that design, do
not expose a plaintext or unauthenticated LAN HTTP server").

## Threats, mitigations, and controls

| # | Threat | Mitigation | Concrete control (proven in spike unless noted) |
|---|---|---|---|
| T1 | **Unauthenticated manifest/asset fetch** — adversary on LAN connects and reads the manifest or downloads media without ever pairing | Every read requires a valid per-client credential issued at enrollment, checked on every request, not just at TLS handshake | `pairing_spike.py`: `AUTHENTICATED TRANSPORT` property — a request with no/garbage `Authorization` value gets `403` and an empty body, asserted byte-for-byte |
| T2 | **Pairing-token replay / double enrollment** — adversary captures or guesses the one-time pairing token and enrolls a second "device" (or the legitimate phone's own retry logic accidentally re-enrolls) | Token is single-use: server marks it consumed atomically on first successful enrollment; any later attempt (correct or incorrect token) is rejected | `pairing_spike.py`: `ONE-TIME ENROLLMENT` property — second `/enroll` with the same token returns rejection, first client's credential still the only valid one |
| T3 | **Stale-revision writes** — a stale/reconnecting client (e.g. iPhone that missed a Mac-side update) submits a checkpoint/mutation against an old `station_revision`, silently clobbering newer state (the design doc: "a stale Mac must not silently overwrite the phone's newer checkpoint") | Every mutating request carries `expected_revision`; server rejects if it does not match current revision — this is the same idempotent-write contract already enforced by the committed reducer (`Checkpoint.expected_revision`, `src/wilted/station/reducer.py`), extended to the transport layer | `pairing_spike.py`: `STALE-REVISION REJECTION` property — a request with `expected_revision` behind current state is rejected before it reaches any state mutation |
| T4 | **Asset-hash tampering** — adversary substitutes or corrupts a downloaded media asset in transit or at rest, and the phone plays it as authentic | Every asset fetch is checked against the manifest's `sha256`; a mismatch is rejected client-side before playback and is also rejected server-side if a client requests by a hash that doesn't match server state (defense in depth) | `pairing_spike.py`: `ASSET-HASH REJECTION` property — a request presenting a tampered/wrong expected hash is rejected, no asset bytes returned |
| T5 | **Secret exposure** — pairing token, TLS private key, or per-client credential ends up in the repo, `wilted.toml`, `data/`, logs, or stdout/stderr | Nothing sensitive is ever written outside an ephemeral temp directory; the spike asserts in-code that no secret substring appears in any tracked file, in captured stdout/stderr, or in the log stream, then shreds the temp dir in `finally` | `pairing_spike.py`: `SECRET HYGIENE` property — `assert_no_secret_leak()` grep-scans the repo working tree and captured output for every generated secret value |
| T6 | **Bonjour/mDNS fingerprinting** — the service advertisement itself leaks identifying information (device name, user's real name) to anyone on the LAN | Advertise a minimally identifying service name (random/opaque instance name, not "David's MacBook"), per the design doc's "minimally identifying discovery" language | Design-time recommendation only — Bonjour itself is simulated, not implemented, in this spike (YAGNI per constraints); real implementation is native (`NetService`/`NWListener`) work, not Python |
| T7 | **Lease/ownership confusion at the transport layer** (a second "authenticated" client trying to mutate while another holds the controller lease) | Already fully specified and tested at the reducer layer (`ControllerLease`, `claim_lease`, fencing-token epoch checks) — the transport layer's job is only to translate an authenticated request into a `(holder_id, epoch)` pair and pass it through unchanged, per `candidate_a/core.py`'s existing pattern | Out of scope for *this* spike (already covered by `spikes/mac-substrate-2026-07-10`); noted here only for completeness |

## Transport/dependency recommendation

**Recommended for the MVP pairing transport:** TLS 1.2+ (stdlib `ssl`,
`PROTOCOL_TLS_SERVER`/`PROTOCOL_TLS_CLIENT`) terminating on `localhost`/LAN,
with the server certificate and key generated **once per station identity**
via the macOS-bundled `openssl` CLI (never shipped as a Python dependency —
invoked as a one-shot subprocess at first-run, then the resulting key is
moved into Keychain and the plaintext file is deleted). Client
authentication is **application-layer**, not X.509 client certificates:
each enrolled client holds an HMAC key issued at enrollment, and every
request is authenticated by an HMAC signature over
`(method, path, expected_revision, timestamp, nonce)`. This is deliberately
*not* full mutual TLS (mTLS with client certs) for the MVP — see the
open-decision analysis below for why.

Server-certificate verification stays fully enforced on the client side
(`ssl.CERT_REQUIRED`, the `PROTOCOL_TLS_CLIENT` default, set explicitly
rather than left implicit): the client pins trust to exactly the one
self-signed certificate generated for that pairing session (via
`load_verify_locations`), so any peer presenting a different certificate
is rejected outright. Only `check_hostname` is disabled, because the
pinned cert has no real DNS name to match against a loopback/LAN IP — that
is a hostname-match convenience, not a weakening of trust verification,
and a real implementation would either pin the station's stable identity
the same way or provision a proper LAN-local hostname.

**Fallback if iOS local-network access is denied:** per TN3179, iOS can
deny the local-network permission prompt before the user ever responds
(background-first access), and the user can deny/revoke it at any time in
Settings. When local discovery/connect fails:

1. The iPhone client falls back to **explicit QR re-pairing** — David
   opens the Mac's pairing screen, which shows a fresh one-time QR code (a
   new pairing token, same enrollment flow), and scans it from the phone.
   This works even if Bonjour discovery itself is blocked, because the QR
   code can encode the Mac's LAN IP/port directly, bypassing mDNS.
2. If TLS/local networking is denied entirely (user declined the OS
   permission and won't be prompted again this session), the phone client
   degrades to **read-only cached playback** of whatever it last
   downloaded — it does not silently retry a denied permission in a loop
   (Apple's guidance treats repeated background retries as an anti-pattern
   and they will not succeed without the user re-granting in Settings).
   The app surfaces a clear "reconnect to your Mac" affordance instead.
3. Remote (non-LAN) fallback is **not** part of MVP — the design doc
   explicitly defers any non-LAN transport to a later decision gate
   ("reuse the exact authenticated manifest protocol through an opt-in
   private transport such as an existing tailnet or user-operated VPN; do
   not expose the Mac service directly to the public internet"). No code
   in this spike or the MVP should attempt to bridge the local-network
   denial by falling back to a public/relay transport.

## Open decision #1: native macOS companion vs. one approved Python dependency

The design doc (lines 266-269) frames this explicitly as undecided and asks
the spike to inform it, not resolve it. Below is the analysis; **the
decision is David's**.

### What a native macOS companion buys

- **Real Keychain API** (`Security.framework` / `SecKeychain*` or the
  modern `SecItem*` API) with no Python-to-Keychain bridge at all — this is
  the API Apple actually tests and documents, and it is the same API the
  iPhone side (Swift/SwiftUI, already committed per the design doc) already
  uses. Zero protocol/behavior mismatch between the two ends of the pairing
  handshake.
- **True mTLS with `Secure Enclave`-backed keys** is straightforward in
  Swift (`SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave`) — the
  private key material is provably non-exportable, not just
  "stored-and-hopefully-not-copied." Python has no equivalent to the
  Secure Enclave binding without dropping into the same native APIs anyway
  (at which point it's not really "a Python dependency" any more, it's a
  PyObjC bridge to the same framework).
- **No new Python runtime dependency** in the Mac process at all — the
  companion is a separate small Swift binary/XPC service that only the
  pairing/transport code talks to, so the security-critical surface is
  entirely outside the existing `mlx-audio`/`textual`/Peewee dependency
  tree. Smaller blast radius if a Python dependency is ever compromised
  upstream (supply-chain risk).
- **Cost:** a second toolchain (Xcode/Swift) and process boundary
  (IPC/XPC between the Python station and the Swift companion) that must
  be built, tested, and kept in sync — real engineering cost for a
  single-user personal project, not proportionate unless the native
  Swift/SwiftUI Mac client (mentioned as a *possible* future direction in
  the design doc's "architecture spike decides whether the Mac client
  shares a Swift package") is being built anyway.

### What one approved Python dependency would require

Two named candidates, matching the design doc's own phrasing:

- **`cryptography`** (self-signed cert/key generation, X.509 handling) —
  this project is the de facto standard, audited, and widely deployed, but
  it is **not** currently present anywhere in this project's dependency
  graph: a check of the 161-package `uv.lock` (`grep -iE '^name =
  "(cryptography|keyring|pyobjc)'`) returns zero matches. Adopting it adds
  a genuinely new top-level dependency, not a free ride on an existing
  transitive one. Generating an ephemeral self-signed cert with it is ~20
  lines and removes the `openssl` CLI subprocess dependency this spike
  uses instead. It does **not** touch Keychain — it only replaces the
  `openssl` shell-out for cert generation.
- **`keyring`** (cross-platform credential storage, with a macOS Keychain
  backend via PyObjC under the hood) — this is the piece that would let
  Python code store the per-client HMAC key / TLS private key in the real
  Keychain instead of `wilted.toml`/`data/`. Like `cryptography`, it is
  **absent** from `uv.lock` today, so adopting it is also a genuinely new
  top-level dependency. It pulls in `pyobjc-framework-Security`
  transitively on macOS (also absent from `uv.lock` today), which is
  itself a maintained, official Apple-bridge project, not a third-party
  reimplementation, but is nonetheless new transitive surface, not
  existing surface.
- **Cost:** both would join the existing Python/`uv` dependency graph as
  new entries — no new toolchain, no IPC boundary, the pairing/transport
  code lives beside the rest of `wilted.station` and can be tested with
  the same `pytest`/`make validate` pipeline already in place, but the
  marginal supply-chain footprint is real (two new top-level packages plus
  `keyring`'s macOS Keychain backend transitives) and should be weighed
  as such, not discounted as already-present. The tradeoff is a weaker security
  boundary than Secure Enclave-backed native keys: `keyring`'s Keychain
  items are protected by the OS ACL (only the signing identity that wrote
  them, or an explicitly authorized app, can read them back) but the key
  material itself is extractable by anything running as that same
  process/user with Keychain access — there is no non-exportable
  hardware-backed key the way there is with Secure Enclave. For a
  single-user home-LAN personal radio, that is very likely an acceptable
  risk; it would not be for a product handling untrusted multi-tenant data.

### Recommendation

**Ship the Python-dependency path (`cryptography` for cert generation,
`keyring` for Keychain storage) for the MVP; do not build a native macOS
companion for Task A.1.** Rationale:

- This is a single-user personal project, not a product being sold to
  people who might target it. The realistic adversary (T1-T3 above) is
  defeated by "not a plaintext HTTP server," which stdlib `ssl` +
  `keyring`-backed secrets already achieves.
- The design doc's own architecture-decision framework (Plan 0, lines
  40-51) is already deciding whether the Mac surface stays Python/Textual
  or becomes native Swift for reasons unrelated to security (UX velocity,
  audio route recovery, awake/sleep availability). If that separate
  decision lands on native Swift, revisit this recommendation for free —
  a native Mac client would already have Keychain/mTLS for the taking. Do
  not build a companion **just** for pairing security ahead of that
  decision; that inverts the dependency (security spike should not force
  the substrate choice the design doc reserves for Plan 0).
- `cryptography` and `keyring` are both mature, widely audited, and this
  project already accepts a comparably-sized trust footprint elsewhere
  (`mlx-audio`, `playwright`, `trafilatura`). Adding two more well-known
  packages is a smaller marginal risk than standing up and maintaining a
  second toolchain and IPC boundary for one user.
- If David's risk tolerance is different than assumed here — e.g. he
  independently decides to build the native Swift Mac client for the UX
  reasons Plan 0 will weigh — the Keychain/mTLS work is then free and this
  recommendation should be revisited at that time, not before.

This spike itself uses **neither** dependency by default (see README) —
it shells out to the macOS-bundled `openssl` CLI for cert generation and
implements HMAC-based application-layer authentication with pure stdlib,
specifically so the disposable spike adds zero footprint to `pyproject.toml`.
Where the spike's approach diverges from the recommendation above (no
`keyring`, no real Keychain write), it is called out inline in the spike's
own docstrings and in the README's "proven vs. deferred" table.

## Hardening backlog — MUST fix before the shipped implementation (2026-07-10 security review)

A security review of this spike on 2026-07-10 identified gaps that are
acceptable in a disposable spike proving protocol *shape* but MUST NOT be
carried into the real Phase B implementation unaddressed:

- **(A) Nonce store must stay bounded and persist across restarts.** The
  2026-07-10 review found `_authenticate` recording/burning the nonce
  *before* verifying the HMAC signature, which let an on-path attacker who
  had merely observed an enrolled `holder_id` (not the credential itself —
  `holder_id` is not secret) send requests with fabricated nonces and
  garbage signatures to burn `(holder_id, nonce)` pairs, causing a
  nonce-namespace denial-of-service against the legitimate client. That
  ordering bug has since been fixed in this spike (`_authenticate` now
  verifies the signature first via `nonce_seen`/`record_nonce`, and only
  records the nonce after a valid signature) — but two related issues
  remain and are still backlog for the real implementation: the nonce
  store (`PairingStore._seen_nonces`) is an unbounded in-memory `set`
  that grows without bound over a long-running process, and it is never
  persisted, so a server restart silently reopens the anti-replay window
  for every nonce ever seen. The real implementation must bound the nonce
  store (e.g. an LRU/expiring window keyed to the same freshness window as
  the timestamp check) and persist it across restarts.
- **(B) Non-finite timestamps must stay rejected.** The 2026-07-10 review
  found the freshness check (`abs(time.time() - float(timestamp)) > 30`)
  did not reject non-finite floats — `float("nan")` compares `False`
  against any bound (`abs(now - nan) > 30` is `False`), so a `nan`
  timestamp passed the freshness window. This has since been fixed in
  this spike (`_authenticate` now calls `math.isfinite(ts)` and rejects
  non-finite timestamps before the freshness comparison) — carry the same
  check into the real implementation; do not regress it.
- **(C) Secret-hygiene self-check is a suffix allowlist, not a denylist,
  and never scans the TLS private key.** `assert_no_secret_leak`'s
  `text_suffixes` allowlist (`.py`, `.md`, `.toml`, `.json`, `.txt`,
  `.cfg`, `.ini`, `.yaml`, `.yml`, `.log`) misses common
  secret-bearing/leak-prone file types entirely — `.key`, `.pem`, `.crt`,
  `.env`, `.sh`, `.conf`, `.plist`, and extensionless files (e.g.
  `Dockerfile`, shell scripts without an extension) are silently never
  scanned. The real implementation must invert this to a denylist that
  skips only known-binary/build directories (already partially done via
  the `.venv`/`.git`/`build`/`__pycache__`/`.pytest_cache`/`.ruff_cache`
  parts-check) and scans everything else, including `.git` itself (a
  secret committed and later "removed" can still live in history/objects,
  which the current scan skips outright). It must also scan the TLS
  private key bytes generated by `generate_ephemeral_tls_identity` — the
  private key is one of the five assets enumerated in this document's
  "Assets" table and is currently never included in
  `all_secret_values()`/the hygiene scan at all. Finally, temp-directory
  cleanup must assert successful deletion rather than
  `shutil.rmtree(temp_dir, ignore_errors=True)`, which silently swallows
  a failed delete and can leave a real private key on disk with no
  signal that it happened.
- **(D) Asset-hash-rejection test is too weak.** The `ASSET-HASH
  REJECTION` property currently asserts `body_tampered != asset.content`
  for the tampered-hash case, which would still pass if the server leaked
  *some other* non-matching bytes (partial content, an error page with
  embedded fragments, etc.). The real implementation's test must assert
  that **zero** asset bytes are returned on a hash mismatch (`body_tampered
  == b""`), not merely that the body differs from the real asset content.
- **(E) No concurrency test for one-time enrollment.** The `ONE-TIME
  ENROLLMENT` property is only ever exercised sequentially (first enroll,
  then second enroll, one after another). `PairingStore.enroll` does hold
  a lock across the check-and-set, so it is very likely correct, but this
  has never been proven under concurrent load. The real implementation
  must add a test that fires multiple concurrent enrollment attempts with
  the same token (e.g. a thread pool hammering `/enroll` simultaneously)
  and asserts exactly one succeeds.

## Deferred to David's physical device (explicitly out of scope here)

- The actual iOS local-network permission prompt (TN3179): does it fire
  correctly for `_wilted._tcp`, does foreground-first pairing avoid the
  silent background-denial case, does the app's `NSBonjourServices` /
  `NSLocalNetworkUsageDescription` copy read clearly.
- Real Bonjour/mDNS advertisement and discovery between two physical
  devices on David's actual home LAN (this spike simulates discovery
  in-process; see README).
- Real Secure Enclave / Keychain behavior on a physical iPhone, and
  Keychain-sync/reset edge cases (e.g. what happens to the enrolled
  credential after an iOS backup restore).

These require David's own hardware and are called out as a manual gate in
the design doc's "Test strategy" section ("manual foreground local-network
permission test on iPhone").
