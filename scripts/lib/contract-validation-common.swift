import Foundation

enum ContractValidationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        if case .invalid(let message) = self { return message }
        return "invalid contract"
    }
}

typealias JSON = [String: Any]
typealias JSONObject = JSON

enum TimestampStringPolicy {
    case timestampStringOrNull
    case nonEmptyString
}

func fail(_ message: String) throws -> Never {
    throw ContractValidationError.invalid(message)
}

func object(_ value: Any?, _ path: String) throws -> JSON {
    guard let value = value as? JSON else { try fail("\(path) must be an object") }
    return value
}

func nonEmptyString(_ value: Any?, _ path: String) throws -> String {
    guard let value = value as? String, !value.isEmpty else {
        try fail("\(path) must be a non-empty string")
    }
    return value
}

func string(_ object: JSONObject, _ key: String, _ path: String) throws -> String {
    try nonEmptyString(object[key], "\(path).\(key)")
}

func bool(_ value: Any?, _ path: String) throws -> Bool {
    guard let value = value as? NSNumber, String(cString: value.objCType) == "c" else {
        try fail("\(path) must be a boolean")
    }
    return value.boolValue
}

func bool(_ object: JSONObject, _ key: String, _ path: String) throws -> Bool {
    guard let value = object[key] as? Bool else {
        try fail("\(path).\(key) must be a boolean")
    }
    return value
}

func number(_ value: Any?, _ path: String) throws -> Double {
    guard let value = value as? NSNumber, String(cString: value.objCType) != "c" else {
        try fail("\(path) must be a number")
    }
    return value.doubleValue
}

func number(_ object: JSONObject, _ key: String, _ path: String) throws -> Double {
    guard let value = object[key] as? NSNumber else {
        try fail("\(path).\(key) must be a number")
    }
    return value.doubleValue
}

func integer(_ value: Any?, _ path: String) throws -> Int {
    let parsedValue = try number(value, path)
    guard parsedValue.isFinite, parsedValue.rounded() == parsedValue else {
        try fail("\(path) must be an integer")
    }
    return Int(parsedValue)
}

func integer(_ object: JSONObject, _ key: String, _ path: String) throws -> Int {
    let parsedValue = try number(object, key, path)
    guard parsedValue.rounded() == parsedValue else {
        try fail("\(path).\(key) must be an integer")
    }
    return Int(parsedValue)
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else { try fail("\(label): expected \(expected), got \(actual)") }
}

private let timestampKeySuffixes = ["At", "Time"]
private let timestampPattern = try! NSRegularExpression(
    pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#
)
private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let timestampFormatterWithoutFractions: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func validateTimestamps(
    _ value: Any,
    path: String = "fixture",
    stringPolicy: TimestampStringPolicy = .timestampStringOrNull
) throws {
    if let object = value as? JSON {
        for key in object.keys.sorted() {
            let child = object[key]!
            if timestampKeySuffixes.contains(where: { key.hasSuffix($0) }), !(child is NSNull) {
                let timestamp: String
                switch stringPolicy {
                case .timestampStringOrNull:
                    guard let stringValue = child as? String else {
                        try fail("\(path).\(key) must be a timestamp string or null")
                    }
                    timestamp = stringValue
                case .nonEmptyString:
                    timestamp = try nonEmptyString(child, "\(path).\(key)")
                }

                let range = NSRange(timestamp.startIndex..<timestamp.endIndex, in: timestamp)
                let shapeMatches = timestampPattern.firstMatch(in: timestamp, range: range) != nil
                let parses = timestampFormatter.date(from: timestamp) != nil
                    || timestampFormatterWithoutFractions.date(from: timestamp) != nil
                guard shapeMatches && parses else {
                    try fail("\(path).\(key) must be UTC ISO 8601 ending in Z")
                }
            }
            try validateTimestamps(child, path: "\(path).\(key)", stringPolicy: stringPolicy)
        }
    } else if let array = value as? [Any] {
        for (index, child) in array.enumerated() {
            try validateTimestamps(child, path: "\(path)[\(index)]", stringPolicy: stringPolicy)
        }
    }
}
