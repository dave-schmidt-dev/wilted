# Task 5: CloudKit capability preflight

**Status:** owner-approved decisions and source configuration; read-only and credential-free
**Date:** 2026-08-17
**Scope:** Wilted macOS producer and iOS 17+ listener

This packet records David’s approval of the Wilted decisions, installed source
configuration, attended portal evidence, and future evidence plan. It does not
contain secrets, team identifiers, certificate names, or provisioning data.
On 2026-08-17, attended screenshots verified the configured container and App ID
capabilities described below. No profile, signing, schema, device, Production,
App Store Connect, or TestFlight evidence was established.

Local source verification is complete. The final disposition and exact evidence
boundary are recorded in `docs/task5-verification-disposition.md`.

**Hard stop:** portal configuration now has screenshot evidence, but further
external execution remains attended. Do not create/pick a profile, upload or
alter a schema, promote Development to Production, or change other Apple state
until the corresponding gate is explicitly executed and evidenced.

## Current inventory and gaps

- `project.yml` is the source of truth and now contains the approved target
  identifiers `com.zerodelta.wilted.mac` and `com.zerodelta.wilted.ios`.
- Attended screenshots verify container `iCloud.com.zerodelta.wilted` and App IDs
  `com.zerodelta.wilted.mac` and `com.zerodelta.wilted.ios`. Both App IDs show
  iCloud/CloudKit enabled with exactly that container and Push Notifications enabled.
- Four source entitlement files now exist, and the Development/Release
  configurations bind the approved Development/Production entitlement choices
  for the Mac and iOS targets. Source does not pin an Apple team or profile.
  There is no provisioning-profile or signed effective-entitlement proof, and
  Debug remains credential-free. Portal screenshots do not substitute for
  artifact-bound evidence.
- `contracts/cloudkit/schema.json` freezes a private database, custom zone
  `WiltedZone`, record families `WiltedItem`, `WiltedRevision`, and
  `WiltedPlaybackState`, and no query indexes (`queryIndexAllowlist: []`). It
  is a contract, not a deployed schema or service-limit assertion.
- The planned adapter is `CKSyncEngine`; its opaque state and CloudKit system
  fields remain local sidecars. Automatic SwiftData CloudKit mirroring is
  excluded.
- Remote notifications and background audio are planned product capabilities,
  but their signed entitlements, profile support, and physical-device behavior
  have not been proven.
- No Development or Production CloudKit request, schema comparison, index
  promotion, signed artifact, provisioning profile, device run, or TestFlight
  receipt exists.

## Owner-approved source configuration

The following choices were approved by David on 2026-08-17. Attended screenshots
also prove the listed identifier/container/capability configuration exists in the
Apple Developer portal; they do not prove signed artifacts or runtime behavior:

| Decision | Approved value | Authorization boundary |
|---|---|---|
| Mac bundle ID | `com.zerodelta.wilted.mac` | Screenshot-verified App ID; iCloud/CloudKit and Push enabled |
| iOS bundle ID | `com.zerodelta.wilted.ios` | Screenshot-verified App ID; iCloud/CloudKit and Push enabled |
| Shared iCloud container | `iCloud.com.zerodelta.wilted` | Screenshot-verified and attached to both App IDs |
| CloudKit database/zone | Private database; custom zone `WiltedZone` | Contract authority only; deployment remains future |
| Mac distribution | Hardened, notarized Developer ID, initially without App Sandbox | Approved hypothesis; signed runtime and notarization remain future |
| Capability membership | Paid Apple Developer Program account with required capabilities | Approved prerequisite; iCloud/CloudKit and Push configuration screenshot-verified |

The approved values are installed in source and match the screenshot-verified
portal configuration. This record does not authorize further portal mutation.

## Owner-approved entitlement matrix

The effective signed entitlements, not source settings alone, are the evidence
of record. The exact container identifier below is approved for source
configuration; effective signed entitlements remain future evidence.

### Target-by-environment key matrix

The source project has three distinct build configurations: local `Debug`
has an explicitly empty `CODE_SIGN_ENTITLEMENTS` setting for credential-free
validation; `Development` binds the Development entitlement files below; and
`Release` binds the Production entitlement files. Local Debug evidence must
not be treated as Development CloudKit evidence.

The approved target-specific effective-key matrix is:

| Target | Development | Production |
|---|---|---|
| Mac | `icloud-container-identifiers`, `icloud-services: [CloudKit]`; `com.apple.developer.aps-environment: development` only if notifications are approved | `icloud-container-identifiers`, `icloud-services: [CloudKit]`, `icloud-container-environment: Production`; `com.apple.developer.aps-environment: production` only if notifications are approved |
| iOS | `icloud-container-identifiers`, `icloud-services: [CloudKit]`; `aps-environment: development` only if notifications are approved; `UIBackgroundModes: [audio]` in the built app Info.plist | `icloud-container-identifiers`, `icloud-services: [CloudKit]`, `icloud-container-environment: Production`; `aps-environment: production` only if notifications are approved; `UIBackgroundModes: [audio]` in the built app Info.plist |

For both targets, the approved shared CloudKit keys are:

```text
com.apple.developer.icloud-container-identifiers = [iCloud.com.zerodelta.wilted]
com.apple.developer.icloud-services = [CloudKit]
```

For Development, omit
`com.apple.developer.icloud-container-environment` unless the owner and Apple
tooling require an explicit Development value. If remote notifications are
enabled for a Development build, the effective Mac entitlement is:

```text
com.apple.developer.aps-environment = development
```

The corresponding iOS entitlement key is `aps-environment = development`.
The iOS built app Info.plist must separately contain `UIBackgroundModes =
[audio]`; physical-device behavior, not the profile alone, proves background
audio. The Mac target must separately prove its audio/speech boundary.

Production artifacts for both targets should carry the same approved container
and CloudKit service keys, plus the explicit Production environment key:

```text
com.apple.developer.icloud-container-identifiers = [iCloud.com.zerodelta.wilted]
com.apple.developer.icloud-services = [CloudKit]
com.apple.developer.icloud-container-environment = Production
```

If remote notifications are part of the approved release path, the effective
Mac Production entitlement is:

```text
com.apple.developer.aps-environment = production
```

The corresponding iOS entitlement key is `aps-environment = production`.

Do not infer that a Development entitlement, simulator run, unsigned Release,
or ad-hoc Mac build can access Production. Preserve separate, hash-bound
Development and Production artifacts and receipts.

Normative Apple references: [iCloud container environment entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment), [iCloud Services entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services), and [supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios). Gradus and WWPIS provide local precedent for separating CloudKit service/container keys and Development versus Production environment values; their identifiers are not Wilted values.

## Schema and index promotion evidence plan

1. Freeze the approved identifiers and a content hash of `contracts/cloudkit/schema.json`.
2. In a future attended gate, create/configure only the approved Development
   container. Record the redacted container/environment identity and exact
   tool/Xcode version, never credentials.
3. Use Apple’s [text-based CloudKit schema workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow)
   to import or compare the contract-derived schema. Retain the command
   transcript with private inputs removed, the input hash, and the resulting
   Development export hash.
4. Independently compare record types, field types/optionality, references,
   custom-zone ownership, and indexes. The current expected index set is empty;
   any proposed query index is a new owner decision and must cite the adapter
   query that requires it.
5. Exercise the Development schema with Mac create/update/delete and iOS
   playback-state operations, including stale change-tag, offline, delayed,
   quota, and malformed-schema cases. Preserve redacted operation receipts and
   artifact hashes.
6. Require a future attended owner approval that Development matches the frozen
   contract before promotion. Promotion evidence must include the exact
   Development export, Production export after promotion, schema/index diff
   showing no unintended change, promotion timestamp, and the approving owner.
7. Validate the signed Production-entitled Mac producer and iOS listener
   against Production on physical roles. A local validator, fixture, simulator,
   or Development success cannot substitute for this proof.

## Signing, profile, and artifact boundaries

- A provisioning profile is evidence only when its App ID, capabilities,
  container association, environment, expiration, and device/distribution
  purpose are inspected and recorded without exposing profile contents that
  contain sensitive data.
- For Mac, prove the exact Developer ID-signed app, hardened runtime,
  notarization/staple result, and effective entitlements. The current
  non-sandbox Developer ID path is only a hypothesis: the signed runtime must
  prove speech IPC, audio, file access, and CloudKit behavior. If sandboxing is
  selected, stop and design the required socket relocation and App Group/XPC
  boundary first.
- For iOS, prove the exact signed archive/IPA, frozen version/build, embedded
  profile association, effective Development or Production entitlements, and
  physical-device behavior for background audio, lock-screen controls, remote
  delivery, download, and offline playback.
- A source plist, Xcode setting, generated project, unsigned Release, ad-hoc
  artifact, simulator result, or local test pass is not signed-artifact proof.
- App Store Connect processing and user-visible Internal TestFlight assignment
  are separate receipts. Neither proves CloudKit schema promotion; Production
  CloudKit and device acceptance remain separate gates.

## Approved checklist and remaining gates

- [x] David approves the two bundle IDs and one shared container.
- [x] David confirms the paid-team capability boundary; no team ID is recorded here.
- [x] David approves private database/custom-zone ownership and the schema contract hash plan.
- [x] David approves Development versus Production entitlement keys for both targets.
- [x] David approves CloudKit, Background Modes/audio, and remote-notification scope.
- [x] David approves the non-sandbox Developer ID hypothesis.
- [x] David approves certificate/profile classes and artifact inspection without names or secrets.
- [x] David approves the schema/index comparison, promotion, stop, and receipt plan.
- [x] David approves physical Mac/iPhone roles and separate Development/Production acceptance.
- [x] David verifies the container, both App IDs, iCloud/CloudKit attachment, and Push capability by attended screenshots.
- [x] David confirms any further portal/container mutation remains a future attended gate.

## Final decision table

| Area | Approved source decision / required future evidence | Owner approval | Evidence reference |
|---|---|---|---|
| Bundle IDs | `com.zerodelta.wilted.mac`; `com.zerodelta.wilted.ios` | Approved 2026-08-17 | Screenshot-verified App IDs; iCloud/CloudKit and Push enabled |
| Shared container | `iCloud.com.zerodelta.wilted` | Approved 2026-08-17 | Screenshot-verified attachment to both App IDs |
| CloudKit scope | Private database; `WiltedZone`; current index set empty | Approved 2026-08-17 | Development schema comparison and promotion future |
| Development entitlements | CloudKit service + container identifiers; Development notification value if used | Approved 2026-08-17 | Signed Development artifacts future |
| Production entitlements | CloudKit service + container identifiers + `icloud-container-environment: Production`; Production notification value if used | Approved 2026-08-17 | Signed Production artifacts future |
| iOS capabilities | CloudKit, Background Modes/audio, remote notifications as approved | Approved 2026-08-17 | CloudKit/Push portal configuration verified; profile, background-audio artifact, and device proof future |
| Mac distribution | Hardened/notarized Developer ID without App Sandbox | Approved 2026-08-17 | Signed runtime and notarization proof future |
| Schema promotion | Hash-bound text-schema import/export, diff, index evidence, attended promotion approval | Approved 2026-08-17 | No schema mutation or promotion performed |
| Signing/profiles | Correct target, capability, environment, and artifact-bound inspection receipts | Approved 2026-08-17 | No profiles or signing evidence recorded |
| Device/release proof | Signed physical Mac/iPhone Production acceptance; App Store Connect/TestFlight receipts separately | Approved 2026-08-17 | No device, App Store Connect, or TestFlight proof |

### References

- Repository: `project.yml`, `contracts/cloudkit/schema.json`,
  `docs/phase0-apple-capability-inventory.md`, and `docs/phase0-decision-record.md`.
- Local release policy: the central Apple release standard maintained outside this repository.
- Local entitlement patterns: Gradus Mac Development/Production and iOS
  entitlements; WWPIS iOS CloudKit entitlement. These are precedent only.
- Apple: [iCloud container environment](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment), [iCloud services](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services), [text-based schema workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow), and [supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios).
