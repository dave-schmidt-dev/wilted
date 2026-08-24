import Foundation
import Testing
import WiltedDomain
@testable import WiltedSync

private func transcriptFixture(_ availability: TranscriptAvailability = .available,
                               text: String? = "A synced transcript.") throws -> Transcript {
    try Transcript(itemID: ItemID(rawValue: "item-transcript"),
                   revisionID: RevisionID(rawValue: "rev-transcript"),
                   availability: availability, text: text, languageCode: "en-US",
                   updatedAt: Timestamp(iso8601: "2026-08-23T20:00:00Z"))
}

@Test("transcript codec preserves identity, content, metadata, and opaque fields")
func transcriptCodecRoundTrip() throws {
    let codec = WiltedRecordCodec()
    let value = try transcriptFixture()
    let envelope = try codec.encode(transcript: value, opaqueFields: ["futureMetadata": .string("kept")])
    let expectedID = try WiltedRecordID.transcript(value.itemID, value.revisionID)
    #expect(envelope.id == expectedID)
    let decoded = try codec.decodeTranscriptRecord(envelope)
    #expect(decoded.value == value)
    #expect(decoded.opaqueFields == ["futureMetadata": .string("kept")])
}

@Test("transcript codec carries explicit unavailable states without text")
func transcriptCodecUnavailableStates() throws {
    let codec = WiltedRecordCodec()
    for state in [TranscriptAvailability.absent, .oversized, .malformed] {
        let value = try transcriptFixture(state, text: nil)
        #expect(try codec.decodeTranscript(codec.encode(transcript: value)) == value)
    }
}

@Test("transcript codec rejects identity, required-field, and content-shape corruption")
func transcriptCodecRejectsMalformedRecords() throws {
    let codec = WiltedRecordCodec()
    let value = try transcriptFixture()
    let valid = try codec.encode(transcript: value)
    var missing = valid.fields
    missing.removeValue(forKey: "availability")
    #expect(throws: WiltedSyncError.missingRequiredField("availability")) {
        try codec.decodeTranscript(WiltedRecordEnvelope(id: valid.id, fields: missing))
    }
    var badText = valid.fields
    badText["text"] = .string("")
    #expect(throws: WiltedSyncError.invalidValue(field: "transcript")) {
        try codec.decodeTranscript(WiltedRecordEnvelope(id: valid.id, fields: badText))
    }
    let wrongID = try WiltedRecordID.transcript(ItemID(rawValue: "item-other"), value.revisionID)
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try codec.decodeTranscript(WiltedRecordEnvelope(id: wrongID, fields: valid.fields))
    }
}

@Test("iPhone transcript mutations remain forbidden while Mac owns publication")
func transcriptOwnership() {
    let policy = SyncOwnershipPolicy()
    #expect(policy.allows(role: .mac, operation: .create, recordType: .transcript))
    #expect(policy.allows(role: .mac, operation: .update, recordType: .transcript))
    #expect(!policy.allows(role: .iphone, operation: .create, recordType: .transcript))
    #expect(!policy.allows(role: .iphone, operation: .update, recordType: .transcript))
}
