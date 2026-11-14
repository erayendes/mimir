import Foundation
import os

/// Codex 0.169.0 has built-in status items, not command hooks. Edit only the [tui] status_line
/// array and keep the rest of the original UTF-8 text, including comments and line endings.
/// Anything beyond a single-line array of plain strings in a plain [tui] table is skipped.
struct CodexStatusLineHook {
    var directory: URL = Self.defaultDirectory

    static var defaultDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: home) // same resolution as CodexProvider.readCodexAuthState
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static let limitItems = ["five-hour-limit", "weekly-limit"]
    // Item IDs verified in tui/src/bottom_pane/status_line_setup.rs at rust-v0.169.0;
    // the absent-setting defaults are documented in that tag's config/src/types.rs (Tui).
    // https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/config/src/types.rs
    static let defaultItems = ["model-with-reasoning", "current-dir", "thread-name"]
    private static let log = Logger(subsystem: "com.erayendes.mimir", category: "codex-statusline")
    /// Symlinks (dotfile managers) are followed so an atomic write replaces the target, not the link.
    private var configURL: URL { directory.appendingPathComponent("config.toml").resolvingSymlinksInPath() }
    private var backupURL: URL { directory.appendingPathComponent("config.toml.mimir-backup") }
    private var stateURL: URL { directory.appendingPathComponent("mimir-statusline.json") }

    /// Appending and then removing the same items is an exact inverse (see ItemArray), so the
    /// limit items we added are all that disable needs; `createdLine` restores an absent setting.
    private struct State: Codable {
        var added: [String]
        var createdLine: Bool
    }

    enum EditError: Error { case unsafeShape }

    struct Edit {
        var text: String
        var added: [String]
        var createdLine: Bool
    }

    // MARK: - Pure, deliberately limited TOML editor

    private struct Document {
        var insertion: String.Index?
        var lineRange: Range<String.Index>?
        var arrayRange: Range<String.Index>?
        var array: ItemArray?
    }

    private struct ItemArray {
        struct Item {
            var value: String
            var range: Range<String.Index>
        }
        var text: String
        var items: [Item] = []
        var commas: [String.Index] = []

        init(_ text: String) throws {
            self.text = text
            guard text.first == "[", text.last == "]" else { throw EditError.unsafeShape }
            var index = text.index(after: text.startIndex)
            let end = text.index(before: text.endIndex)
            func skipSpaces() {
                while index < end, text[index] == " " || text[index] == "\t" {
                    index = text.index(after: index)
                }
            }
            skipSpaces()
            while index < end {
                let start = index
                let quote = text[index]
                guard quote == "\"" || quote == "'" else { throw EditError.unsafeShape }
                index = text.index(after: index)
                let valueStart = index
                while index < end, text[index] != quote {
                    // Built-in item IDs need no escapes. Leave exotic strings to Codex's parser.
                    guard text[index].isASCII,
                          text[index].isLetter || text[index].isNumber || text[index] == "-" || text[index] == "_"
                    else { throw EditError.unsafeShape }
                    index = text.index(after: index)
                }
                guard index < end else { throw EditError.unsafeShape }
                let value = String(text[valueStart..<index])
                index = text.index(after: index)
                items.append(Item(value: value, range: start..<index))
                skipSpaces()
                if index < end {
                    guard text[index] == "," else { throw EditError.unsafeShape }
                    commas.append(index)
                    index = text.index(after: index)
                    skipSpaces()
                }
            }
        }

        func appending(_ values: [String]) -> String {
            guard !values.isEmpty else { return text }
            let newItems = values.map { "\"\($0)\"" }.joined(separator: ", ")
            var result = text
            if let last = items.last {
                // Inserting before the old trailing comma also preserves trailing-comma style.
                result.insert(contentsOf: ", " + newItems, at: last.range.upperBound)
            } else {
                result.insert(contentsOf: newItems, at: text.index(after: text.startIndex))
            }
            return result
        }

        func removing(_ values: Set<String>) throws -> String {
            var current = self
            while let index = current.items.firstIndex(where: { values.contains($0.value) }) {
                let item = current.items[index]
                let range: Range<String.Index>
                if index + 1 < current.items.count {
                    range = item.range.lowerBound..<current.items[index + 1].range.lowerBound
                } else if index > 0 {
                    range = current.commas[index - 1]..<item.range.upperBound
                } else {
                    let end = current.commas.last.map { current.text.index(after: $0) } ?? item.range.upperBound
                    range = item.range.lowerBound..<end
                }
                var result = current.text
                result.removeSubrange(range)
                current = try ItemArray(result)
            }
            return current.text
        }
    }

    /// Strip comments outside strings; track array/inline-table depth so a [tui] lookalike in an
    /// unrelated multiline array cannot become a table. Multiline strings and escaped/complex
    /// keys are conservatively refused. This is a safe subset editor, not a general TOML parser.
    private static func code(_ line: Substring, brackets: inout [Character]) throws -> Substring {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let char = line[index]
            if let currentQuote = quote {
                if escaped { escaped = false }
                else if char == "\\", currentQuote == "\"" { escaped = true }
                else if char == currentQuote { quote = nil }
            } else if char == "#" {
                return line[..<index]
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "[" || char == "{" {
                brackets.append(char)
            } else if char == "]" || char == "}" {
                guard brackets.popLast() == (char == "]" ? "[" : "{") else { throw EditError.unsafeShape }
            }
        }
        guard quote == nil else { throw EditError.unsafeShape }
        return line
    }

    private static func keyPath(_ text: String) throws -> [String] {
        let pattern = #"\s*(?:([A-Za-z0-9_-]+)|"([^"\\]+)"|'([^']+)')\s*(\.|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var offset = 0
        var keys: [String] = []
        while offset < ns.length {
            guard let match = regex.firstMatch(in: text, range: NSRange(location: offset, length: ns.length - offset)),
                  match.range.location == offset else { throw EditError.unsafeShape }
            let valueRange = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            keys.append(ns.substring(with: valueRange))
            offset = NSMaxRange(match.range)
            if offset == ns.length, ns.substring(with: match.range(at: 4)) == "." {
                throw EditError.unsafeShape
            }
        }
        guard !keys.isEmpty else { throw EditError.unsafeShape }
        return keys
    }

    private static func parse(_ text: String) throws -> Document {
        var document = Document()
        var table: [String] = []
        var brackets: [Character] = []
        var seenTUI = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let previousDepth = brackets.count
            let rawCode = try code(line, brackets: &brackets)
            let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.contains("\"\"\""), !trimmed.contains("'''") else { throw EditError.unsafeShape }
            if trimmed.isEmpty || previousDepth > 0 { continue }
            let lineEnd = line.endIndex < text.endIndex ? text.index(after: line.endIndex) : line.endIndex
            if trimmed.hasPrefix("[") {
                guard brackets.isEmpty, trimmed.hasSuffix("]") else { throw EditError.unsafeShape }
                let isArray = trimmed.hasPrefix("[[")
                let count = isArray ? 2 : 1
                table = try keyPath(String(trimmed.dropFirst(count).dropLast(count)))
                if table.first == "tui" {
                    guard !isArray, !table.dropFirst().contains("status_line") else { throw EditError.unsafeShape }
                    if table == ["tui"] {
                        guard !seenTUI else { throw EditError.unsafeShape }
                        seenTUI = true
                        document.insertion = lineEnd
                    }
                }
                continue
            }
            guard let equals = rawCode.firstIndex(of: "=") else { throw EditError.unsafeShape }
            let key = try keyPath(String(rawCode[..<equals]))
            if table.isEmpty, key.first == "tui" { throw EditError.unsafeShape } // inline/dotted tui
            guard table == ["tui"], key.first == "status_line" else { continue }
            guard key.count == 1, document.array == nil, brackets.isEmpty else { throw EditError.unsafeShape }
            let value = rawCode[rawCode.index(after: equals)...]
            guard let start = value.firstIndex(where: { !$0.isWhitespace }),
                  let end = value.lastIndex(where: { !$0.isWhitespace }) else { throw EditError.unsafeShape }
            let range = start..<value.index(after: end)
            document.arrayRange = range
            document.lineRange = line.startIndex..<lineEnd
            document.array = try ItemArray(String(text[range]))
        }
        guard brackets.isEmpty else { throw EditError.unsafeShape }
        return document
    }

    /// The exact line enable writes when the setting is absent; disable removes only this line.
    private static var generatedLine: String {
        "status_line = " + (try! ItemArray("[]")).appending(defaultItems + limitItems)
    }

    static func enabling(_ text: String) throws -> Edit {
        let document = try parse(text)
        guard let array = document.array, let range = document.arrayRange else {
            let newline = text.contains("\r\n") ? "\r\n" : "\n"
            var result = text
            let line = generatedLine + newline
            if let insertion = document.insertion {
                let separator = insertion == text.endIndex && !text.hasSuffix("\n") ? newline : ""
                result.insert(contentsOf: separator + line, at: insertion)
            } else {
                let separator = text.isEmpty || text.hasSuffix("\n") ? "" : newline
                result += separator + "[tui]" + newline + line
            }
            return Edit(text: result, added: defaultItems + limitItems, createdLine: true)
        }
        let missing = limitItems.filter { item in !array.items.contains { $0.value == item } }
        var result = text
        result.replaceSubrange(range, with: array.appending(missing))
        return Edit(text: result, added: missing, createdLine: false)
    }

    private static func disabling(_ text: String, state: State) throws -> String {
        let document = try parse(text)
        guard let array = document.array, let range = document.arrayRange,
              let lineRange = document.lineRange else { return text }
        var result = text
        if state.createdLine,
           text[lineRange].trimmingCharacters(in: .newlines) == generatedLine {
            // Restore an absent setting so Codex can use its defaults again. Leave the table
            // itself intact; it may now contain other settings the user has added.
            result.removeSubrange(lineRange)
            return result
        }
        // Only our limit items go; the defaults we wrote stay explicit, which renders the same as
        // an absent setting. An empty array would instead hide Codex's status line entirely.
        result.replaceSubrange(range, with: try array.removing(Set(state.added)))
        return result
    }

    // MARK: - Disk I/O

    private func readConfig() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return "" }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    private func readState() throws -> State? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        guard Set(state.added).isSubset(of: Set(Self.limitItems)) else { throw EditError.unsafeShape }
        return state
    }

    /// Atomic, but keeps the file's permissions: config.toml can hold MCP server secrets.
    private func writeConfig(_ text: String) throws {
        let mode = try? FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions]
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: configURL.path) }
    }

    /// Adopts once. While our state exists, items the user removed stay removed on later launches.
    func enable() {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, // do not install Codex for the user
              !FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let edit = try Self.enabling(readConfig())
            let added = edit.added.filter(Self.limitItems.contains)
            guard !added.isEmpty else { return }
            if FileManager.default.fileExists(atPath: configURL.path),
               !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: configURL, to: backupURL)
            }
            try JSONEncoder().encode(State(added: added, createdLine: edit.createdLine))
                .write(to: stateURL, options: .atomic)
            do {
                try writeConfig(edit.text)
            } catch {
                try? FileManager.default.removeItem(at: stateURL)
                throw error
            }
        } catch {
            Self.log.error("Skipping Codex status_line enable (unsafe shape or I/O): \(error.localizedDescription)")
        }
    }

    func refreshScript() { enable() }

    func disable() {
        do {
            guard let state = try readState() else { return }
            let original = try readConfig()
            let edited = try Self.disabling(original, state: state)
            if edited != original { try writeConfig(edited) }
            try FileManager.default.removeItem(at: stateURL)
        } catch {
            Self.log.error("Skipping Codex status_line disable (unsafe shape or I/O): \(error.localizedDescription)")
        }
    }
}
