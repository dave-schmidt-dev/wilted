# Phase 0 Apple capability inventory

Status: inventory only. This is not a capability-ready or release-ready claim.

## Credential-free facts

- The frozen deployment minimums are macOS 14+ for the full-window SwiftUI Mac app and iOS 17+ for the iPhone SwiftUI app. iPad optimization is deferred. [Implementation plan, lines 50-61](../../.plans/wilted/wilted-native-mvp-implementation-2026-08-17.md#L50-L61)
- The planned project toolchain is SwiftUI plus a CloudKit-free Swift package (`WiltedKit`); `project.yml` is the XcodeGen source of truth and generated project files must not become a second authority. [Implementation plan, lines 69-80](../../.plans/wilted/wilted-native-mvp-implementation-2026-08-17.md#L69-L80)
- `CKSyncEngine` is the preferred synchronization adapter on macOS 14/iOS 17, with opaque engine state persisted and scheduling treated as eventual. This is a documented design/API availability fact, not a successful local runtime probe. [Implementation plan, lines 160-170](../../.plans/wilted/wilted-native-mvp-implementation-2026-08-17.md#L160-L170)
- The recommended personal-MVP hypothesis is a hardened, notarized Developer ID Mac app without App Sandbox. This remains a hypothesis until the signed runtime spike proves the speech boundary and the owner approves the distribution choice. [Implementation plan, lines 141-148](../../.plans/wilted/wilted-native-mvp-implementation-2026-08-17.md#L141-L148)
- Gradus provides the applicable XcodeGen convention: separate Mac/iOS application targets, explicit deployment targets, unit-test and UI-test bundles, and schemes that enumerate test targets. [Gradus `project.yml`, lines 14-45, 125-145, 212-250, 269-330](../../gradus/app/project.yml#L14-L45)
- Gradus also demonstrates the required entitlement separation: development entitlements use `aps-environment: development` and CloudKit; its production Mac entitlements add `aps-environment: production` and `icloud-container-environment: Production`. These are reference conventions, not Wilted identifiers. [Gradus development entitlements](../../gradus/app/GradusMac/GradusMac.entitlements#L5-L14), [Gradus production entitlements](../../gradus/app/GradusMac/GradusMacProduction.entitlements#L5-L16)

Development evidence must use Development entitlements only. The notarized Developer ID Mac candidate and TestFlight iPhone candidate must explicitly carry the Production CloudKit environment entitlement. [Implementation plan, lines 172-180](../../.plans/wilted/wilted-native-mvp-implementation-2026-08-17.md#L172-L180)

## Simulator inventory boundary

CoreSimulator was inaccessible from the restricted workspace sandbox, where `simctl` reported an invalid service connection. The same read-only inventory succeeded with host access and found installed iOS simulator runtimes and available devices. This proves inventory only: no Wilted simulator build or test has run, and no SDK, device, signing, CloudKit, or TestFlight readiness is inferred.

## Attended human gates still required

Before any portal or external mutation, an attended owner must verify and approve:

- final bundle identifiers, iCloud container identifier, Apple Developer team, and target ownership;
- Development versus Production CloudKit configuration and entitlements;
- CloudKit custom-zone schema, required indexes, and Development-to-Production schema/index promotion;
- appropriate Apple Development, Developer ID, and iPhone distribution certificates and provisioning profiles;
- remote-notification and background-audio capabilities, including the signed artifact’s effective entitlements and Info.plist;
- the non-App-Sandbox Developer ID Mac choice, or an owner-approved App Sandbox/App Group/XPC alternative;
- physical-device validation: Mac signed/notarized artifact and iPhone playback, background audio, lock-screen controls, and remote delivery;
- App Store Connect processing and user-visible internal TestFlight availability for the signed iPhone candidate.

These gates are explicitly required by the plan before portal mutation and qualification; simulator or Development results cannot substitute for Production/device evidence. [Implementation plan, lines 309-324](../../.plans/wilted/wilted-native-mvp-implementation-2026-08-17.md#L309-L324), [Apple release standard, lines 78-98](../../apple_developer/RELEASE_STANDARDS.md#L78-L98)
