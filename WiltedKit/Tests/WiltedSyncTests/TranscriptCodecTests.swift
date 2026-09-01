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

@Test("transcript codec carries cue timing and its provenance across the wire")
func transcriptCodecCarriesTiming() throws {
    let codec = WiltedRecordCodec()
    let cues = [try TranscriptCue(startSeconds: 0, endSeconds: 2.5, text: "First line"),
                try TranscriptCue(startSeconds: 2.5, endSeconds: 6, text: "Second line")]
    let value = try Transcript(itemID: ItemID(rawValue: "item-transcript"),
                               revisionID: RevisionID(rawValue: "rev-transcript"),
                               availability: .available, text: "First line Second line",
                               languageCode: "en-US", timing: .published, cues: cues,
                               updatedAt: Timestamp(iso8601: "2026-08-23T20:00:00Z"))
    let envelope = try codec.encode(transcript: value)
    #expect(envelope.fields["timing"] == .string("published"))
    guard case .bytes = envelope.fields["cues"] else {
        Issue.record("cues must travel as bytes so the record budget stays with the text")
        return
    }
    let decoded = try codec.decodeTranscript(envelope)
    #expect(decoded == value)
    #expect(decoded.cue(at: 3)?.text == "Second line")
    // Cues are not a leftover the decoder forwards as opaque state; they are
    // decoded content, so nothing about them should reappear in opaqueFields.
    #expect(try codec.decodeTranscriptRecord(envelope).opaqueFields.isEmpty)
}

@Test("a record written before timing existed decodes as untimed rather than failing")
func transcriptCodecAcceptsVersionOneRecords() throws {
    let codec = WiltedRecordCodec()
    let value = try transcriptFixture()
    var legacy = try codec.encode(transcript: value).fields
    legacy.removeValue(forKey: "timing")
    legacy["schemaVersion"] = .int64(1)
    let id = try WiltedRecordID.transcript(value.itemID, value.revisionID)
    let decoded = try codec.decodeTranscript(WiltedRecordEnvelope(id: id, fields: legacy))
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.timing == .none)
    #expect(decoded.cues == nil)
}

@Test("transcript codec refuses unreadable timing rather than downgrading it")
func transcriptCodecRejectsCorruptTiming() throws {
    let codec = WiltedRecordCodec()
    let value = try transcriptFixture()
    let valid = try codec.encode(transcript: value)
    var unknownTiming = valid.fields
    unknownTiming["timing"] = .string("guessed")
    #expect(throws: WiltedSyncError.invalidValue(field: "transcript.timing")) {
        try codec.decodeTranscript(WiltedRecordEnvelope(id: valid.id, fields: unknownTiming))
    }
    var corruptCues = valid.fields
    corruptCues["timing"] = .string("aligned")
    corruptCues["cues"] = .bytes(Data("not zlib".utf8))
    #expect(throws: WiltedSyncError.invalidValue(field: "transcript.cues")) {
        try codec.decodeTranscript(WiltedRecordEnvelope(id: valid.id, fields: corruptCues))
    }
    // Timing without cues is a half-written record; the domain contract
    // refuses it and the codec must surface that rather than paper over it.
    var timingWithoutCues = valid.fields
    timingWithoutCues["timing"] = .string("aligned")
    #expect(throws: WiltedSyncError.invalidValue(field: "transcript")) {
        try codec.decodeTranscript(WiltedRecordEnvelope(id: valid.id, fields: timingWithoutCues))
    }
}

@Test("only transcripts accept the version-two field schema")
func onlyTranscriptsAcceptVersionTwo() throws {
    let codec = WiltedRecordCodec()
    let url = try #require(URL(string: "https://example.test/a"))
    let article = try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "A",
                              source: "Example", createdAt: Timestamp(iso8601: "2026-08-23T20:00:00Z"))
    let valid = try codec.encode(article: article, currentRevisionID: RevisionID(rawValue: "rev-a"))
    var fields: [String: WiltedFieldValue] = valid.fields
    fields["schemaVersion"] = .int64(2)
    #expect(throws: WiltedSyncError.unsupportedSchemaVersion(2)) {
        try codec.decodeArticle(WiltedRecordEnvelope(id: valid.id, fields: fields))
    }
}

/// The envelope writes no version of its own, so a JSON round trip recovers it
/// from the record's `schemaVersion` field. If the encoder pinned the envelope
/// at one while the field said two, the envelope would change version on the
/// way through the store and the pending change would stop decoding.
@Test("a timed transcript envelope survives a JSON round trip through the store")
func timedTranscriptEnvelopeSurvivesJSONRoundTrip() throws {
    let codec = WiltedRecordCodec()
    let cues = [try TranscriptCue(startSeconds: 0, endSeconds: 2, text: "Line one")]
    let value = try Transcript(itemID: ItemID(rawValue: "item-transcript"),
                               revisionID: RevisionID(rawValue: "rev-transcript"),
                               availability: .available, text: "Line one", timing: .aligned,
                               cues: cues, updatedAt: Timestamp(iso8601: "2026-08-23T20:00:00Z"))
    let envelope = try codec.encode(transcript: value)
    #expect(envelope.schemaVersion == 2)
    let restored = try JSONDecoder().decode(WiltedRecordEnvelope.self, from: JSONEncoder().encode(envelope))
    #expect(restored == envelope)
    #expect(try codec.decodeTranscript(restored) == value)
}

@Test("only transcript envelopes accept version two")
func onlyTranscriptEnvelopesAcceptVersionTwo() throws {
    #expect(WiltedRecordEnvelope.supportedSchemaVersions(for: .transcript) == 1...2)
    for type in [WiltedRecordType.item, .revision, .playbackState] {
        #expect(WiltedRecordEnvelope.supportedSchemaVersions(for: type) == 1...1)
    }
    let id = try WiltedRecordID.item(ItemID(rawValue: "item-version"))
    #expect(throws: WiltedSyncError.unsupportedSchemaVersion(2)) {
        try WiltedRecordEnvelope(id: id, schemaVersion: 2, fields: [:])
    }
}
