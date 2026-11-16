import FischerCore

/// Edits the tag section of a game's PGN text without rewriting its
/// movetext, so comments, variations and formatting are kept as they were.
public enum PGNTextEditing {
    /// Sets tag values in `pgn`, the text of a single game.
    ///
    /// A tag that already exists is replaced in place; a new tag is added
    /// after the last tag line. A `nil` value removes the tag.
    public static func settingTags(_ values: [(tag: PGNTag, value: String?)], in pgn: String) -> String {
        var lines = pgn.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The tag section is the run of leading tag lines.
        var tagEnd = 0
        while tagEnd < lines.count, tagName(of: lines[tagEnd]) != nil { tagEnd += 1 }

        for (tag, value) in values {
            let name = tag.rawValue
            let existing = lines[..<tagEnd].firstIndex { tagName(of: $0) == name }
            switch (existing, value) {
            case let (index?, value?):
                lines[index] = tagLine(name, value)
            case let (index?, nil):
                lines.remove(at: index)
                tagEnd -= 1
            case let (nil, value?):
                lines.insert(tagLine(name, value), at: tagEnd)
                tagEnd += 1
            case (nil, nil):
                break
            }
        }
        if tagEnd > 0, tagEnd < lines.count, !lines[tagEnd].trimmingCharacters(in: .whitespaces).isEmpty {
            // Keep a blank line between the tags and the movetext.
            lines.insert("", at: tagEnd)
        }
        return lines.joined(separator: "\n")
    }

    /// A tag pair line with the value escaped as the PGN standard requires.
    public static func tagLine(_ name: String, _ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "[\(name) \"\(escaped)\"]"
    }

    /// The tag name of a tag pair line, or `nil` for any other line.
    static func tagName(of line: String) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == "[" else { return nil }
        let name = trimmed.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}
