#!/usr/bin/env swift

import Foundation

enum ValidationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

typealias JSONObject = [String: Any]

func fail(_ message: String) throws -> Never {
    throw ValidationError.invalid(message)
}

func object(_ value: Any?, _ path: String) throws -> JSONObject {
    guard let value = value as? JSONObject else { try fail("\(path) must be an object") }
    return value
}

func string(_ object: JSONObject, _ key: String, _ path: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        try fail("\(path).\(key) must be a non-empty string")
    }
    return value
}

func bool(_ object: JSONObject, _ key: String, _ path: String) throws -> Bool {
    guard let value = object[key] as? Bool else { try fail("\(path).\(key) must be a boolean") }
    return value
}

func number(_ object: JSONObject, _ key: String, _ path: String) throws -> Double {
    guard let value = object[key] as? NSNumber else { try fail("\(path).\(key) must be a number") }
    return value.doubleValue
}

func integer(_ object: JSONObject, _ key: String, _ path: String) throws -> Int {
    let value = try number(object, key, path)
    guard value.rounded() == value else { try fail("\(path).\(key) must be an integer") }
    return Int(value)
}

func stringArray(_ object: JSONObject, _ key: String, _ path: String) throws -> [String] {
    guard let values = object[key] as? [Any] else { try fail("\(path).\(key) must be an array") }
    return try values.enumerated().map { index, value in
        guard let value = value as? String, !value.isEmpty else {
            try fail("\(path).\(key)[\(index)] must be a non-empty string")
        }
        return value
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else { try fail("\(label): expected \(expected), got \(actual)") }
}

let timestampKeySuffixes = ["At", "Time"]
let timestampPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#)
let timestampFormatter = ISO8601DateFormatter()
timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let timestampFormatterWithoutFractions = ISO8601DateFormatter()
timestampFormatterWithoutFractions.formatOptions = [.withInternetDateTime]

func validateTimestamps(_ value: Any, path: String = "fixture") throws {
    if let object = value as? JSONObject {
        for key in object.keys.sorted() {
            let child = object[key]!
            if timestampKeySuffixes.contains(where: { key.hasSuffix($0) }), !(child is NSNull) {
                guard let timestamp = child as? String else { try fail("\(path).\(key) must be a timestamp string or null") }
                let range = NSRange(timestamp.startIndex..<timestamp.endIndex, in: timestamp)
                let shapeMatches = timestampPattern.firstMatch(in: timestamp, range: range) != nil
                let parses = timestampFormatter.date(from: timestamp) != nil || timestampFormatterWithoutFractions.date(from: timestamp) != nil
                guard shapeMatches && parses else { try fail("\(path).\(key) must be UTC ISO 8601 ending in Z") }
            }
            try validateTimestamps(child, path: "\(path).\(key)")
        }
    } else if let array = value as? [Any] {
        for (index, child) in array.enumerated() {
            try validateTimestamps(child, path: "\(path)[\(index)]")
        }
    }
}

func validatePlaybackState(_ state: JSONObject, path: String) throws {
    for key in ["itemID", "revisionID", "sessionID", "intent", "deviceID", "updatedAt"] {
        _ = try string(state, key, path)
    }
    let sequence = try integer(state, "sequence", path)
    let position = try number(state, "positionSeconds", path)
    let duration = try number(state, "durationSeconds", path)
    guard sequence >= 1 else { try fail("\(path).sequence must be positive") }
    guard position >= 0, duration > 0, position <= duration else { try fail("\(path) has invalid playback bounds") }
    _ = try bool(state, "completed", path)
    let intent = try string(state, "intent", path)
    guard ["progress", "rewind", "restart"].contains(intent) else { try fail("\(path).intent is unsupported") }
}

func executePublishDecode(input: JSONObject, expected: JSONObject) throws {
    let article = try object(input["article"], "input.article")
    let revision = try object(input["revision"], "input.revision")
    let itemID = try string(article, "itemID", "input.article")
    try assertEqual(try string(revision, "itemID", "input.revision"), itemID, "revision item identity")
    _ = try string(article, "canonicalURL", "input.article")
    _ = try string(article, "title", "input.article")
    _ = try string(article, "source", "input.article")
    _ = try string(article, "createdAt", "input.article")
    _ = try bool(article, "isDeleted", "input.article")
    _ = try string(revision, "revisionID", "input.revision")
    guard try number(revision, "durationSeconds", "input.revision") > 0 else { try fail("revision duration must be positive") }
    guard try integer(revision, "byteCount", "input.revision") > 0 else { try fail("revision byteCount must be positive") }
    _ = try string(revision, "contentHash", "input.revision")
    _ = try string(revision, "mediaType", "input.revision")
    _ = try string(revision, "createdAt", "input.revision")
    guard try integer(revision, "schemaVersion", "input.revision") > 0 else { try fail("revision schemaVersion must be positive") }
    let readiness = try string(revision, "readiness", "input.revision")

    try assertEqual(itemID, try string(expected, "itemID", "expected"), "decoded itemID")
    try assertEqual(try string(revision, "revisionID", "input.revision"), try string(expected, "revisionID", "expected"), "decoded revisionID")
    try assertEqual(article["author"] is NSNull, try bool(expected, "authorIsUnknown", "expected"), "unknown author")
    try assertEqual(article["publishedTime"] is NSNull, try bool(expected, "publishedTimeIsUnknown", "expected"), "unknown publication time")
    try assertEqual(readiness, try string(expected, "readiness", "expected"), "revision readiness")
}

func executePlaybackMerge(input: JSONObject, expected: JSONObject) throws {
    let current = try object(input["current"], "input.current")
    let incoming = try object(input["incoming"], "input.incoming")
    try validatePlaybackState(current, path: "input.current")
    try validatePlaybackState(incoming, path: "input.incoming")
    let changeTagMatches = try bool(input, "changeTagMatches", "input")

    let currentItem = try string(current, "itemID", "input.current")
    let incomingItem = try string(incoming, "itemID", "input.incoming")
    let currentRevision = try string(current, "revisionID", "input.current")
    let incomingRevision = try string(incoming, "revisionID", "input.incoming")
    let currentSession = try string(current, "sessionID", "input.current")
    let incomingSession = try string(incoming, "sessionID", "input.incoming")
    let intent = try string(incoming, "intent", "input.incoming")

    let result: (decision: String, winner: String, reason: String)
    if currentItem != incomingItem {
        result = ("reject", "current", "incompatibleItem")
    } else if currentRevision != incomingRevision {
        result = ("reject", "current", "incompatibleRevision")
    } else if intent == "rewind" || intent == "restart" {
        guard incomingSession != currentSession else { try fail("explicit \(intent) must create a new session ID") }
        guard changeTagMatches else { try fail("explicit \(intent) fixture must represent retry against the current change tag") }
        result = ("accept", "incoming", "explicitIntentNewSession")
    } else if incomingSession != currentSession {
        result = ("reject", "current", "staleOrdinaryProgressAcrossSessions")
    } else if try integer(incoming, "sequence", "input.incoming") <= integer(current, "sequence", "input.current") {
        result = ("reject", "current", "staleSequence")
    } else if try bool(current, "completed", "input.current") && !bool(incoming, "completed", "input.incoming") {
        result = ("reject", "current", "completionRequiresExplicitRestart")
    } else if try number(incoming, "positionSeconds", "input.incoming") < number(current, "positionSeconds", "input.current") {
        result = ("reject", "current", "ordinaryProgressMovedBackward")
    } else if !changeTagMatches {
        result = ("reject", "current", "staleChangeTag")
    } else {
        result = ("accept", "incoming", "forwardProgress")
    }

    try assertEqual(result.decision, try string(expected, "decision", "expected"), "merge decision")
    try assertEqual(result.winner, try string(expected, "winningState", "expected"), "merge winner")
    try assertEqual(result.reason, try string(expected, "reason", "expected"), "merge reason")
}

func executeRevisionSupersession(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "itemID", "input")
    let playingRevision = try string(input, "playingRevisionID", "input")
    let newRevision = try string(input, "newRevisionID", "input")
    guard playingRevision != newRevision else { try fail("supersession requires distinct immutable revisions") }
    let oldPosition = try number(input, "playingPositionSeconds", "input")
    let cached = try bool(input, "playingRevisionCached", "input")
    let selected = try bool(input, "newRevisionExplicitlySelected", "input")
    _ = try bool(input, "oldAssetRemovedRemotely", "input")
    _ = try string(input, "publishedAt", "input")

    let activeRevision = selected ? newRevision : playingRevision
    let activePosition = selected ? 0.0 : oldPosition
    try assertEqual(activeRevision, try string(expected, "activeRevisionID", "expected"), "active revision")
    try assertEqual(activePosition, try number(expected, "activePositionSeconds", "expected"), "active position")
    try assertEqual(cached && !selected, try bool(expected, "mayFinishCachedRevision", "expected"), "cached revision availability")
    try assertEqual(newRevision, try string(expected, "availableRevisionID", "expected"), "available revision")
    try assertEqual(false, try bool(expected, "translatedPosition", "expected"), "position translation")
    try assertEqual(0.0, try number(expected, "newRevisionStartSecondsOnSelection", "expected"), "new revision start")
}

func executeDeletionReconcile(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "generationID", "input")
    let complete = try bool(input, "fetchComplete", "input")
    let seen = Set(try stringArray(input, "seenRemoteItemIDs", "input"))
    guard let rawRecords = input["localRecords"] as? [Any], !rawRecords.isEmpty else {
        try fail("input.localRecords must be a non-empty array")
    }
    let allowedStatuses = Set(["remoteAcknowledged", "localOnly", "pendingUpload", "conflicted", "failedUpload"])
    var deleted: [String] = []
    var retained: [String] = []
    for (index, rawRecord) in rawRecords.enumerated() {
        let record = try object(rawRecord, "input.localRecords[\(index)]")
        let itemID = try string(record, "itemID", "input.localRecords[\(index)]")
        let status = try string(record, "syncStatus", "input.localRecords[\(index)]")
        guard allowedStatuses.contains(status) else { try fail("unsupported syncStatus \(status)") }
        if complete && status == "remoteAcknowledged" && !seen.contains(itemID) {
            deleted.append(itemID)
        } else {
            retained.append(itemID)
        }
    }
    deleted.sort()
    retained.sort()
    try assertEqual(deleted, try stringArray(expected, "deleteItemIDs", "expected").sorted(), "deleted item IDs")
    try assertEqual(retained, try stringArray(expected, "retainItemIDs", "expected").sorted(), "retained item IDs")
    try assertEqual(!deleted.isEmpty, try bool(expected, "mutated", "expected"), "deletion mutation")
}

func executeOfflineCache(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "itemID", "input")
    _ = try string(input, "revisionID", "input")
    let network = try bool(input, "networkAvailable", "input")
    let playable = try bool(input, "cachedFilePresent", "input") && bool(input, "cachedHashVerified", "input")
    _ = try string(input, "lastSyncedAt", "input")
    _ = try string(input, "checkedAt", "input")
    try assertEqual(playable, try bool(expected, "playable", "expected"), "offline playability")
    try assertEqual(!playable && !network, try bool(expected, "requiresNetwork", "expected"), "network requirement")
    let state = playable && !network ? "offlineCached" : (playable ? "cached" : "unavailable")
    try assertEqual(state, try string(expected, "state", "expected"), "offline state")
}

func executeDelayedDelivery(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "itemID", "input")
    _ = try string(input, "revisionID", "input")
    let cached = try bool(input, "cachedHashVerified", "input")
    let acknowledged = try bool(input, "uploadAcknowledged", "input")
    let remoteVisible = try bool(input, "remoteRevisionVisible", "input")
    _ = try string(input, "lastAttemptAt", "input")
    try assertEqual(cached, try bool(expected, "localPlayable", "expected"), "local playback during delay")
    try assertEqual(acknowledged && remoteVisible ? "delivered" : "pending", try string(expected, "deliveryState", "expected"), "delivery state")
    try assertEqual(remoteVisible, try bool(expected, "remotePlayable", "expected"), "remote playability")
    try assertEqual(false, try bool(expected, "immediateDeliveryPromised", "expected"), "immediate delivery promise")
}

func executeSchemaCompatibility(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "recordType", "input")
    let recordVersion = try integer(input, "recordSchemaVersion", "input")
    let supportedVersion = try integer(input, "supportedSchemaVersion", "input")
    _ = try string(input, "receivedAt", "input")
    let accepted = recordVersion <= supportedVersion
    try assertEqual(accepted, try bool(expected, "accepted", "expected"), "schema acceptance")
    try assertEqual(accepted ? "compatible" : "incompatibleSchema", try string(expected, "state", "expected"), "schema state")
}

func executePreparationFailure(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "itemID", "input")
    let priorRevision = try string(input, "priorRevisionID", "input")
    let candidateRevision = try string(input, "candidateRevisionID", "input")
    guard priorRevision != candidateRevision else { try fail("candidate revision must be immutable and distinct") }
    let priorReady = try bool(input, "priorRevisionReady", "input")
    let tempPresent = try bool(input, "candidateTempFilePresent", "input")
    let validated = try bool(input, "candidateValidated", "input")
    let moved = try bool(input, "candidateAtomicallyMoved", "input")
    _ = try string(input, "failureAt", "input")
    let published = validated && moved
    try assertEqual(priorRevision, try string(expected, "activeRevisionID", "expected"), "active revision after failure")
    try assertEqual(published, try bool(expected, "candidatePublished", "expected"), "candidate publication")
    try assertEqual(tempPresent && !published, try bool(expected, "removeCandidateTempFile", "expected"), "candidate temp cleanup")
    try assertEqual(priorReady && !published, try bool(expected, "priorRevisionPreserved", "expected"), "prior revision preservation")
}

func executeTimeoutTerminalError(input: JSONObject, expected: JSONObject) throws {
    _ = try string(input, "requestID", "input")
    let timeoutSeconds = try number(input, "timeoutSeconds", "input")
    let statusIntervalSeconds = try number(input, "statusIntervalSeconds", "input")
    guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 300 else {
        try fail("input.timeoutSeconds must be bounded to 0...300 seconds")
    }
    guard statusIntervalSeconds.isFinite, statusIntervalSeconds > 0, statusIntervalSeconds <= 5 else {
        try fail("input.statusIntervalSeconds must be within the 5-second maximum")
    }

    guard let rawEvents = input["events"] as? [Any], rawEvents.count >= 3 else {
        try fail("input.events must include an initial status, progress status, and terminal")
    }
    var terminalCount = 0
    var terminalOutcome = ""
    var terminalErrorCode = ""
    var terminalElapsed = 0.0
    var statusCount = 0
    var firstKind = ""
    var firstElapsed = 0.0
    var lastStatusElapsed = 0.0
    var previousElapsed = 0.0

    for (index, rawEvent) in rawEvents.enumerated() {
        let event = try object(rawEvent, "input.events[\(index)]")
        let kind = try string(event, "kind", "input.events[\(index)]")
        let elapsed = try number(event, "elapsedSeconds", "input.events[\(index)]")
        guard elapsed.isFinite, elapsed >= 0, elapsed >= previousElapsed else {
            try fail("input.events must be ordered by nondecreasing elapsedSeconds")
        }
        if index == 0 {
            firstKind = kind
            firstElapsed = elapsed
        }
        previousElapsed = elapsed

        switch kind {
        case "status":
            statusCount += 1
            guard elapsed - lastStatusElapsed <= statusIntervalSeconds else {
                try fail("input.events has a silent interval longer than statusIntervalSeconds")
            }
            lastStatusElapsed = elapsed
        case "terminal":
            terminalCount += 1
            let terminal = try object(event["terminal"], "input.events[\(index)].terminal")
            terminalOutcome = try string(terminal, "outcome", "input.events[\(index)].terminal")
            let error = try object(terminal["error"], "input.events[\(index)].terminal.error")
            terminalErrorCode = try string(error, "code", "input.events[\(index)].terminal.error")
            _ = try string(error, "message", "input.events[\(index)].terminal.error")
            _ = try bool(error, "retryable", "input.events[\(index)].terminal.error")
            terminalElapsed = elapsed
            guard terminalCount == 1 else { try fail("timeout operation must emit exactly one terminal event") }
        default:
            try fail("input.events[\(index)].kind is unsupported")
        }
    }

    guard firstKind == "status", firstElapsed == 0, statusCount >= 2 else {
        try fail("timeout operation must emit an initial status and a progress status")
    }
    guard terminalCount == 1, terminalElapsed == timeoutSeconds,
          terminalOutcome == "failed", terminalErrorCode == "timedOut",
          (try string(try object(rawEvents.last, "input.events.last"), "kind", "input.events.last")) == "terminal" else {
        try fail("timeout operation must end at its deadline with one failed timedOut terminal")
    }
    guard terminalElapsed - lastStatusElapsed <= statusIntervalSeconds else {
        try fail("timeout terminal follows a silent interval longer than statusIntervalSeconds")
    }

    let priorRevision = try string(input, "priorRevisionID", "input")
    let candidateRevision = try string(input, "candidateRevisionID", "input")
    guard priorRevision != candidateRevision else { try fail("timeout candidate revision must be distinct") }
    let priorReady = try bool(input, "priorRevisionReady", "input")
    let tempPresent = try bool(input, "candidateTempOutputPresent", "input")
    let validated = try bool(input, "candidateValidated", "input")
    let moved = try bool(input, "candidateAtomicallyMoved", "input")
    let published = validated && moved
    let removeTempOutput = tempPresent && !published
    let priorPreserved = priorReady && !published

    try assertEqual(terminalCount, try integer(expected, "terminalEventCount", "expected"), "terminal event count")
    try assertEqual(terminalOutcome, try string(expected, "terminalOutcome", "expected"), "terminal outcome")
    try assertEqual(terminalErrorCode, try string(expected, "terminalErrorCode", "expected"), "terminal error code")
    try assertEqual(firstKind == "status" && firstElapsed == 0, try bool(expected, "initialStatusEmitted", "expected"), "initial status")
    try assertEqual(statusIntervalSeconds <= 5 && terminalElapsed - lastStatusElapsed <= statusIntervalSeconds,
                    try bool(expected, "statusIntervalWithinMaximum", "expected"), "status interval")
    try assertEqual(published, try bool(expected, "candidatePublished", "expected"), "candidate publication")
    try assertEqual(removeTempOutput, try bool(expected, "removeCandidateTempOutput", "expected"), "candidate temp cleanup")
    try assertEqual(priorPreserved, try bool(expected, "priorRevisionPreserved", "expected"), "prior revision preservation")
    try assertEqual(priorRevision, try string(expected, "activeRevisionID", "expected"), "active revision")
}

func executeFixture(_ fixture: JSONObject) throws -> String {
    guard try integer(fixture, "fixtureVersion", "fixture") == 1 else { try fail("fixture.fixtureVersion must equal 1") }
    let caseID = try string(fixture, "caseID", "fixture")
    let operation = try string(fixture, "operation", "fixture")
    _ = try string(fixture, "description", "fixture")
    let input = try object(fixture["input"], "fixture.input")
    let expected = try object(fixture["expected"], "fixture.expected")
    guard !input.isEmpty, !expected.isEmpty else { try fail("fixture input and expected must be non-empty") }
    try validateTimestamps(fixture)

    switch operation {
    case "publishDecode": try executePublishDecode(input: input, expected: expected)
    case "playbackMerge": try executePlaybackMerge(input: input, expected: expected)
    case "revisionSupersession": try executeRevisionSupersession(input: input, expected: expected)
    case "deletionReconcile": try executeDeletionReconcile(input: input, expected: expected)
    case "offlineCache": try executeOfflineCache(input: input, expected: expected)
    case "delayedDelivery": try executeDelayedDelivery(input: input, expected: expected)
    case "schemaCompatibility": try executeSchemaCompatibility(input: input, expected: expected)
    case "preparationFailure": try executePreparationFailure(input: input, expected: expected)
    case "timeoutTerminalError": try executeTimeoutTerminalError(input: input, expected: expected)
    default: try fail("unknown operation \(operation)")
    }
    return caseID
}

let fixtureDirectory = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : "contracts/fixtures"
let fileManager = FileManager.default
var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: fixtureDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
    fputs("error: fixture directory not found: \(fixtureDirectory)\n", stderr)
    exit(2)
}

let directoryURL = URL(fileURLWithPath: fixtureDirectory)
guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
    fputs("error: cannot enumerate fixture directory: \(fixtureDirectory)\n", stderr)
    exit(2)
}
let fixtureURLs = enumerator.compactMap { $0 as? URL }
    .filter { $0.pathExtension.lowercased() == "json" }
    .sorted { $0.path < $1.path }

guard !fixtureURLs.isEmpty else {
    fputs("error: zero JSON fixtures discovered in \(fixtureDirectory)\n", stderr)
    exit(2)
}

var caseIDs = Set<String>()
var failures: [String] = []
for url in fixtureURLs {
    do {
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data)
        let fixture = try object(raw, url.lastPathComponent)
        let caseID = try executeFixture(fixture)
        guard caseIDs.insert(caseID).inserted else { try fail("duplicate caseID \(caseID)") }
        print("PASS \(url.lastPathComponent): \(caseID)")
    } catch {
        failures.append("\(url.lastPathComponent): \(error)")
    }
}

if !failures.isEmpty {
    for failure in failures { fputs("FAIL \(failure)\n", stderr) }
    fputs("error: \(failures.count) of \(fixtureURLs.count) fixture cases failed\n", stderr)
    exit(1)
}

guard caseIDs.count > 0 else {
    fputs("error: validator executed zero fixture cases\n", stderr)
    exit(2)
}
print("Validated \(caseIDs.count) fixture cases")
