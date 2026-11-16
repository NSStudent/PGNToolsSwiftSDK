import FischerCore
import Foundation

/// A comparison between a tag value and a reference value.
public enum TagComparison: String, Sendable, CaseIterable {
    case equal = "=="
    case notEqual = "!="
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
    /// The tag value contains the reference text (case and diacritics are
    /// ignored).
    case contains = "~"
}

/// Compares one tag with a value, like `WhiteElo >= 2500` or
/// `Event ~ Olympiad`.
///
/// Values are compared as numbers when both are integers, as dates for the
/// `Date`, `EventDate` and `UTCDate` tags, and otherwise as text, ignoring
/// case and diacritics. A missing tag only passes `!=`.
public struct TagFilter: GameFilter {
    public var tag: PGNTag
    public var comparison: TagComparison
    public var value: String

    public init(_ tag: PGNTag, _ comparison: TagComparison, _ value: String) {
        self.tag = tag
        self.comparison = comparison
        self.value = value
    }

    /// Parses `Name operator value`, for example `WhiteElo >= 2500`,
    /// `Result == 1-0` or `Event ~ "World Cup"`. The operators are
    /// `== = != < <= > >= ~`.
    public init(_ text: String) throws(PGNToolsError) {
        let trimmed = text.trimmed
        let name = String(trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        var rest = trimmed.dropFirst(name.count).drop(while: \.isWhitespace)
        let operators: [(String, TagComparison)] = [
            ("==", .equal), ("!=", .notEqual), ("<=", .lessOrEqual), (">=", .greaterOrEqual),
            ("<", .less), (">", .greater), ("=", .equal), ("~", .contains),
        ]
        guard !name.isEmpty, let (symbol, comparison) = operators.first(where: { rest.hasPrefix($0.0) }) else {
            throw PGNToolsError(.invalidArgument, "tag criterion \"\(text)\" must look like 'Tag >= value'")
        }
        rest = rest.dropFirst(symbol.count).drop(while: \.isWhitespace)
        var value = String(rest).trimmed
        if value.count >= 2, value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
        self.init(PGNTag(rawValue: name) ?? .custom(name), comparison, value)
    }

    public func matches(_ context: GameContext) -> Bool {
        let actual = tag == .result ? context.game.tags[.result] ?? context.game.result.rawValue : context.game.tags[tag]
        guard let actual else { return comparison == .notEqual }
        if comparison == .contains { return Self.fold(actual).contains(Self.fold(value)) }
        let order: ComparisonResult
        if let lhs = Int(actual.trimmed), let rhs = Int(value.trimmed) {
            order = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        } else if [.date, .eventDate, .UTCDate].contains(tag) {
            guard let lhs = PGNDate(actual), let rhs = PGNDate(value) else { return comparison == .notEqual }
            if lhs.latest < rhs.earliest {
                order = .orderedAscending
            } else if lhs.earliest > rhs.latest {
                order = .orderedDescending
            } else {
                order = .orderedSame
            }
        } else {
            order = Self.fold(actual).compare(Self.fold(value))
        }
        switch comparison {
        case .equal: return order == .orderedSame
        case .notEqual: return order != .orderedSame
        case .less: return order == .orderedAscending
        case .lessOrEqual: return order != .orderedDescending
        case .greater: return order == .orderedDescending
        case .greaterOrEqual: return order != .orderedAscending
        case .contains: return false
        }
    }

    static func fold(_ text: String) -> String {
        text.trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Which player a filter looks at.
public enum PlayerSide: String, Sendable, CaseIterable {
    case white, black, either
}

/// Passes games played by a player whose name contains `name` (case and
/// diacritics are ignored).
public struct PlayerFilter: GameFilter {
    public var name: String
    public var side: PlayerSide

    public init(_ name: String, side: PlayerSide = .either) {
        self.name = name
        self.side = side
    }

    public func matches(_ context: GameContext) -> Bool {
        let needle = TagFilter.fold(name)
        func check(_ tag: PGNTag) -> Bool {
            context.game.tags[tag].map { TagFilter.fold($0).contains(needle) } ?? false
        }
        switch side {
        case .white: return check(.white)
        case .black: return check(.black)
        case .either: return check(.white) || check(.black)
        }
    }
}

/// Passes games whose `Date` falls in a range.
///
/// A date with unknown parts stands for every day it could be:
/// `2020.??.??` passes a range that includes any day of 2020. Games without
/// a known year never pass.
public struct DateRangeFilter: GameFilter {
    public var from: PGNDate?
    public var to: PGNDate?

    public init(from: PGNDate? = nil, to: PGNDate? = nil) {
        self.from = from
        self.to = to
    }

    public func matches(_ context: GameContext) -> Bool {
        guard let date = context.game.tags[.date].flatMap(PGNDate.init) else { return false }
        if let from, date.latest < from.earliest { return false }
        if let to, date.earliest > to.latest { return false }
        return true
    }
}

/// Passes games with one of the given results. The `Result` tag is used,
/// or the movetext termination marker when the tag is missing.
public struct ResultFilter: GameFilter {
    public var results: Set<PGNOutcome>

    public init(_ results: Set<PGNOutcome>) {
        self.results = results
    }

    public func matches(_ context: GameContext) -> Bool {
        let outcome = context.game.tags[.result].flatMap { PGNOutcome(rawValue: $0.trimmed) } ?? context.game.result
        return results.contains(outcome)
    }
}

/// Passes games whose Elo ratings fall in a range.
public struct EloFilter: GameFilter {
    /// Which ratings must be in the range.
    public enum Mode: String, Sendable, CaseIterable {
        /// Both players' ratings.
        case both
        /// At least one player's rating.
        case either
        /// The average of both ratings.
        case average
        /// White's rating only.
        case white
        /// Black's rating only.
        case black
    }

    public var minimum: Int?
    public var maximum: Int?
    public var mode: Mode

    public init(minimum: Int? = nil, maximum: Int? = nil, mode: Mode = .both) {
        self.minimum = minimum
        self.maximum = maximum
        self.mode = mode
    }

    public func matches(_ context: GameContext) -> Bool {
        func elo(_ tag: PGNTag) -> Int? { context.game.tags[tag].flatMap { Int($0.trimmed) }.flatMap { $0 > 0 ? $0 : nil } }
        func inRange(_ value: Int?) -> Bool {
            guard let value else { return false }
            return value >= (minimum ?? Int.min) && value <= (maximum ?? Int.max)
        }
        let white = elo(.whiteElo)
        let black = elo(.blackElo)
        switch mode {
        case .both: return inRange(white) && inRange(black)
        case .either: return inRange(white) || inRange(black)
        case .white: return inRange(white)
        case .black: return inRange(black)
        case .average:
            guard let white, let black else { return false }
            return inRange((white + black) / 2)
        }
    }
}
