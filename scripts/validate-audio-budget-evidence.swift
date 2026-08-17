#!/usr/bin/env swift

import Foundation

typealias JSONObject = [String: Any]

struct ValidationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func fail(_ message: String) throws -> Never { throw ValidationError(message: message) }

func object(_ value: Any?, _ path: String) throws -> JSONObject {
    guard let value = value as? JSONObject else { try fail("\(path) must be an object") }
    return value
}

func number(_ value: Any?, _ path: String) throws -> NSNumber {
    guard let value = value as? NSNumber,
          String(cString: value.objCType) != "c",
          value.doubleValue.isFinite else {
        try fail("\(path) must be a finite number")
    }
    return value
}

func integer(_ value: Any?, _ path: String) throws -> Int64 {
    let value = try number(value, path)
    guard value.doubleValue.rounded() == value.doubleValue else { try fail("\(path) must be an integer") }
    return value.int64Value
}

func string(_ value: Any?, _ path: String) throws -> String {
    guard let value = value as? String, !value.isEmpty else { try fail("\(path) must be a non-empty string") }
    return value
}

func boolean(_ value: Any?, _ path: String) throws -> Bool {
    guard let value = value as? Bool else { try fail("\(path) must be a boolean") }
    return value
}

func readJSON(_ path: String) throws -> Any {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { try fail(message) }
}

func validateMeasurement(_ value: Any?, _ index: Int) throws -> (minutes: Double, bytes: Int64) {
    let measurement = try object(value, "evidence.measurements[\(index)]")
    let minutes = try number(measurement["requestedDurationMinutes"], "evidence.measurements[\(index)].requestedDurationMinutes").doubleValue
    let actualSeconds = try number(measurement["actualDurationSeconds"], "evidence.measurements[\(index)].actualDurationSeconds").doubleValue
    let bytes = try integer(measurement["encodedByteSize"], "evidence.measurements[\(index)].encodedByteSize")
    let hash = try string(measurement["sha256"], "evidence.measurements[\(index)].sha256")
    let durationWithinTolerance = try boolean(measurement["durationWithinTolerance"], "evidence.measurements[\(index)].durationWithinTolerance")
    try require(minutes > 0 && actualSeconds > 0 && bytes > 0, "evidence.measurements[\(index)] must contain positive duration and byte values")
    try require(abs(actualSeconds - minutes * 60.0) <= 1.0, "evidence.measurements[\(index)] actual duration does not match requested duration")
    try require(hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "evidence.measurements[\(index)].sha256 must be a lowercase SHA-256 hex digest")
    try require(durationWithinTolerance, "evidence.measurements[\(index)] duration is outside tolerance")
    _ = try integer(measurement["chunkFrameCount"], "evidence.measurements[\(index)].chunkFrameCount")
    _ = try integer(measurement["peakWorkingPCMBytes"], "evidence.measurements[\(index)].peakWorkingPCMBytes")
    _ = try number(measurement["bytesPerMinute"], "evidence.measurements[\(index)].bytesPerMinute")
    return (minutes, bytes)
}

func validate(evidence: JSONObject, schema: JSONObject) throws {
    try require(try integer(evidence["schemaVersion"], "evidence.schemaVersion") == 1, "evidence schemaVersion must be 1")
    let candidate = try object(evidence["candidate"], "evidence.candidate")
    let candidateBitRate = try integer(candidate["bitRate"], "evidence.candidate.bitRate")
    try require(candidateBitRate == 96000, "evidence must use the configured 96 kbps candidate")
    try require(try integer(candidate["channels"], "evidence.candidate.channels") == 1, "evidence candidate must be mono")
    try require(try string(candidate["container"], "evidence.candidate.container") == "M4A", "evidence candidate must be M4A")
    try require(try string(candidate["codec"], "evidence.candidate.codec") == "AAC", "evidence candidate must be AAC")

    let rawMeasurements = evidence["measurements"] as? [Any] ?? []
    try require(rawMeasurements.count == 3, "evidence must contain exactly 5, 30, and 90 minute measurements")
    let measurements = try rawMeasurements.enumerated().map { try validateMeasurement($0.element, $0.offset) }
    try require(measurements.map(\.minutes) == [5, 30, 90], "evidence measurements must be ordered 5, 30, and 90 minutes")
    let measuredMaximum = measurements.map(\.bytes).max()!
    let measuredNinety = measurements[2].bytes
    try require(try integer(evidence["measuredMaximumEncodedByteSize"], "evidence.measuredMaximumEncodedByteSize") == measuredMaximum, "evidence measured maximum does not match measurements")
    try require(try integer(evidence["measuredNinetyMinuteEncodedByteSize"], "evidence.measuredNinetyMinuteEncodedByteSize") == measuredNinety, "evidence 90-minute measurement does not match measurements")
    try require(try integer(evidence["budgetSourceDurationMinutes"], "evidence.budgetSourceDurationMinutes") == 90, "budget source must be the 90-minute measurement")
    try require(try integer(evidence["budgetSourceEncodedByteSize"], "evidence.budgetSourceEncodedByteSize") == measuredNinety, "budget source bytes do not match the 90-minute measurement")

    let bitrateDuration = try number(evidence["configuredBitrateReferenceDurationMinutes"], "evidence.configuredBitrateReferenceDurationMinutes").doubleValue
    let bitrateReference = try integer(evidence["configuredBitrateReferenceBytes"], "evidence.configuredBitrateReferenceBytes")
    let expectedBitrateReference = Int64((Double(candidateBitRate) * bitrateDuration * 60.0 / 8.0).rounded())
    try require(bitrateDuration == 90, "configured bitrate reference must cover 90 minutes")
    try require(bitrateReference == expectedBitrateReference, "configured 96 kbps reference bytes are not reproducible")

    let multiplier = try number(evidence["budgetMultiplier"], "evidence.budgetMultiplier").doubleValue
    let roundingBoundary = try integer(evidence["budgetRoundingBoundaryBytes"], "evidence.budgetRoundingBoundaryBytes")
    try require(multiplier == 2 && roundingBoundary == 10_000_000, "budget safety multiplier or rounding boundary changed")
    let rawSafetyBytes = max(Int64(ceil(Double(measuredNinety) * multiplier)), bitrateReference)
    let derivedBudget = ((rawSafetyBytes + roundingBoundary - 1) / roundingBoundary) * roundingBoundary
    try require(derivedBudget == 80_000_000, "fresh evidence no longer derives the accepted 80,000,000-byte policy")
    try require(try integer(evidence["appOwnedPerRevisionBudgetBytes"], "evidence.appOwnedPerRevisionBudgetBytes") == derivedBudget, "evidence app-owned per-revision budget does not match the recomputed formula")
    try require(try string(evidence["budgetDerivation"], "evidence.budgetDerivation") == "ceil(max(budget-source encoded bytes * 2, configured 96 kbps 90-minute reference bytes) to next 10,000,000-byte boundary); app-owned budget only, not a CloudKit service limit", "evidence formula description is not the configured app-owned policy")

    let delayOfflineQuota = try object(schema["delayOfflineQuota"], "schema.delayOfflineQuota")
    let publicationBudget = try object(delayOfflineQuota["publicationBudget"], "schema.delayOfflineQuota.publicationBudget")
    let schemaPerRevision = try integer(publicationBudget["maxRevisionAssetBytes"], "schema.delayOfflineQuota.publicationBudget.maxRevisionAssetBytes")
    let schemaAggregate = try integer(publicationBudget["maxOwnedAssetBytes"], "schema.delayOfflineQuota.publicationBudget.maxOwnedAssetBytes")
    try require(schemaPerRevision == derivedBudget, "CloudKit schema maxRevisionAssetBytes does not match recomputed evidence policy")
    try require(schemaAggregate == 800_000_000 && schemaAggregate == derivedBudget * 10, "schema 800MB aggregate policy must equal 10x the per-revision app-owned policy")
    try require(try boolean(publicationBudget["isCloudKitLimit"], "publicationBudget.isCloudKitLimit") == false, "publication budget must not claim a CloudKit service limit")
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let defaultEvidence = root + "/contracts/audio/evidence/2026-08-17-audio-budget-sizing.json"
let defaultSchema = root + "/contracts/cloudkit/schema.json"
let evidencePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultEvidence
let schemaPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : defaultSchema

do {
    try validate(evidence: object(readJSON(evidencePath), "evidence"), schema: object(readJSON(schemaPath), "schema"))
    print("PASS audio budget evidence: 5/30/90-minute measurements derive 80,000,000 bytes per revision; schema aggregate is 10x app-owned policy (not a CloudKit service limit)")
} catch {
    fputs("FAIL audio budget evidence: \(error)\n", stderr)
    exit(1)
}
