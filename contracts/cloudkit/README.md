# CloudKit contract freeze

`schema.json` is the credential-free, machine-readable Phase 0 contract for
Wilted's private CloudKit database. It freezes one custom zone, four record
families, field types, record-name construction, references, query indexes,
ownership, schema compatibility, and failure behavior. No custom query indexes
are frozen yet: Phase 0 has no implemented adapter queries, and record-name
lookups and zone changes do not require indexes. It does not create a
container, promote a schema, or assert a service quota.

CloudKit system fields and `CKSyncEngine` state are local opaque byte sidecars;
they are not user-defined record fields. A change tag is required for an
optimistic update or delete. A stale tag causes refetch and pure reconciliation.

The publication budget is the app-owned policy parameter
`audioPublicationBudgetBytes`: 80,000,000 bytes per revision and 800,000,000
bytes across acknowledged plus pending Wilted-owned remote assets. It is based
on a fresh 90-minute encode and configured bitrate reference, representing ten
maximum-sized revisions for the small-library MVP. It is not a CloudKit service
limit. Publication rejects visibly before upload when either check
fails. Recovery is explicit item deletion after remote acknowledgement or a
later owner configuration change; there is no automatic eviction, and local
`Remove Download` does not free remote asset budget. `CKError.quotaExceeded`
remains a separate actionable failure below this policy.

Fixtures under `fixtures/` include valid core and transcript publish/decode cases and invalid
missing-field, wrong-type, unsupported-schema, out-of-zone-reference, and
non-allowlisted-query cases. Run the dependency-free validator with:

```sh
swift scripts/validate-cloudkit-contract.swift
bash tests/test-cloudkit-contract.sh
```
