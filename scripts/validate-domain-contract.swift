#!/usr/bin/env swift

import Foundation

enum ContractError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let message) = self { return message }; return "invalid contract" }
}

typealias JSON = [String: Any]

func fail(_ message: String) throws -> Never { throw ContractError.invalid(message) }
func object(_ value: Any?, _ path: String) throws -> JSON {
    guard let value = value as? JSON else { try fail("\(path) must be an object") }
    return value
}
func nonEmptyString(_ value: Any?, _ path: String) throws -> String {
    guard let value = value as? String, !value.isEmpty else { try fail("\(path) must be a non-empty string") }
    return value
}
func bool(_ value: Any?, _ path: String) throws -> Bool {
    guard let value = value as? NSNumber, String(cString: value.objCType) == "c" else { try fail("\(path) must be a boolean") }
    return value.boolValue
}
func number(_ value: Any?, _ path: String) throws -> Double {
    guard let value = value as? NSNumber, String(cString: value.objCType) != "c" else { try fail("\(path) must be a number") }
    return value.doubleValue
}
func integer(_ value: Any?, _ path: String) throws -> Int {
    let value = try number(value, path)
    guard value.isFinite, value.rounded() == value else { try fail("\(path) must be an integer") }
    return Int(value)
}
func stringArray(_ value: Any?, _ path: String) throws -> [String] {
    guard let values = value as? [Any] else { try fail("\(path) must be an array") }
    return try values.enumerated().map { try nonEmptyString($0.element, "\(path)[\($0.offset)]") }
}
func exactKeys(_ value: JSON, _ expected: Set<String>, _ path: String) throws {
    let actual = Set(value.keys)
    guard actual == expected else {
        let missing = expected.subtracting(actual).sorted().joined(separator: ",")
        let extra = actual.subtracting(expected).sorted().joined(separator: ",")
        try fail("\(path) keys mismatch; missing=[\(missing)] extra=[\(extra)]")
    }
}
func oneOf(_ value: String, _ values: Set<String>, _ path: String) throws {
    guard values.contains(value) else { try fail("\(path) unsupported value \(value)") }
}
func nullableString(_ value: Any?, _ path: String) throws {
    if value is NSNull { return }
    _ = try nonEmptyString(value, path)
}

let timestampPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#)
let timestampFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
let timestampFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()
func validateTimestamps(_ value: Any, _ path: String = "fixture") throws {
    if let value = value as? JSON {
        for key in value.keys.sorted() {
            let child = value[key]!
            if (key.hasSuffix("At") || key.hasSuffix("Time")) && !(child is NSNull) {
                let timestamp = try nonEmptyString(child, "\(path).\(key)")
                let range = NSRange(timestamp.startIndex..<timestamp.endIndex, in: timestamp)
                guard timestampPattern.firstMatch(in: timestamp, range: range) != nil,
                      timestampFormatter.date(from: timestamp) != nil || timestampFormatterNoFraction.date(from: timestamp) != nil else {
                    try fail("\(path).\(key) must be UTC ISO 8601 ending in Z")
                }
            }
            try validateTimestamps(child, "\(path).\(key)")
        }
    } else if let values = value as? [Any] {
        for (index, child) in values.enumerated() { try validateTimestamps(child, "\(path)[\(index)]") }
    }
}

let expectedTypeNames: Set<String> = [
    "ItemID", "RevisionID", "Timestamp", "Article", "AudioRevision", "RevisionReadiness", "PlaybackIntent", "PlaybackState",
    "PreparationStage", "PreparationOutcome", "PreparationTerminalResult", "PreparationStatus", "ArticleRequest", "SpeechRequest",
    "ExtractionEvent", "SpeechEvent", "ProducerError", "ExtractionTerminal", "SpeechTerminal"
]
let primitiveTypes: Set<String> = ["string", "boolean", "number", "integer", "object"]
let expectedObjectFields: [String: Set<String>] = [
    "Article": ["itemID", "canonicalURL", "title", "source", "author", "publishedTime", "createdAt", "isDeleted"],
    "AudioRevision": ["itemID", "revisionID", "durationSeconds", "byteCount", "contentHash", "mediaType", "createdAt", "schemaVersion", "readiness"],
    "PlaybackState": ["itemID", "revisionID", "sessionID", "sequence", "positionSeconds", "durationSeconds", "completed", "intent", "deviceID", "encodedCloudKitRecordSystemFields", "updatedAt"],
    "PreparationTerminalResult": ["outcome", "revisionID", "error"],
    "PreparationStatus": ["stage", "detail", "fraction", "cancellable", "terminal", "terminalResult", "emittedAt"],
    "ArticleRequest": ["requestID", "sourceURL", "timeoutSeconds", "statusIntervalSeconds"],
    "SpeechRequest": ["requestID", "itemID", "extractedText", "voiceID", "synthesisSettings", "audioFormat", "timeoutSeconds", "statusIntervalSeconds"],
    "ExtractionEvent": ["requestID", "sequence", "emittedAt", "kind", "stage", "detail", "fraction", "article", "terminal"],
    "SpeechEvent": ["requestID", "sequence", "emittedAt", "kind", "stage", "detail", "fraction", "audioChunkBase64", "terminal"],
    "ProducerError": ["code", "message", "retryable", "stage", "underlyingCode"],
    "ExtractionTerminal": ["requestID", "sequence", "emittedAt", "outcome", "article", "error"],
    "SpeechTerminal": ["requestID", "sequence", "emittedAt", "outcome", "error"]
]

func validateTaggedStream(_ type: JSON, _ typeName: String, terminalType: String, dataPayload: String) throws {
    let fields = try object(type["fields"], "schema.types.\(typeName).fields")
    let kind = try object(fields["kind"], "schema.types.\(typeName).fields.kind")
    guard try bool(kind["required"], "schema.types.\(typeName).fields.kind.required") else { try fail("\(typeName).kind must be required") }
    let kindConstraints = try object(kind["constraints"], "schema.types.\(typeName).fields.kind.constraints")
    let kinds = try stringArray(kindConstraints["enum"], "schema.types.\(typeName).fields.kind.constraints.enum")
    guard kinds == ["status", "data", "terminal"] else { try fail("\(typeName).kind must be the status/data/terminal tag") }
    let terminal = try object(fields["terminal"], "schema.types.\(typeName).fields.terminal")
    guard try nonEmptyString(terminal["type"], "schema.types.\(typeName).fields.terminal.type") == terminalType,
          try bool(terminal["required"], "schema.types.\(typeName).fields.terminal.required") == false,
          try bool(terminal["nullable"], "schema.types.\(typeName).fields.terminal.nullable") == true else {
        try fail("\(typeName).terminal must be optional nullable \(terminalType)")
    }
    let stream = try object(type["stream"], "schema.types.\(typeName).stream")
    try exactKeys(stream, ["tag", "terminalCount", "variants"], "schema.types.\(typeName).stream")
    try oneOf(try nonEmptyString(stream["tag"], "schema.types.\(typeName).stream.tag"), ["kind"], "schema.types.\(typeName).stream.tag")
    try oneOf(try nonEmptyString(stream["terminalCount"], "schema.types.\(typeName).stream.terminalCount"), ["exactlyOne"], "schema.types.\(typeName).stream.terminalCount")
    let variants = try object(stream["variants"], "schema.types.\(typeName).stream.variants")
    try exactKeys(variants, ["status", "data", "terminal"], "schema.types.\(typeName).stream.variants")
    let expectedRequired: [String: Set<String>] = ["status": [], "data": [dataPayload], "terminal": ["terminal"]]
    let expectedForbidden: [String: Set<String>] = ["status": [dataPayload, "terminal"], "data": ["terminal"], "terminal": [dataPayload]]
    for variant in ["status", "data", "terminal"] {
        let definition = try object(variants[variant], "schema.types.\(typeName).stream.variants.\(variant)")
        try exactKeys(definition, ["requiredPayload", "forbiddenPayload"], "schema.types.\(typeName).stream.variants.\(variant)")
        let required = Set(try stringArray(definition["requiredPayload"], "schema.types.\(typeName).stream.variants.\(variant).requiredPayload"))
        let forbidden = Set(try stringArray(definition["forbiddenPayload"], "schema.types.\(typeName).stream.variants.\(variant).forbiddenPayload"))
        guard required == expectedRequired[variant]!, forbidden == expectedForbidden[variant]!, required.isDisjoint(with: forbidden) else {
            try fail("\(typeName).stream variant \(variant) payload rule is invalid")
        }
    }
}

func validateFieldDefinition(_ field: JSON, _ path: String, typeNames: Set<String>) throws {
    let allowed: Set<String> = ["type", "required", "nullable", "constraints"]
    try exactKeys(field, allowed.intersection(Set(field.keys)).union(["type", "required", "nullable"]), path)
    let type = try nonEmptyString(field["type"], "\(path).type")
    guard primitiveTypes.contains(type) || typeNames.contains(type) else { try fail("\(path).type references unknown type \(type)") }
    _ = try bool(field["required"], "\(path).required")
    _ = try bool(field["nullable"], "\(path).nullable")
    if let constraints = field["constraints"] {
        let constraintsObject = try object(constraints, "\(path).constraints")
        try exactKeys(constraintsObject, Set(["pattern", "maxLength", "minLength", "greaterThan", "greaterThanOrEqual", "minimum", "maximum", "maximumConfig", "format", "scheme", "encoding", "enum"]).intersection(Set(constraintsObject.keys)), "\(path).constraints")
    }
}

func validateSchema(_ schema: JSON) throws -> (JSON, JSON) {
    try exactKeys(schema, ["contractName", "contractVersion", "serialization", "config", "types", "transitions", "merge", "rpc", "progressTimeoutCancellation", "fixtureCoverage"], "schema")
    _ = try nonEmptyString(schema["contractName"], "schema.contractName")
    guard try integer(schema["contractVersion"], "schema.contractVersion") == 1 else { try fail("schema.contractVersion must be 1") }

    let serialization = try object(schema["serialization"], "schema.serialization")
    try exactKeys(serialization, ["dateTime", "dateTimePattern", "unknownOptionalMetadata"], "schema.serialization")
    try oneOf(try nonEmptyString(serialization["dateTime"], "schema.serialization.dateTime"), ["UTC ISO 8601"], "schema.serialization.dateTime")
    try oneOf(try nonEmptyString(serialization["unknownOptionalMetadata"], "schema.serialization.unknownOptionalMetadata"), ["null-or-absent-is-unknown-and-must-not-be-invented"], "schema.serialization.unknownOptionalMetadata")

    let config = try object(schema["config"], "schema.config")
    try exactKeys(config, ["noSilentWaitMaximumStatusIntervalSeconds", "defaultOperationTimeoutSeconds", "cancellationGracePeriodSeconds"], "schema.config")
    guard try number(config["noSilentWaitMaximumStatusIntervalSeconds"], "schema.config.noSilentWaitMaximumStatusIntervalSeconds") > 0 else { try fail("status interval must be positive") }
    guard try number(config["defaultOperationTimeoutSeconds"], "schema.config.defaultOperationTimeoutSeconds") > 0 else { try fail("timeout must be positive") }
    guard try number(config["cancellationGracePeriodSeconds"], "schema.config.cancellationGracePeriodSeconds") > 0 else { try fail("cancellation grace must be positive") }

    let types = try object(schema["types"], "schema.types")
    guard Set(types.keys) == expectedTypeNames else { try fail("schema.types must declare exactly the frozen type set") }
    for typeName in expectedTypeNames {
        let type = try object(types[typeName], "schema.types.\(typeName)")
        let kind = try nonEmptyString(type["kind"], "schema.types.\(typeName).kind")
        _ = try bool(type["required"], "schema.types.\(typeName).required")
        _ = try bool(type["nullable"], "schema.types.\(typeName).nullable")
        switch kind {
        case "object":
            let allowed: Set<String> = ["kind", "required", "nullable", "fields", "conditions", "durabilityRule", "mergeRule", "persistenceRule", "streamRule", "stream"]
            try exactKeys(type, allowed.intersection(Set(type.keys)).union(["kind", "required", "nullable", "fields"]), "schema.types.\(typeName)")
            let fields = try object(type["fields"], "schema.types.\(typeName).fields")
            guard !fields.isEmpty else { try fail("schema.types.\(typeName).fields must not be empty") }
            if let expectedFields = expectedObjectFields[typeName] {
                guard Set(fields.keys) == expectedFields else { try fail("schema.types.\(typeName).fields must match the frozen field set") }
            }
            for fieldName in fields.keys.sorted() { try validateFieldDefinition(try object(fields[fieldName], "schema.types.\(typeName).fields.\(fieldName)"), "schema.types.\(typeName).fields.\(fieldName)", typeNames: expectedTypeNames) }
        case "enum":
            try exactKeys(type, ["kind", "required", "nullable", "values"], "schema.types.\(typeName)")
            let values = try stringArray(type["values"], "schema.types.\(typeName).values")
            guard Set(values).count == values.count else { try fail("schema.types.\(typeName).values contains duplicates") }
        case "string":
            let allowed: Set<String> = ["kind", "required", "nullable", "constraints", "identity"]
            try exactKeys(type, allowed.intersection(Set(type.keys)).union(["kind", "required", "nullable"]), "schema.types.\(typeName)")
            _ = try object(type["constraints"], "schema.types.\(typeName).constraints")
            if let identity = type["identity"] {
                let identityObject = try object(identity, "schema.types.\(typeName).identity")
                try exactKeys(identityObject, ["algorithm", "encoding", "prefix", "inputs", "canonicalization"], "schema.types.\(typeName).identity")
                _ = try nonEmptyString(identityObject["algorithm"], "schema.types.\(typeName).identity.algorithm")
                _ = try nonEmptyString(identityObject["encoding"], "schema.types.\(typeName).identity.encoding")
                _ = try nonEmptyString(identityObject["prefix"], "schema.types.\(typeName).identity.prefix")
                _ = try stringArray(identityObject["inputs"], "schema.types.\(typeName).identity.inputs")
                _ = try nonEmptyString(identityObject["canonicalization"], "schema.types.\(typeName).identity.canonicalization")
            }
        default:
            try fail("schema.types.\(typeName).kind unsupported: \(kind)")
        }
    }
    let revisionReadinessType = try object(types["RevisionReadiness"], "schema.types.RevisionReadiness")
    guard try stringArray(revisionReadinessType["values"], "schema.types.RevisionReadiness.values") == ["ready"] else {
        try fail("AudioRevision readiness is immutable and must be ready only")
    }
    let preparationStageType = try object(types["PreparationStage"], "schema.types.PreparationStage")
    let expectedPreparationStages = Set(["preparing", "fetching", "extracting", "synthesizing", "assembling", "saving", "completed", "failed", "cancelled"])
    guard Set(try stringArray(preparationStageType["values"], "schema.types.PreparationStage.values")) == expectedPreparationStages else {
        try fail("PreparationStatus must own preparing, failed, and cancelled stages")
    }
    try validateTaggedStream(try object(types["ExtractionEvent"], "schema.types.ExtractionEvent"), "ExtractionEvent", terminalType: "ExtractionTerminal", dataPayload: "article")
    try validateTaggedStream(try object(types["SpeechEvent"], "schema.types.SpeechEvent"), "SpeechEvent", terminalType: "SpeechTerminal", dataPayload: "audioChunkBase64")

    let transitions = try object(schema["transitions"], "schema.transitions")
    try exactKeys(transitions, ["AudioRevision.readiness"], "schema.transitions")
    let readiness = try object(transitions["AudioRevision.readiness"], "schema.transitions.AudioRevision.readiness")
    try exactKeys(readiness, ["allowed", "immutableFields", "publicationRule"], "schema.transitions.AudioRevision.readiness")
    let allowedTransitions = try object(readiness["allowed"], "schema.transitions.AudioRevision.readiness.allowed")
    let readinessValues = Set(["ready"])
    guard Set(allowedTransitions.keys) == readinessValues else { try fail("readiness transition states are incomplete") }
    for value in readinessValues { _ = try stringArray(allowedTransitions[value], "schema.transitions.AudioRevision.readiness.allowed.\(value)") }
    _ = try stringArray(readiness["immutableFields"], "schema.transitions.AudioRevision.readiness.immutableFields")
    _ = try nonEmptyString(readiness["publicationRule"], "schema.transitions.AudioRevision.readiness.publicationRule")

    let playbackFields = try object(try object(types["PlaybackState"], "schema.types.PlaybackState")["fields"], "schema.types.PlaybackState.fields")
    let cloudKitFields = try object(playbackFields["encodedCloudKitRecordSystemFields"], "schema.types.PlaybackState.fields.encodedCloudKitRecordSystemFields")
    guard try bool(cloudKitFields["required"], "schema.types.PlaybackState.fields.encodedCloudKitRecordSystemFields.required") == false,
          try bool(cloudKitFields["nullable"], "schema.types.PlaybackState.fields.encodedCloudKitRecordSystemFields.nullable") == true else {
        try fail("encoded CloudKit system fields must be optional and nullable for create")
    }
    let persistenceRule = try object(try object(types["PlaybackState"], "schema.types.PlaybackState")["persistenceRule"], "schema.types.PlaybackState.persistenceRule")
    try exactKeys(persistenceRule, ["field", "create", "updateDeleteConflictSave"], "schema.types.PlaybackState.persistenceRule")
    guard try nonEmptyString(persistenceRule["field"], "schema.types.PlaybackState.persistenceRule.field") == "encodedCloudKitRecordSystemFields" else { try fail("playback persistence rule names the wrong causal field") }
    let createRule = try object(persistenceRule["create"], "schema.types.PlaybackState.persistenceRule.create")
    let updateRule = try object(persistenceRule["updateDeleteConflictSave"], "schema.types.PlaybackState.persistenceRule.updateDeleteConflictSave")
    try exactKeys(createRule, ["required", "nullable"], "schema.types.PlaybackState.persistenceRule.create")
    try exactKeys(updateRule, ["required", "nullable"], "schema.types.PlaybackState.persistenceRule.updateDeleteConflictSave")
    guard try bool(createRule["required"], "schema.types.PlaybackState.persistenceRule.create.required") == false,
          try bool(createRule["nullable"], "schema.types.PlaybackState.persistenceRule.create.nullable") == true,
          try bool(updateRule["required"], "schema.types.PlaybackState.persistenceRule.updateDeleteConflictSave.required") == true,
          try bool(updateRule["nullable"], "schema.types.PlaybackState.persistenceRule.updateDeleteConflictSave.nullable") == false else {
        try fail("playback persistence rule must distinguish create from update/delete saves")
    }

    let merge = try object(schema["merge"], "schema.merge")
    try exactKeys(merge, ["canonicalRecord", "causalBoundary", "rules"], "schema.merge")
    _ = try nonEmptyString(merge["canonicalRecord"], "schema.merge.canonicalRecord")
    _ = try nonEmptyString(merge["causalBoundary"], "schema.merge.causalBoundary")
    guard (try stringArray(merge["rules"], "schema.merge.rules")).count >= 7 else { try fail("merge rules are incomplete") }

    let rpc = try object(schema["rpc"], "schema.rpc")
    try exactKeys(rpc, ["ArticleExtracting", "SpeechProducing"], "schema.rpc")
    for name in ["ArticleExtracting", "SpeechProducing"] {
        let entry = try object(rpc[name], "schema.rpc.\(name)")
        try exactKeys(entry, ["requestType", "eventType", "terminalType", "errorType", "signature", "cancellation"], "schema.rpc.\(name)")
        for key in ["requestType", "eventType", "terminalType", "errorType"] { guard expectedTypeNames.contains(try nonEmptyString(entry[key], "schema.rpc.\(name).\(key)")) else { try fail("schema.rpc.\(name).\(key) references unknown type") } }
        let eventType = try nonEmptyString(entry["eventType"], "schema.rpc.\(name).eventType")
        let terminalType = try nonEmptyString(entry["terminalType"], "schema.rpc.\(name).terminalType")
        let signature = try nonEmptyString(entry["signature"], "schema.rpc.\(name).signature")
        guard signature.contains("AsyncThrowingStream<\(eventType), ProducerError>"),
              (name == "ArticleExtracting" ? eventType == "ExtractionEvent" && terminalType == "ExtractionTerminal" : eventType == "SpeechEvent" && terminalType == "SpeechTerminal") else {
            try fail("schema.rpc.\(name) signature must stream its tagged event with its terminal type")
        }
        _ = try nonEmptyString(entry["cancellation"], "schema.rpc.\(name).cancellation")
    }

    let progress = try object(schema["progressTimeoutCancellation"], "schema.progressTimeoutCancellation")
    try exactKeys(progress, ["statusRule", "timeoutRule", "cancellationRule", "terminalRule"], "schema.progressTimeoutCancellation")
    for key in ["statusRule", "timeoutRule", "cancellationRule", "terminalRule"] { _ = try nonEmptyString(progress[key], "schema.progressTimeoutCancellation.\(key)") }

    let coverage = try object(schema["fixtureCoverage"], "schema.fixtureCoverage")
    try exactKeys(coverage, ["fixtureVersion", "requiredCases"], "schema.fixtureCoverage")
    guard try integer(coverage["fixtureVersion"], "schema.fixtureCoverage.fixtureVersion") == 1 else { try fail("fixture coverage version must be 1") }
    guard let cases = coverage["requiredCases"] as? [Any], cases.count == 16 else { try fail("fixture coverage must list exactly 16 cases") }
    var seen = Set<String>()
    for (index, raw) in cases.enumerated() {
        let entry = try object(raw, "schema.fixtureCoverage.requiredCases[\(index)]")
        try exactKeys(entry, ["caseID", "operation"], "schema.fixtureCoverage.requiredCases[\(index)]")
        let caseID = try nonEmptyString(entry["caseID"], "schema.fixtureCoverage.requiredCases[\(index)].caseID")
        guard seen.insert(caseID).inserted else { try fail("duplicate fixture coverage caseID \(caseID)") }
        _ = try nonEmptyString(entry["operation"], "schema.fixtureCoverage.requiredCases[\(index)].operation")
    }
    return (config, coverage)
}

func validateID(_ value: Any?, _ path: String) throws { _ = try nonEmptyString(value, path) }
func validateTimestamp(_ value: Any?, _ path: String) throws { let s = try nonEmptyString(value, path); guard s.last == "Z" else { try fail("\(path) must end in Z") } }

func validateFixturePlaybackState(_ state: JSON, _ path: String) throws {
    try exactKeys(state, ["itemID", "revisionID", "sessionID", "sequence", "positionSeconds", "durationSeconds", "completed", "intent", "deviceID", "updatedAt"], path)
    for key in ["itemID", "revisionID", "sessionID", "deviceID"] { try validateID(state[key], "\(path).\(key)") }
    guard try integer(state["sequence"], "\(path).sequence") >= 1 else { try fail("\(path).sequence must be >= 1") }
    let position = try number(state["positionSeconds"], "\(path).positionSeconds")
    let duration = try number(state["durationSeconds"], "\(path).durationSeconds")
    guard duration > 0, position >= 0, position <= duration else { try fail("\(path) playback bounds invalid") }
    _ = try bool(state["completed"], "\(path).completed")
    try oneOf(try nonEmptyString(state["intent"], "\(path).intent"), ["progress", "rewind", "restart"], "\(path).intent")
    try validateTimestamp(state["updatedAt"], "\(path).updatedAt")
}

func validateFixture(_ fixture: JSON, _ path: String) throws -> (String, String) {
    try exactKeys(fixture, ["fixtureVersion", "caseID", "operation", "description", "input", "expected"], path)
    guard try integer(fixture["fixtureVersion"], "\(path).fixtureVersion") == 1 else { try fail("\(path).fixtureVersion must be 1") }
    let caseID = try nonEmptyString(fixture["caseID"], "\(path).caseID")
    let operation = try nonEmptyString(fixture["operation"], "\(path).operation")
    _ = try nonEmptyString(fixture["description"], "\(path).description")
    let input = try object(fixture["input"], "\(path).input")
    let expected = try object(fixture["expected"], "\(path).expected")
    try validateTimestamps(fixture)

    switch operation {
    case "publishDecode":
        try exactKeys(input, ["article", "revision"], "\(path).input")
        let article = try object(input["article"], "\(path).input.article")
        try exactKeys(article, ["itemID", "canonicalURL", "title", "source", "author", "publishedTime", "createdAt", "isDeleted"], "\(path).input.article")
        for key in ["itemID", "canonicalURL", "title", "source", "createdAt"] { try validateID(article[key], "\(path).input.article.\(key)") }
        try nullableString(article["author"], "\(path).input.article.author"); try nullableString(article["publishedTime"], "\(path).input.article.publishedTime")
        _ = try bool(article["isDeleted"], "\(path).input.article.isDeleted")
        let revision = try object(input["revision"], "\(path).input.revision")
        try exactKeys(revision, ["itemID", "revisionID", "durationSeconds", "byteCount", "contentHash", "mediaType", "createdAt", "schemaVersion", "readiness"], "\(path).input.revision")
        try validateID(revision["itemID"], "\(path).input.revision.itemID"); try validateID(revision["revisionID"], "\(path).input.revision.revisionID")
        guard try number(revision["durationSeconds"], "\(path).input.revision.durationSeconds") > 0, try integer(revision["byteCount"], "\(path).input.revision.byteCount") > 0 else { try fail("\(path).input.revision dimensions invalid") }
        try validateID(revision["contentHash"], "\(path).input.revision.contentHash"); try validateID(revision["mediaType"], "\(path).input.revision.mediaType"); try validateTimestamp(revision["createdAt"], "\(path).input.revision.createdAt")
        guard try integer(revision["schemaVersion"], "\(path).input.revision.schemaVersion") > 0 else { try fail("schemaVersion must be positive") }
        try oneOf(try nonEmptyString(revision["readiness"], "\(path).input.revision.readiness"), ["ready"], "\(path).input.revision.readiness")
        try exactKeys(expected, ["itemID", "revisionID", "authorIsUnknown", "publishedTimeIsUnknown", "readiness"], "\(path).expected")
    case "playbackMerge":
        try exactKeys(input, ["changeTagMatches", "current", "incoming"], "\(path).input"); _ = try bool(input["changeTagMatches"], "\(path).input.changeTagMatches")
        try validateFixturePlaybackState(try object(input["current"], "\(path).input.current"), "\(path).input.current")
        try validateFixturePlaybackState(try object(input["incoming"], "\(path).input.incoming"), "\(path).input.incoming")
        try exactKeys(expected, ["decision", "winningState", "reason"], "\(path).expected")
        try oneOf(try nonEmptyString(expected["decision"], "\(path).expected.decision"), ["accept", "reject"], "\(path).expected.decision")
        try oneOf(try nonEmptyString(expected["winningState"], "\(path).expected.winningState"), ["current", "incoming"], "\(path).expected.winningState")
        try oneOf(try nonEmptyString(expected["reason"], "\(path).expected.reason"), ["forwardProgress", "explicitIntentNewSession", "staleOrdinaryProgressAcrossSessions", "staleSequence", "incompatibleRevision", "incompatibleItem", "completionRequiresExplicitRestart", "ordinaryProgressMovedBackward", "staleChangeTag"], "\(path).expected.reason")
    case "revisionSupersession":
        try exactKeys(input, ["itemID", "playingRevisionID", "playingPositionSeconds", "playingRevisionCached", "newRevisionID", "oldAssetRemovedRemotely", "newRevisionExplicitlySelected", "publishedAt"], "\(path).input")
        for key in ["itemID", "playingRevisionID", "newRevisionID"] { try validateID(input[key], "\(path).input.\(key)") }
        guard try number(input["playingPositionSeconds"], "\(path).input.playingPositionSeconds") >= 0 else { try fail("playing position must be nonnegative") }
        for key in ["playingRevisionCached", "oldAssetRemovedRemotely", "newRevisionExplicitlySelected"] { _ = try bool(input[key], "\(path).input.\(key)") }
        try validateTimestamp(input["publishedAt"], "\(path).input.publishedAt")
        try exactKeys(expected, ["activeRevisionID", "activePositionSeconds", "mayFinishCachedRevision", "availableRevisionID", "translatedPosition", "newRevisionStartSecondsOnSelection"], "\(path).expected")
    case "deletionReconcile":
        let deletionKeys = Set(["generationID", "fetchComplete", "seenRemoteItemIDs", "localRecords"]).union(Set(input.keys.contains("completedAt") ? ["completedAt"] : ["failedAt"]))
        try exactKeys(input, deletionKeys, "\(path).input")
        try validateID(input["generationID"], "\(path).input.generationID"); _ = try bool(input["fetchComplete"], "\(path).input.fetchComplete"); _ = try stringArray(input["seenRemoteItemIDs"], "\(path).input.seenRemoteItemIDs")
        guard let records = input["localRecords"] as? [Any], !records.isEmpty else { try fail("\(path).input.localRecords must be nonempty") }
        for (index, raw) in records.enumerated() { let record = try object(raw, "\(path).input.localRecords[\(index)]"); try exactKeys(record, ["itemID", "syncStatus"], "\(path).input.localRecords[\(index)]"); try validateID(record["itemID"], "\(path).input.localRecords[\(index)].itemID"); try oneOf(try nonEmptyString(record["syncStatus"], "\(path).input.localRecords[\(index)].syncStatus"), ["remoteAcknowledged", "localOnly", "pendingUpload", "conflicted", "failedUpload"], "syncStatus") }
        if let value = input["completedAt"] ?? input["failedAt"] { try validateTimestamp(value, "\(path).input.completion") }
        try exactKeys(expected, ["deleteItemIDs", "retainItemIDs", "mutated"], "\(path).expected"); _ = try stringArray(expected["deleteItemIDs"], "\(path).expected.deleteItemIDs"); _ = try stringArray(expected["retainItemIDs"], "\(path).expected.retainItemIDs"); _ = try bool(expected["mutated"], "\(path).expected.mutated")
    case "offlineCache":
        try exactKeys(input, ["itemID", "revisionID", "networkAvailable", "cachedFilePresent", "cachedHashVerified", "lastSyncedAt", "checkedAt"], "\(path).input"); try validateID(input["itemID"], "\(path).input.itemID"); try validateID(input["revisionID"], "\(path).input.revisionID"); for key in ["networkAvailable", "cachedFilePresent", "cachedHashVerified"] { _ = try bool(input[key], "\(path).input.\(key)") }; try validateTimestamp(input["lastSyncedAt"], "\(path).input.lastSyncedAt"); try validateTimestamp(input["checkedAt"], "\(path).input.checkedAt"); try exactKeys(expected, ["playable", "requiresNetwork", "state"], "\(path).expected"); _ = try bool(expected["playable"], "playable"); _ = try bool(expected["requiresNetwork"], "requiresNetwork"); try oneOf(try nonEmptyString(expected["state"], "state"), ["offlineCached", "cached", "unavailable"], "state")
    case "delayedDelivery":
        try exactKeys(input, ["itemID", "revisionID", "cachedHashVerified", "uploadAcknowledged", "remoteRevisionVisible", "lastAttemptAt"], "\(path).input"); for key in ["itemID", "revisionID"] { try validateID(input[key], "\(path).input.\(key)") }; for key in ["cachedHashVerified", "uploadAcknowledged", "remoteRevisionVisible"] { _ = try bool(input[key], "\(path).input.\(key)") }; try validateTimestamp(input["lastAttemptAt"], "\(path).input.lastAttemptAt"); try exactKeys(expected, ["localPlayable", "deliveryState", "remotePlayable", "immediateDeliveryPromised"], "\(path).expected"); _ = try bool(expected["localPlayable"], "localPlayable"); try oneOf(try nonEmptyString(expected["deliveryState"], "deliveryState"), ["pending", "delivered"], "deliveryState"); _ = try bool(expected["remotePlayable"], "remotePlayable"); _ = try bool(expected["immediateDeliveryPromised"], "immediateDeliveryPromised")
    case "schemaCompatibility":
        try exactKeys(input, ["recordType", "recordSchemaVersion", "supportedSchemaVersion", "receivedAt"], "\(path).input"); try validateID(input["recordType"], "\(path).input.recordType"); guard try integer(input["recordSchemaVersion"], "recordSchemaVersion") > 0, try integer(input["supportedSchemaVersion"], "supportedSchemaVersion") > 0 else { try fail("schema versions must be positive") }; try validateTimestamp(input["receivedAt"], "receivedAt"); try exactKeys(expected, ["accepted", "state"], "\(path).expected"); _ = try bool(expected["accepted"], "accepted"); try oneOf(try nonEmptyString(expected["state"], "state"), ["compatible", "incompatibleSchema"], "state")
    case "preparationFailure":
        try exactKeys(input, ["itemID", "priorRevisionID", "priorRevisionReady", "candidateRevisionID", "candidateTempFilePresent", "candidateValidated", "candidateAtomicallyMoved", "failureAt"], "\(path).input"); for key in ["itemID", "priorRevisionID", "candidateRevisionID"] { try validateID(input[key], "\(path).input.\(key)") }; for key in ["priorRevisionReady", "candidateTempFilePresent", "candidateValidated", "candidateAtomicallyMoved"] { _ = try bool(input[key], "\(path).input.\(key)") }; try validateTimestamp(input["failureAt"], "failureAt"); try exactKeys(expected, ["activeRevisionID", "candidatePublished", "removeCandidateTempFile", "priorRevisionPreserved"], "\(path).expected"); try validateID(expected["activeRevisionID"], "activeRevisionID"); for key in ["candidatePublished", "removeCandidateTempFile", "priorRevisionPreserved"] { _ = try bool(expected[key], key) }
    case "timeoutTerminalError":
        try exactKeys(input, ["requestID", "timeoutSeconds", "statusIntervalSeconds", "events", "priorRevisionID", "priorRevisionReady", "candidateRevisionID", "candidateTempOutputPresent", "candidateValidated", "candidateAtomicallyMoved"], "\(path).input")
        try validateID(input["requestID"], "\(path).input.requestID")
        let timeoutSeconds = try number(input["timeoutSeconds"], "\(path).input.timeoutSeconds")
        let statusIntervalSeconds = try number(input["statusIntervalSeconds"], "\(path).input.statusIntervalSeconds")
        guard timeoutSeconds > 0, timeoutSeconds <= 300 else { try fail("\(path).input.timeoutSeconds must be bounded to 0...300 seconds") }
        guard statusIntervalSeconds > 0, statusIntervalSeconds <= 5 else { try fail("\(path).input.statusIntervalSeconds must be within the 5-second maximum") }
        for key in ["priorRevisionID", "candidateRevisionID"] { try validateID(input[key], "\(path).input.\(key)") }
        let priorRevisionID = try nonEmptyString(input["priorRevisionID"], "priorRevisionID")
        let candidateRevisionID = try nonEmptyString(input["candidateRevisionID"], "candidateRevisionID")
        guard priorRevisionID != candidateRevisionID else { try fail("timeout candidate revision must be distinct") }
        for key in ["priorRevisionReady", "candidateTempOutputPresent", "candidateValidated", "candidateAtomicallyMoved"] { _ = try bool(input[key], "\(path).input.\(key)") }
        guard let events = input["events"] as? [Any], events.count >= 3 else { try fail("\(path).input.events must contain initial status, progress status, and terminal") }
        var statusCount = 0
        var terminalCount = 0
        var previousElapsed = 0.0
        var terminalElapsed = 0.0
        var firstKind = ""
        var firstElapsed = 0.0
        for (index, rawEvent) in events.enumerated() {
            let eventPath = "\(path).input.events[\(index)]"
            let event = try object(rawEvent, eventPath)
            let kind = try nonEmptyString(event["kind"], "\(eventPath).kind")
            let elapsed = try number(event["elapsedSeconds"], "\(eventPath).elapsedSeconds")
            guard elapsed >= 0, elapsed >= previousElapsed else { try fail("\(path).input.events must be ordered by elapsedSeconds") }
            if index == 0 { firstKind = kind; firstElapsed = elapsed }
            previousElapsed = elapsed
            switch kind {
            case "status":
                try exactKeys(event, ["kind", "elapsedSeconds"], eventPath)
                statusCount += 1
            case "terminal":
                try exactKeys(event, ["kind", "elapsedSeconds", "terminal"], eventPath)
                terminalCount += 1
                let terminal = try object(event["terminal"], "\(eventPath).terminal")
                try exactKeys(terminal, ["outcome", "error"], "\(eventPath).terminal")
                try oneOf(try nonEmptyString(terminal["outcome"], "\(eventPath).terminal.outcome"), ["failed"], "\(eventPath).terminal.outcome")
                let error = try object(terminal["error"], "\(eventPath).terminal.error")
                try exactKeys(error, ["code", "message", "retryable", "stage"], "\(eventPath).terminal.error")
                try oneOf(try nonEmptyString(error["code"], "\(eventPath).terminal.error.code"), ["timedOut"], "\(eventPath).terminal.error.code")
                _ = try nonEmptyString(error["message"], "\(eventPath).terminal.error.message")
                _ = try bool(error["retryable"], "\(eventPath).terminal.error.retryable")
                _ = try nonEmptyString(error["stage"], "\(eventPath).terminal.error.stage")
                terminalElapsed = elapsed
            default:
                try fail("\(eventPath).kind must be status or terminal")
            }
        }
        let lastEvent = try object(events.last, "\(path).input.events.last")
        guard firstKind == "status", firstElapsed == 0, statusCount >= 2, terminalCount == 1, terminalElapsed == timeoutSeconds,
              try nonEmptyString(lastEvent["kind"], "\(path).input.events.last.kind") == "terminal" else {
            try fail("\(path).input.events must prove initial/progress status and one terminal at the timeout")
        }
        try exactKeys(expected, ["terminalEventCount", "terminalOutcome", "terminalErrorCode", "initialStatusEmitted", "statusIntervalWithinMaximum", "candidatePublished", "removeCandidateTempOutput", "priorRevisionPreserved", "activeRevisionID"], "\(path).expected")
        guard try integer(expected["terminalEventCount"], "\(path).expected.terminalEventCount") == 1 else { try fail("timeout expected terminal count must be one") }
        try oneOf(try nonEmptyString(expected["terminalOutcome"], "\(path).expected.terminalOutcome"), ["failed"], "\(path).expected.terminalOutcome")
        try oneOf(try nonEmptyString(expected["terminalErrorCode"], "\(path).expected.terminalErrorCode"), ["timedOut"], "\(path).expected.terminalErrorCode")
        for key in ["initialStatusEmitted", "statusIntervalWithinMaximum", "candidatePublished", "removeCandidateTempOutput", "priorRevisionPreserved"] { _ = try bool(expected[key], "\(path).expected.\(key)") }
        try validateID(expected["activeRevisionID"], "\(path).expected.activeRevisionID")
    default:
        try fail("unknown fixture operation \(operation)")
    }
    return (caseID, operation)
}

let defaultSchemaPath = "contracts/domain/schema.json"
let defaultFixtureDirectory = "contracts/fixtures"
let schemaPath: String
let fixtureDirectory: String
if CommandLine.arguments.count > 2 {
    schemaPath = CommandLine.arguments[1]
    fixtureDirectory = CommandLine.arguments[2]
} else if CommandLine.arguments.count == 2 {
    let argument = CommandLine.arguments[1]
    if argument.lowercased().hasSuffix(".json") {
        schemaPath = argument
        fixtureDirectory = defaultFixtureDirectory
    } else {
        schemaPath = defaultSchemaPath
        fixtureDirectory = argument
    }
} else {
    schemaPath = defaultSchemaPath
    fixtureDirectory = defaultFixtureDirectory
}
do {
    let schemaRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: schemaPath)))
    let schema = try object(schemaRaw, schemaPath)
    let (_, coverage) = try validateSchema(schema)
    guard let requiredCases = coverage["requiredCases"] as? [Any] else { try fail("schema.fixtureCoverage.requiredCases must be an array") }
    var expected: [String: String] = [:]
    for raw in requiredCases { let entry = try object(raw, "coverage entry"); expected[try nonEmptyString(entry["caseID"], "caseID")] = try nonEmptyString(entry["operation"], "operation") }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: fixtureDirectory, isDirectory: &isDirectory), isDirectory.boolValue else { try fail("fixture directory not found: \(fixtureDirectory)") }
    guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: fixtureDirectory), includingPropertiesForKeys: [.isRegularFileKey]) else { try fail("cannot enumerate fixture directory") }
    let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.path < $1.path }
    guard !urls.isEmpty else { try fail("zero JSON fixtures discovered") }
    var seen = Set<String>()
    for url in urls {
        let fixture = try object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), url.lastPathComponent)
        let (caseID, operation) = try validateFixture(fixture, url.lastPathComponent)
        guard let expectedOperation = expected[caseID] else { try fail("fixture \(caseID) is not declared in schema fixtureCoverage") }
        guard expectedOperation == operation else { try fail("fixture \(caseID) operation mismatch: expected \(expectedOperation), got \(operation)") }
        guard seen.insert(caseID).inserted else { try fail("duplicate fixture caseID \(caseID)") }
        print("PASS \(url.lastPathComponent): \(caseID) [\(operation)]")
    }
    guard seen == Set(expected.keys) else { try fail("fixture coverage mismatch: expected \(expected.count), found \(seen.count)") }
    print("Validated domain schema and \(seen.count) fixture cases")
} catch {
    fputs("FAIL domain contract: \(error)\n", stderr)
    exit(1)
}
