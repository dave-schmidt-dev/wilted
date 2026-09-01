#!/usr/bin/env swift

import Foundation

typealias JSONObject = [String: Any]

struct ContractError: Error, CustomStringConvertible {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var description: String { "\(code): \(message)" }
}

func fail(_ code: String, _ message: String) throws -> Never { throw ContractError(code, message) }
func object(_ value: Any?, _ path: String) throws -> JSONObject {
    guard let value = value as? JSONObject else { try fail("wrong-object-type", "\(path) must be an object") }
    return value
}
func string(_ value: Any?, _ path: String) throws -> String {
    guard let value = value as? String, !value.isEmpty else { try fail("wrong-field-type", "\(path) must be a non-empty string") }
    return value
}
func number(_ value: Any?, _ path: String) throws -> NSNumber {
    guard let value = value as? NSNumber, String(cString: value.objCType) != "c", value.doubleValue.isFinite else {
        try fail("wrong-field-type", "\(path) must be a finite number")
    }
    return value
}
func integer(_ value: Any?, _ path: String) throws -> Int64 {
    let value = try number(value, path)
    guard value.doubleValue.rounded() == value.doubleValue else { try fail("wrong-field-type", "\(path) must be an integer") }
    return value.int64Value
}
func bool(_ value: Any?, _ path: String) throws -> Bool {
    guard let value = value as? Bool else { try fail("wrong-field-type", "\(path) must be a boolean") }
    return value
}
func readJSON(_ path: String) throws -> Any {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
func path(_ base: String, _ child: String) -> String { base.hasSuffix("/") ? base + child : base + "/" + child }
func allJSONFiles(_ directory: String) throws -> [String] {
    let files = try FileManager.default.contentsOfDirectory(atPath: directory)
    return files.filter { $0.hasSuffix(".json") }.sorted().map { path(directory, $0) }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let schemaPath = path(root, "contracts/cloudkit/schema.json")
let fixtureDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : path(root, "contracts/cloudkit/fixtures")

let schema = try object(readJSON(schemaPath), "schema")
guard try integer(schema["contractVersion"], "schema.contractVersion") == 1 else {
    throw ContractError("invalid-contract", "schema contractVersion must be 1")
}
let database = try object(schema["database"], "schema.database")
guard try string(database["scope"], "schema.database.scope") == "private",
      try string(database["zoneType"], "schema.database.zoneType") == "custom",
      try string(database["zoneName"], "schema.database.zoneName") == "WiltedZone" else {
    throw ContractError("invalid-contract", "database must be the private WiltedZone custom zone")
}
let supportedVersions = Set(try (schema["supportedSchemaVersions"] as? [Any] ?? []).map { try integer($0, "schema.supportedSchemaVersions") })
guard supportedVersions == Set([Int64(1)]) else { throw ContractError("invalid-contract", "only schema version 1 is frozen") }
// Transcripts are the one family whose own record version moved, because
// timing was added additively at version two. Version-one transcript records
// carry no timing or cues field and still decode; every other family stays at
// version one, and the two sets are validated separately so a stray version
// bump elsewhere still fails.
let transcriptVersions = Set(try (schema["transcriptSchemaVersions"] as? [Any] ?? []).map { try integer($0, "schema.transcriptSchemaVersions") })
guard transcriptVersions == Set([Int64(1), Int64(2)]) else { throw ContractError("invalid-contract", "transcript records accept schema versions 1 and 2") }
let queryIndexAllowlist = schema["queryIndexAllowlist"] as? [Any] ?? []
guard queryIndexAllowlist.isEmpty else { throw ContractError("invalid-contract", "Phase 0 must not freeze custom query indexes") }
let delayOfflineQuota = try object(schema["delayOfflineQuota"], "schema.delayOfflineQuota")
let publicationBudget = try object(delayOfflineQuota["publicationBudget"], "schema.delayOfflineQuota.publicationBudget")
guard try string(publicationBudget["parameter"], "publicationBudget.parameter") == "audioPublicationBudgetBytes",
      try string(publicationBudget["status"], "publicationBudget.status") == "frozen-app-policy",
      try integer(publicationBudget["maxRevisionAssetBytes"], "publicationBudget.maxRevisionAssetBytes") == 80000000,
      try integer(publicationBudget["maxOwnedAssetBytes"], "publicationBudget.maxOwnedAssetBytes") == 800000000,
      try string(publicationBudget["capacityRationale"], "publicationBudget.capacityRationale") == "10 maximum-sized revisions for the small-library MVP",
      try string(publicationBudget["aggregateFormula"], "publicationBudget.aggregateFormula") == "acknowledgedOwnedBytes + pendingOwnedBytes + candidateBytes <= maxOwnedAssetBytes",
      try bool(publicationBudget["isCloudKitLimit"], "publicationBudget.isCloudKitLimit") == false,
      try bool(publicationBudget["automaticEviction"], "publicationBudget.automaticEviction") == false else {
    throw ContractError("invalid-contract", "publication budget must be the accepted app-owned policy")
}

struct FieldSpec {
    let type: String
    let logicalType: String?
    let target: String?
    let enumValues: Set<String>
}
struct RecordSpec {
    let required: [String: FieldSpec]
    let optional: [String: FieldSpec]
    let references: [String]
}

func fieldSpecs(_ value: Any?, _ path: String) throws -> [String: FieldSpec] {
    let fields = try object(value, path)
    var result: [String: FieldSpec] = [:]
    for name in fields.keys.sorted() {
        let descriptor = try object(fields[name], "\(path).\(name)")
        let values = try (descriptor["enum"] as? [Any] ?? []).map { try string($0, "\(path).\(name).enum") }
        result[name] = FieldSpec(type: try string(descriptor["cloudKitType"], "\(path).\(name).cloudKitType"),
                                  logicalType: descriptor["logicalType"] as? String,
                                  target: descriptor["referenceTarget"] as? String,
                                  enumValues: Set(values))
    }
    return result
}

let recordsObject = try object(schema["records"], "schema.records")
var records: [String: RecordSpec] = [:]
for recordType in recordsObject.keys.sorted() {
    let raw = try object(recordsObject[recordType], "schema.records.\(recordType)")
    records[recordType] = RecordSpec(required: try fieldSpecs(raw["requiredFields"], "schema.records.\(recordType).requiredFields"),
                                      optional: try fieldSpecs(raw["optionalFields"], "schema.records.\(recordType).optionalFields"),
                                      references: try (raw["references"] as? [Any] ?? []).map { try string($0, "schema.records.\(recordType).references") })
}
let expectedRecordTypes = Set(["WiltedItem", "WiltedRevision", "WiltedTranscript", "WiltedPlaybackState"])
guard Set(records.keys) == expectedRecordTypes else { throw ContractError("invalid-contract", "schema must define exactly the four Wilted record families") }

func validateDate(_ value: Any?, _ path: String) throws {
    let text = try string(value, path)
    let pattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let noFraction = ISO8601DateFormatter()
    noFraction.formatOptions = [.withInternetDateTime]
    guard pattern.firstMatch(in: text, range: range) != nil,
          format.date(from: text) != nil || noFraction.date(from: text) != nil else {
        try fail("wrong-field-type", "\(path) must be UTC ISO 8601 ending in Z")
    }
}
func validateType(_ field: JSONObject, _ spec: FieldSpec, _ path: String) throws {
    guard try string(field["type"], "\(path).type") == spec.type else { try fail("wrong-field-type", "\(path).type does not match schema") }
    let value = field["value"]
    switch spec.type {
    case "String":
        let text = try string(value, "\(path).value")
        if spec.logicalType == "identifier" {
            let pattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._~-]*$"#)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard pattern.firstMatch(in: text, range: range) != nil else { try fail("invalid-identifier", "\(path).value is not a contract identifier") }
        }
        if spec.logicalType == "httpsURL", !text.hasPrefix("https://") { try fail("invalid-url", "\(path).value must use https") }
        if spec.logicalType == "sha256", !text.hasPrefix("sha256:") { try fail("invalid-hash", "\(path).value must use sha256:<value>") }
        if spec.logicalType == "boundedTranscriptText", text.utf8.count > 500_000 {
            try fail("transcript-too-large", "\(path).value exceeds the 500000-byte transcript limit")
        }
        if spec.logicalType == "bcp47" {
            let pattern = try! NSRegularExpression(pattern: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard text.utf8.count <= 35, pattern.firstMatch(in: text, range: range) != nil else {
                try fail("invalid-language-code", "\(path).value must be a BCP 47 language tag")
            }
        }
        if !spec.enumValues.isEmpty && !spec.enumValues.contains(text) { try fail("invalid-enum", "\(path).value is not allowed") }
    case "Int64":
        let n = try integer(value, "\(path).value")
        if spec.logicalType == "boolean01", n != 0 && n != 1 { try fail("invalid-boolean01", "\(path).value must be 0 or 1") }
        if spec.logicalType == "positive", n <= 0 { try fail("invalid-positive", "\(path).value must be positive") }
        if spec.logicalType == "supportedSchemaVersion", !supportedVersions.contains(n) { try fail("unsupported-schema-version", "\(path).value is not supported") }
        if spec.logicalType == "transcriptSchemaVersion", !transcriptVersions.contains(n) { try fail("unsupported-schema-version", "\(path).value is not supported") }
    case "Double":
        let n = try number(value, "\(path).value").doubleValue
        if spec.logicalType == "positive", n <= 0 { try fail("invalid-positive", "\(path).value must be positive") }
        if spec.logicalType == "nonnegative", n < 0 { try fail("invalid-nonnegative", "\(path).value must not be negative") }
    case "Date":
        try validateDate(value, "\(path).value")
    case "Asset":
        let asset = try object(value, "\(path).value")
        _ = try string(asset["assetID"], "\(path).value.assetID")
        _ = try string(asset["contentHash"], "\(path).value.contentHash")
    case "Reference":
        let reference = try object(value, "\(path).value")
        _ = try string(reference["recordType"], "\(path).value.recordType")
        _ = try string(reference["recordName"], "\(path).value.recordName")
        guard try string(reference["zoneName"], "\(path).value.zoneName") == "WiltedZone" else { try fail("reference-outside-zone", "\(path) must remain in WiltedZone") }
        guard try string(reference["action"], "\(path).value.action") == "none" else { try fail("invalid-reference-action", "\(path) must not cascade") }
    case "Bytes":
        let text = try string(value, "\(path).value")
        guard let bytes = Data(base64Encoded: text) else { try fail("wrong-field-type", "\(path).value must be base64 bytes") }
        if spec.logicalType == "boundedTranscriptCues" {
            // Cues travel compressed, so the transport check is on the wire
            // bytes. The uncompressed ceiling belongs to the domain contract,
            // which is the only thing that can actually parse them.
            guard bytes.count <= 1_000_000 else { try fail("transcript-cues-too-large", "\(path).value exceeds the 1000000-byte cue limit") }
            guard bytes.count >= 2, bytes[bytes.startIndex] == 0x78 else {
                try fail("invalid-transcript-cues", "\(path).value must be zlib-compressed cue JSON")
            }
        }
    default:
        try fail("invalid-contract", "unsupported CloudKit type \(spec.type)")
    }
}

func recordName(_ recordType: String, _ fields: JSONObject) throws -> String {
    let item = try string((fields["itemID"] as? JSONObject)?["value"], "fields.itemID.value")
    switch recordType {
    case "WiltedItem": return "item:\(item)"
    case "WiltedRevision": return "revision:\(item):\(try string((fields["revisionID"] as? JSONObject)?["value"], "fields.revisionID.value"))"
    case "WiltedTranscript": return "transcript:\(item):\(try string((fields["revisionID"] as? JSONObject)?["value"], "fields.revisionID.value"))"
    case "WiltedPlaybackState": return "playback:\(item):\(try string((fields["revisionID"] as? JSONObject)?["value"], "fields.revisionID.value"))"
    default: try fail("unknown-record-type", "\(recordType) is not frozen")
    }
}

func validateRecord(_ raw: JSONObject) throws -> (type: String, name: String) {
    let recordType = try string(raw["recordType"], "record.recordType")
    guard let spec = records[recordType] else { try fail("unknown-record-type", recordType) }
    guard try string(raw["zoneName"], "record.zoneName") == "WiltedZone" else { try fail("wrong-zone", "records must be in WiltedZone") }
    let name = try string(raw["recordName"], "record.recordName")
    let fields = try object(raw["fields"], "record.fields")
    let names = Set(fields.keys)
    for required in spec.required.keys where fields[required] == nil { try fail("missing-required-field", "\(recordType).\(required) is required") }
    let allowed = Set(spec.required.keys).union(spec.optional.keys)
    if let unknown = names.subtracting(allowed).sorted().first { try fail("unknown-field", "\(recordType).\(unknown) is not declared") }
    for key in names {
        let field = try object(fields[key], "\(recordType).\(key)")
        try validateType(field, spec.required[key] ?? spec.optional[key]!, "\(recordType).\(key)")
    }
    if recordType == "WiltedTranscript" {
        let availability = try string((fields["availability"] as? JSONObject)?["value"], "WiltedTranscript.availability.value")
        let hasText = fields["text"] != nil
        if ["available", "stale"].contains(availability), !hasText {
            try fail("missing-transcript-text", "WiltedTranscript.text is required for available or stale content")
        }
        if ["absent", "oversized", "malformed"].contains(availability), hasText {
            try fail("unexpected-transcript-text", "WiltedTranscript.text must be absent for unavailable content")
        }
        // Timing and cues state one fact twice, so a record carrying half of it
        // is malformed: a reader would either scroll against nothing or treat
        // cues as evidence the record never claimed.
        let timing = try (fields["timing"] as? JSONObject).map { try string($0["value"], "WiltedTranscript.timing.value") } ?? "none"
        let hasCues = fields["cues"] != nil
        if timing == "none", hasCues {
            try fail("unexpected-transcript-cues", "WiltedTranscript.cues must be absent when timing is none")
        }
        if timing != "none", !hasCues {
            try fail("missing-transcript-cues", "WiltedTranscript.cues is required for timed content")
        }
        if hasCues, !["available", "stale"].contains(availability) {
            try fail("unexpected-transcript-cues", "WiltedTranscript.cues must be absent for unavailable content")
        }
        // Version one predates timing entirely. A record that declares version
        // one and still carries timing is claiming a shape that never existed.
        let version = try integer((fields["schemaVersion"] as? JSONObject)?["value"], "WiltedTranscript.schemaVersion.value")
        if version == 1, fields["timing"] != nil || hasCues {
            try fail("unsupported-schema-version", "WiltedTranscript version 1 predates timing")
        }
    }
    guard name == (try recordName(recordType, fields)) else { try fail("unstable-record-name", "\(recordType) record name does not follow the stable rule") }
    for referenceName in spec.references {
        let field = try object(fields[referenceName], "\(recordType).\(referenceName)")
        let reference = try object(field["value"], "\(recordType).\(referenceName).value")
        let targetType = try string(reference["recordType"], "reference.recordType")
        guard let targetSpec = spec.required[referenceName], targetSpec.target == targetType else { try fail("invalid-reference-target", "\(recordType).\(referenceName) target is not declared") }
        let expectedPrefix: String
        switch targetType { case "WiltedItem": expectedPrefix = "item:"; case "WiltedRevision": expectedPrefix = "revision:"; default: expectedPrefix = "" }
        guard (try string(reference["recordName"], "reference.recordName")).hasPrefix(expectedPrefix) else { try fail("invalid-reference-target", "reference record name has the wrong family") }
    }
    return (recordType, name)
}

func validateSidecars(_ raw: JSONObject, _ names: Set<String>) throws {
    let sidecars = try object(raw["sidecars"], "fixture.sidecars")
    guard Set(sidecars.keys) == names else { try fail("missing-system-fields", "every published record needs its opaque sidecar") }
    for name in names {
        let sidecar = try object(sidecars[name], "fixture.sidecars.\(name)")
        let encoded = try string(sidecar["encodedSystemFieldsBase64"], "fixture.sidecars.\(name).encodedSystemFieldsBase64")
        guard Data(base64Encoded: encoded) != nil else { try fail("invalid-system-fields", "system fields must be base64") }
        _ = try string(sidecar["changeTag"], "fixture.sidecars.\(name).changeTag")
    }
}

func validateQuery(_ raw: JSONObject) throws {
    let query = try object(raw["query"], "fixture.query")
    let recordType = try string(query["recordType"], "query.recordType")
    let field = try string(query["field"], "query.field")
    let op = try string(query["operator"], "query.operator")
    let allowlist = queryIndexAllowlist.compactMap { $0 as? JSONObject }
    let allowed = allowlist.contains { item in
        (item["recordType"] as? String) == recordType && (item["field"] as? String) == field && (item["operator"] as? String) == op
    }
    guard allowed else { try fail("query-not-allowlisted", "\(recordType).\(field) \(op) is not an allowed query") }
}

func validateBudget(_ raw: JSONObject) throws {
    let input = try object(raw["input"], "fixture.input")
    let candidate = try integer(input["candidateBytes"], "input.candidateBytes")
    let acknowledged = try integer(input["acknowledgedOwnedBytes"], "input.acknowledgedOwnedBytes")
    let pending = try integer(input["pendingOwnedBytes"], "input.pendingOwnedBytes")
    guard candidate >= 0, acknowledged >= 0, pending >= 0 else { try fail("invalid-budget-input", "budget byte counts must not be negative") }
    let maxRevision = try integer(publicationBudget["maxRevisionAssetBytes"], "publicationBudget.maxRevisionAssetBytes")
    let maxOwned = try integer(publicationBudget["maxOwnedAssetBytes"], "publicationBudget.maxOwnedAssetBytes")
    if candidate > maxRevision { try fail("revision-budget-exceeded", "candidate exceeds maxRevisionAssetBytes") }
    guard acknowledged <= Int64.max - pending else { try fail("aggregate-budget-exceeded", "owned byte sum overflows") }
    let ownedPlusCandidate = acknowledged + pending
    guard ownedPlusCandidate <= Int64.max - candidate, ownedPlusCandidate + candidate <= maxOwned else {
        try fail("aggregate-budget-exceeded", "owned plus candidate bytes exceed maxOwnedAssetBytes")
    }
    let expected = try object(raw["expected"], "fixture.expected")
    guard try string(expected["decision"], "expected.decision") == "allow",
          try bool(expected["visibleRejection"], "expected.visibleRejection") == false else {
        try fail("invalid-budget-fixture", "an allowed budget fixture must have no visible rejection")
    }
}

func validateFixture(_ raw: JSONObject) throws {
    guard try integer(raw["fixtureVersion"], "fixture.fixtureVersion") == 1 else { try fail("invalid-fixture", "fixtureVersion must be 1") }
    _ = try string(raw["caseID"], "fixture.caseID")
    let operation = try string(raw["operation"], "fixture.operation")
    let expectedValid = try bool(raw["expectedValid"], "fixture.expectedValid")
    do {
        switch operation {
        case "publishDecode", "recordValidation":
            let rawRecords = raw["records"] as? [Any] ?? []
            guard !rawRecords.isEmpty else { try fail("missing-records", "fixture.records must not be empty") }
            var names = Set<String>()
            for value in rawRecords {
                let result = try validateRecord(try object(value, "fixture.records[]"))
                guard names.insert(result.name).inserted else { try fail("duplicate-record-name", result.name) }
            }
            if operation == "publishDecode" { try validateSidecars(raw, names) }
        case "queryValidation": try validateQuery(raw)
        case "budgetValidation": try validateBudget(raw)
        default: try fail("unknown-operation", operation)
        }
        guard expectedValid else { try fail("expected-invalid-but-valid", "fixture was expected to fail") }
    } catch let error as ContractError {
        guard !expectedValid else { throw error }
        let expectedError = try string(raw["expectedError"], "fixture.expectedError")
        guard error.code == expectedError else { throw ContractError("wrong-invalid-fixture", "expected \(expectedError), got \(error.code)") }
    }
}

let fixturePaths = try allJSONFiles(fixtureDirectory)
guard !fixturePaths.isEmpty else { throw ContractError("no-fixtures", "no CloudKit fixtures found") }
var validated = 0
for fixturePath in fixturePaths {
    let fixture = try object(readJSON(fixturePath), fixturePath)
    try validateFixture(fixture)
    validated += 1
    print("PASS \(fixturePath.split(separator: "/").last!)")
}
print("Validated \(validated) CloudKit contract fixtures")
