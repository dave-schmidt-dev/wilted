import Foundation
import Testing
@testable import WiltedProducer

@Suite("Labelled attempt outcome recording and decoding")
struct LabelledAttemptOutcomeInfoTests {
    @Test func decodesFromJournalEvidenceFieldsWithAllValuesPresent() {
        let fields: [String: String] = [
            "provider": "openCodeCLI",
            "modelID": "deepseek-v4.1-flash",
            "level": "low",
            "breaks": "2",
            "rejected": "0",
        ]
        let info = LabelledAttemptOutcomeInfo.decode(from: fields)
        #expect(info.provider == "openCodeCLI")
        #expect(info.modelID == "deepseek-v4.1-flash")
        #expect(info.level == "low")
    }

    @Test func decodesOlderJournalRecordsWithoutProviderAsUnknown() {
        let legacyFields: [String: String] = [
            "modelID": "deepseek-v4.1-flash",
            "level": "low",
            "breaks": "1",
        ]
        let info = LabelledAttemptOutcomeInfo.decode(from: legacyFields)
        #expect(info.provider == "unknown")
        #expect(info.modelID == "deepseek-v4.1-flash")
        #expect(info.level == "low")
    }

    @Test func decodesOlderRecordsWithNoFieldsAsUnknown() {
        let emptyFields: [String: String] = [:]
        let info = LabelledAttemptOutcomeInfo.decode(from: emptyFields)
        #expect(info.provider == "unknown")
        #expect(info.modelID == "unknown")
        #expect(info.level == "unknown")
    }

    @Test func decodesFromDictionary() {
        let dict: [String: Any] = [
            "labellerProvider": "openCodeCLI",
            "labellerModelID": "deepseek-v4.1-flash",
            "labellerLevel": "high",
        ]
        let info = LabelledAttemptOutcomeInfo.decode(from: dict)
        #expect(info.provider == "openCodeCLI")
        #expect(info.modelID == "deepseek-v4.1-flash")
        #expect(info.level == "high")
    }

    @Test func decodesLegacyDictionaryWithoutProviderAsUnknown() {
        let legacyDict: [String: Any] = [
            "labellerModelID": "deepseek-v4.1-flash",
            "labellerLevel": "high",
        ]
        let info = LabelledAttemptOutcomeInfo.decode(from: legacyDict)
        #expect(info.provider == "unknown")
        #expect(info.modelID == "deepseek-v4.1-flash")
        #expect(info.level == "high")
    }
}
