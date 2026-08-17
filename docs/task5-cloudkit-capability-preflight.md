# Task 5: CloudKit capability preflight

**Status:** attended decision packet; read-only and credential-free
**Date:** 2026-08-17
**Scope:** Wilted macOS producer and iOS 17+ listener

This packet records decisions the release owner must make before any Apple
Developer portal, CloudKit container, capability, profile, or signing state is
created or changed. It does not contain secrets, team identifiers, certificate
names, or portal receipts.

**Hard stop:** do not register an App ID, create or attach a container, enable a
capability, create/pick a profile, upload a schema, promote Development to
Production, or alter any external Apple state until the owner approves the
decision table at the end.

## Current inventory and gaps

- `project.yml` is the source of truth. It currently uses the local placeholder
  prefix `com.example.wilted`, with target placeholders
  `com.example.wilted.mac` and `com.example.wilted.ios`.
- Both application targets have no entitlements file, no CloudKit container,
  no Development/Production environment selection, and no Apple team/profile
  binding. Current Mac ad-hoc signing is local validation only.
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

## Owner decisions requested

These are proposals only and are **not approved identifiers**:

| Decision | Proposed value | Owner decision required |
|---|---|---|
| Mac bundle ID | `com.zerodelta.wilted.mac` | Confirm ownership and final spelling |
| iOS bundle ID | `com.zerodelta.wilted.ios` | Confirm ownership and final spelling |
| Shared iCloud container | `iCloud.com.zerodelta.wilted` | Confirm one shared private container for both targets |
| CloudKit database/zone | Private database; custom zone `WiltedZone` | Confirm contract ownership and zone policy |
| Mac distribution | Hardened, notarized Developer ID, initially without App Sandbox | Approve hypothesis or select App Sandbox/App Group/XPC alternative |
| Capability membership | Paid Apple Developer Program account with required capabilities | Confirm account authority and capability availability |

The proposed values must not be typed into the portal until approved. The
placeholder values remain intentionally non-release values.

## Entitlement matrix to approve

The effective signed entitlements, not source settings alone, are the evidence
of record. The exact container identifier below is still conditional on the
owner decision above.

### Target-by-environment key matrix

The proposed target-specific effective-key matrix is:

| Target | Development | Production |
|---|---|---|
| Mac | `icloud-container-identifiers`, `icloud-services: [CloudKit]`; `com.apple.developer.aps-environment: development` only if notifications are approved | `icloud-container-identifiers`, `icloud-services: [CloudKit]`, `icloud-container-environment: Production`; `com.apple.developer.aps-environment: production` only if notifications are approved |
| iOS | `icloud-container-identifiers`, `icloud-services: [CloudKit]`; `aps-environment: development` only if notifications are approved; `UIBackgroundModes: [audio]` in the built app Info.plist | `icloud-container-identifiers`, `icloud-services: [CloudKit]`, `icloud-container-environment: Production`; `aps-environment: production` only if notifications are approved; `UIBackgroundModes: [audio]` in the built app Info.plist |

For both targets, the proposed shared CloudKit keys are:

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
2. Create/configure only the approved Development container after the owner
   authorizes the portal step. Record the redacted container/environment
   identity and exact tool/Xcode version, never credentials.
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
6. Require an attended owner approval that Development matches the frozen
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

## Human approval checklist

- [ ] Owner approves the two bundle IDs and one shared container, or records replacements.
- [ ] Owner confirms the authorized paid-team capability boundary; no team ID is recorded here.
- [ ] Owner approves private database/custom-zone ownership and the schema contract hash.
- [ ] Owner approves Development versus Production entitlement files for both targets.
- [ ] Owner approves CloudKit, Background Modes/audio, and remote-notification scope.
- [ ] Owner chooses the non-sandbox Developer ID hypothesis or an approved sandbox alternative.
- [ ] Owner approves certificate/profile classes and artifact inspection method without recording names or secrets.
- [ ] Owner approves the schema/index comparison, promotion, rollback/stop, and receipt plan.
- [ ] Owner approves physical Mac/iPhone roles and separate Development/Production acceptance.
- [ ] Owner confirms that no portal/container mutation occurs before this checklist and decision table are approved.

## Final decision table

| Area | Proposed decision / required evidence | Owner approval | Evidence reference |
|---|---|---|---|
| Bundle IDs | `com.zerodelta.wilted.mac`; `com.zerodelta.wilted.ios` |  |  |
| Shared container | `iCloud.com.zerodelta.wilted` |  |  |
| CloudKit scope | Private database; `WiltedZone`; current index set empty |  |  |
| Development entitlements | CloudKit service + container identifiers; Development notification value if used |  |  |
| Production entitlements | CloudKit service + container identifiers + `icloud-container-environment: Production`; Production notification value if used |  |  |
| iOS capabilities | CloudKit, Background Modes/audio, remote notifications as approved |  |  |
| Mac distribution | Hardened/notarized Developer ID without App Sandbox, or owner-approved alternative |  |  |
| Schema promotion | Hash-bound text-schema import/export, diff, index evidence, attended promotion approval |  |  |
| Signing/profiles | Correct target, capability, environment, and artifact-bound inspection receipts |  |  |
| Device/release proof | Signed physical Mac/iPhone Production acceptance; App Store Connect/TestFlight receipts separately |  |  |

### References

- Repository: `project.yml`, `contracts/cloudkit/schema.json`,
  `docs/phase0-apple-capability-inventory.md`, and `docs/phase0-decision-record.md`.
- Local release policy: the central Apple release standard maintained outside this repository.
- Local entitlement patterns: Gradus Mac Development/Production and iOS
  entitlements; WWPIS iOS CloudKit entitlement. These are precedent only.
- Apple: [iCloud container environment](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment), [iCloud services](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services), [text-based schema workflow](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow), and [supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios).
