import Foundation
import XCTest

final class WiltedMacIconHelpTests: XCTestCase {
    func testEveryIconOnlyButtonHasHelpInItsOwnExpression() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("WiltedMac/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let violations = IconButtonHelpAudit.missingHelpLines(in: source)
            XCTAssertTrue(violations.isEmpty, "\(file.lastPathComponent): icon-only Button missing .help at lines \(violations)")
        }
    }

    func testRemovingHelpFromAnActualButtonFailsTheAudit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacRootView.swift"), encoding: .utf8)
        let help = ".help(model.sidebarToggleTitle)"
        XCTAssertTrue(source.contains(help), "The causal fixture must still name the actual sidebar button")
        let mutated = source.replacingOccurrences(of: help, with: "")
        XCTAssertEqual(IconButtonHelpAudit.missingHelpLines(in: mutated).count,
                       IconButtonHelpAudit.missingHelpLines(in: source).count + 1)
    }

    func testCommentsStringsAndNeighborHelpCannotSatisfyAMissingTooltip() {
        let source = #"""
        Button {} label: { Image(systemName: "play") }
            // .help("Play")
            .accessibilityLabel("literal .help( is not a modifier")
        Button {} label: { Image(systemName: "pause") }
            .help("Pause")
        """#
        XCTAssertEqual(IconButtonHelpAudit.missingHelpLines(in: source), [1])
    }

    func testIconOnlyLabelsAndSharedSemanticHelpAreCovered() {
        let source = #"""
        Button {} label: { Label("Play", systemImage: "play") }
            .labelStyle(.iconOnly)
        Button(action: action) { Image(systemName: symbol) }
            .help(busy ? pending.message : label)
        Button {} label: { Label("Pause", systemImage: "pause").labelStyle(.iconOnly) }
            .help("Pause")
        Button("Download") { download() }
        Button {} label: { Label("Visible title", systemImage: "plus") }
        """#
        XCTAssertEqual(IconButtonHelpAudit.missingHelpLines(in: source), [1])
    }

    func testNestedAndContainerHelpDoNotSatisfyTheButtonModifierChain() {
        let source = #"""
        Group {
            Button {} label: { Image(systemName: "play") }
                .overlay { Text("overlay").help("Overlay help") }
        }.help("Container help")
        """#
        XCTAssertEqual(IconButtonHelpAudit.missingHelpLines(in: source), [2])
    }

    func testBalancedClosuresAndInterpolatedStringsKeepButtonsSeparate() {
        let source = #"""
        Button { if ready { act() } } label: {
            Image(systemName: "play")
                .overlay { if busy { ProgressView() } }
        }.help("Play \(name ?? "unknown")")
        /* outer comment /* Button {} label: { Image() } */ */
        Button(action: act) { Image(systemName: "pause") }
        """#
        XCTAssertEqual(IconButtonHelpAudit.missingHelpLines(in: source), [6])
    }
}

/// A lexical audit, not a file-wide grep: strings/comments are opaque and
/// balanced arguments/closures prevent another view's help from leaking in.
private enum IconButtonHelpAudit {
    private struct Token {
        let text: String
        let line: Int
    }

    static func missingHelpLines(in source: String) -> [Int] {
        let tokens = tokenize(source)
        let pairs = matchingDelimiters(tokens)
        var missing: [Int] = []
        for start in tokens.indices where tokens[start].text == "Button" {
            var cursor = start + 1
            var initializer: [Token] = []
            if cursor < tokens.count, tokens[cursor].text == "(", let end = pairs[cursor] {
                initializer = Array(tokens[(cursor + 1)..<end])
                cursor = end + 1
            }
            var label: [Token] = []
            if cursor < tokens.count, tokens[cursor].text == "{", let end = pairs[cursor] {
                // Button(action: ...) { label } versus Button { action } label: { label }.
                if initializer.contains(where: { $0.text == "action" }) {
                    label = Array(tokens[(cursor + 1)..<end])
                }
                cursor = end + 1
            }
            if cursor + 2 < tokens.count, tokens[cursor].text == "label",
               tokens[cursor + 1].text == ":", tokens[cursor + 2].text == "{",
               let end = pairs[cursor + 2] {
                label = Array(tokens[(cursor + 3)..<end])
                cursor = end + 1
            }
            var modifiers: [String] = []
            var iconOnly = hasIconOnlyStyle(label)
            while cursor + 1 < tokens.count, tokens[cursor].text == "." {
                let name = tokens[cursor + 1].text
                modifiers.append(name)
                cursor += 2
                if cursor < tokens.count, tokens[cursor].text == "(", let end = pairs[cursor] {
                    if name == "labelStyle" {
                        iconOnly = iconOnly || tokens[cursor..<end].contains(where: { $0.text == "iconOnly" })
                    }
                    cursor = end + 1
                }
                if cursor < tokens.count, tokens[cursor].text == "{", let end = pairs[cursor] {
                    cursor = end + 1
                }
                // Multiple trailing closures on a modifier belong to that modifier.
                while cursor + 2 < tokens.count, tokens[cursor + 1].text == ":",
                      tokens[cursor + 2].text == "{", let end = pairs[cursor + 2] {
                    cursor = end + 1
                }
            }
            let hasImage = label.contains { $0.text == "Image" }
            let hasText = label.contains { $0.text == "Text" || $0.text == "Label" }
            let hasLabel = label.contains { $0.text == "Label" } || initializer.contains { $0.text == "systemImage" }
            if ((hasImage && !hasText) || (hasLabel && iconOnly)), !modifiers.contains("help") {
                missing.append(tokens[start].line)
            }
        }
        return missing
    }

    private static func hasIconOnlyStyle(_ tokens: [Token]) -> Bool {
        guard tokens.count >= 5 else { return false }
        for index in 0..<(tokens.count - 4) {
            if tokens[index].text == ".", tokens[index + 1].text == "labelStyle",
               tokens[index + 2].text == "(", tokens[index + 3].text == ".",
               tokens[index + 4].text == "iconOnly" { return true }
        }
        return false
    }

    private static func matchingDelimiters(_ tokens: [Token]) -> [Int: Int] {
        var stack: [Int] = []
        var result: [Int: Int] = [:]
        let closers = [")": "(", "}": "{", "]": "["]
        for index in tokens.indices {
            let text = tokens[index].text
            if ["(", "{", "["].contains(text) { stack.append(index) }
            if let opener = closers[text], let start = stack.last, tokens[start].text == opener {
                result[start] = index
                stack.removeLast()
            }
        }
        return result
    }

    private static func tokenize(_ source: String) -> [Token] {
        let characters = Array(source)
        var cursor = 0
        var line = 1
        var tokens: [Token] = []
        func matches(_ text: String) -> Bool {
            let wanted = Array(text)
            return cursor + wanted.count <= characters.count
                && Array(characters[cursor..<(cursor + wanted.count)]) == wanted
        }
        func advance(_ count: Int = 1) {
            for _ in 0..<count where cursor < characters.count {
                if characters[cursor] == "\n" { line += 1 }
                cursor += 1
            }
        }
        // Skip interpolation recursively so its quoted strings cannot end the outer string.
        func skipString() {
            let delimiter = matches("\"\"\"") ? "\"\"\"" : "\""
            advance(delimiter.count)
            while cursor < characters.count {
                if matches(delimiter) { advance(delimiter.count); return }
                if matches("\\(") {
                    advance(2)
                    var depth = 1
                    while cursor < characters.count && depth > 0 {
                        if matches("\"") { skipString() }
                        else {
                            if characters[cursor] == "(" { depth += 1 }
                            if characters[cursor] == ")" { depth -= 1 }
                            advance()
                        }
                    }
                } else if matches("\\") { advance(min(2, characters.count - cursor)) }
                else { advance() }
            }
        }
        while cursor < characters.count {
            if characters[cursor].isWhitespace { advance(); continue }
            if matches("//") {
                while cursor < characters.count && characters[cursor] != "\n" { advance() }
                continue
            }
            if matches("/*") {
                advance(2)
                var depth = 1
                while cursor < characters.count && depth > 0 {
                    if matches("/*") { depth += 1; advance(2) }
                    else if matches("*/") { depth -= 1; advance(2) }
                    else { advance() }
                }
                continue
            }
            let tokenLine = line
            if matches("\"") {
                skipString()
                tokens.append(Token(text: "<string>", line: tokenLine))
            } else if characters[cursor].isLetter || characters[cursor] == "_" {
                let start = cursor
                while cursor < characters.count && (characters[cursor].isLetter
                    || characters[cursor].isNumber || characters[cursor] == "_") { advance() }
                tokens.append(Token(text: String(characters[start..<cursor]), line: tokenLine))
            } else {
                tokens.append(Token(text: String(characters[cursor]), line: tokenLine))
                advance()
            }
        }
        return tokens
    }
}
