# Pairing/transport-security spike — 2026-07-10 (Task 0.5, MAC-SIDE)

**This is a disposable architecture spike. It is not production code.**

## Purpose

MAC-SIDE half of Task 0.5 in the mac-first personal-radio plan
(`/Users/dave/Documents/Projects/.plans/wilted/mac-first-personal-radio-2026-07-10.md`
lines 141-153, "Phone handoff: local-only first", and open decision #1,
lines 266-269). Proves — with a real localhost TLS server and a real
authenticated client, using only ephemeral temp-dir material — the
transport-security properties the design doc requires before any
plaintext or unauthenticated LAN server may be built:

- one-time pairing enrollment (no double-enroll / token replay),
- authenticated manifest/asset transport (unpaired clients get nothing),
- stale-revision rejection,
- asset-hash-tamper rejection,
- and that none of the above ever produces a secret that touches the repo,
  a log, or stdout/stderr.

See `THREAT-MODEL.md` in this directory for the full threat model,
adversary list, per-threat control mapping, the exact transport/dependency
recommendation and local-network-denied fallback, and the open-decision-#1
analysis (native macOS companion vs. one approved Python
Keychain/TLS dependency).

## How to run

From the project root, with the project's own `.venv` (stdlib only, no
extra dependency needed):

```bash
python spikes/pairing-security-2026-07-10/pairing_spike.py
```

Requires the `openssl` CLI on `PATH` (present by default on macOS; used
only to generate the run's ephemeral self-signed TLS cert/key into a
`tempfile.mkdtemp()` directory — never a Python dependency, never written
under the repo). Exits `0` and prints one `[PASS]`/`[FAIL]` line per
security property, plus a final summary line. Exits non-zero if any
property fails.

To lint just this spike (intentionally outside `make validate`'s scope,
same convention as the sibling `mac-substrate-2026-07-10` spike):

```bash
ruff check spikes/pairing-security-2026-07-10
```

## Security properties proven here

| Property | How it's proven |
|---|---|
| **One-time enrollment** | A pairing token is generated once per run. A real client enrolls successfully; a second client immediately attempts to enroll with the *same* token and is rejected (`403 enrollment_rejected`). |
| **Authenticated transport** | A client with no enrollment credential (or a garbage one) requests the manifest and gets `403` with a zero-length body — no manifest, no asset, nothing. An enrolled client's HMAC-signed request succeeds and gets the manifest. |
| **Stale-revision rejection** | An enrolled client requests the manifest with `expected_revision` one behind the server's actual revision and gets `409 stale_revision`; the same client's up-to-date request succeeds. |
| **Asset-hash rejection** | An enrolled client requests the fixture asset with a tampered/wrong `expected_sha256` and gets `409 asset_hash_mismatch` with no asset bytes; the same client's correctly-hashed request gets the exact asset bytes back. |
| **Secret hygiene** | Every secret value this run generates (the pairing token, the per-client HMAC credential) is grep-scanned against this script's own captured stdout/stderr and against every text file under the repo working tree (`REPO_ROOT.rglob("*")`, skipping `.venv`/`.git`/build caches) — the scan must find zero matches outside the ephemeral temp dir. The temp dir is `shutil.rmtree`'d in a `finally` block regardless of pass/fail. |

Re-verify secret hygiene independently of the script's own self-check
after any run:

```bash
git status                                                    # only source files should appear as new/modified
grep -RInE '[A-Za-z0-9_-]{32,}' spikes/pairing-security-2026-07-10/*.py *.md 2>/dev/null | grep -v '^Binary'
```

The second command should show no base64/hex/PEM secret literals — only
identifiers, comments, and code (the grep is intentionally broad; expect
it to surface things like long descriptive names, not actual secrets).

## Security properties explicitly deferred

- **Physical-iPhone local-network permission test** (TN3179 foreground
  prompt behavior, denial/retry UX, `NSBonjourServices` copy) — out of
  scope for this environment per the task brief; defers to David's own
  device. Tracked as a manual gate in the design doc's "Test strategy"
  section.
- **Real Bonjour/mDNS discovery** between two physical devices — this
  spike hardcodes `127.0.0.1` and never stands up mDNS (YAGNI per the task
  constraints: "no real Bonjour/mDNS stack needed... you may simulate
  discovery").
- **Real Keychain storage** — this spike does not call `security
  add-generic-password` against any keychain, isolated or otherwise, and
  does not use `keyring`. The per-client HMAC credential lives only in an
  in-process Python dict (`PairingStore._enrolled_clients`) for the
  duration of the run. `THREAT-MODEL.md`'s open-decision-#1 section
  documents the `keyring`-backed approach a real implementation would use
  instead of executing it, per the task's Keychain constraint.
- **Full mutual TLS** (X.509 client certificates) — this spike uses
  server-side TLS plus application-layer HMAC client authentication, not
  per-client certificate issuance. See `THREAT-MODEL.md`'s transport
  recommendation for the reasoning.
- **Controller-lease/ownership-epoch enforcement at the transport layer**
  — already fully covered by the committed reducer and the
  `mac-substrate-2026-07-10` spike; this spike's fixture manifest doesn't
  wire in `wilted.station` at all (no reducer import), since proving
  lease semantics again here would be redundant, not additive.

## Rules for anything built on top of this scaffold

- **Nothing under `src/wilted/` may import anything from `spikes/`.** This
  directory is removable at any time without touching production code or
  data (`grep -rn 'spikes' src/wilted` must stay empty).
- No plaintext secret, private key, TLS cert/key, or content token may
  ever be written under the repository working tree. Everything sensitive
  is generated into a `tempfile.mkdtemp()` directory and shredded in a
  `finally` block before the process exits, every run, no exceptions.
- No dependency beyond the Python stdlib and the macOS-bundled `openssl`
  CLI. If a follow-on spike needs `cryptography`/`keyring`, invoke it via
  `uv run --with <pkg> python ...` — do not add it to `pyproject.toml`.
- No import of `wilted.station` or any other `src/wilted/` module — this
  spike proves transport/authentication properties against a fixture
  manifest shaped like `StationCore.get_manifest()`
  (`spikes/mac-substrate-2026-07-10/candidate_a/core.py:115-149`), not the
  real reducer-backed one.
