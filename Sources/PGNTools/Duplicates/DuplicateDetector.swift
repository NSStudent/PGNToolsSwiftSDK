import FischerCore

/// What makes two games duplicates.
public enum DuplicateCriterion: Sendable, Equatable {
    /// The same main line moves from the same starting position. Comments,
    /// variations, NAGs, move number style and tags are ignored.
    case sameMoves
    /// The same final position of the main line (placement, side to move,
    /// castling and en passant rights), however it was reached.
    case sameFinalPosition
    /// The same main line moves and the same values of `tags` (compared
    /// case-insensitively, with whitespace collapsed; `?` counts as empty).
    case sameTagsAndMoves(tags: [PGNTag] = DuplicateCriterion.defaultTags)

    /// The tags compared by ``sameTagsAndMoves(tags:)`` by default.
    public static let defaultTags: [PGNTag] = [.white, .black, .event, .site, .round, .date, .result]
}

/// A game and the earlier games it duplicates.
public struct DuplicateGroup: Sendable, Equatable {
    /// Number of the first game with this content.
    public let original: Int
    /// Numbers of the later games with the same content, in input order.
    public var duplicates: [Int]
}

/// Detects duplicate games in a stream, remembering one key per distinct
/// game.
///
/// ```swift
/// var detector = DuplicateDetector(criterion: .sameMoves)
/// try reader.forEachGame { record in
///     if let original = detector.check(record) {
///         print("game \(record.number) duplicates game \(original)")
///     }
/// }
/// ```
public struct DuplicateDetector: Sendable {
    public let criterion: DuplicateCriterion
    private var firstGame: [String: Int] = [:]
    private var groupIndex: [Int: Int] = [:]
    /// The duplicate groups found so far, ordered by their original game.
    public private(set) var groups: [DuplicateGroup] = []

    public init(criterion: DuplicateCriterion = .sameMoves) {
        self.criterion = criterion
    }

    /// Records `record` and returns the number of the earlier game it
    /// duplicates, or `nil` if it is the first game with its content.
    public mutating func check(_ record: GameRecord) -> Int? {
        check(key: Self.key(for: record.game, criterion: criterion), gameNumber: record.number)
    }

    /// Records a game by its precomputed ``key(for:criterion:)``.
    public mutating func check(key: String, gameNumber: Int) -> Int? {
        guard let original = firstGame[key] else {
            firstGame[key] = gameNumber
            return nil
        }
        if let index = groupIndex[original] {
            groups[index].duplicates.append(gameNumber)
        } else {
            groupIndex[original] = groups.count
            groups.append(DuplicateGroup(original: original, duplicates: [gameNumber]))
        }
        return original
    }

    /// Number of distinct games seen.
    public var uniqueCount: Int { firstGame.count }

    /// The key that identical games share under `criterion`.
    public static func key(for game: AnnotatedPGNGame, criterion: DuplicateCriterion) -> String {
        key(for: game, criterion: criterion, finalPosition: { game.finalPosition.key })
    }

    /// The key of a game being filtered, reusing its replayed positions.
    public static func key(for context: GameContext, criterion: DuplicateCriterion) -> String {
        key(for: context.game, criterion: criterion, finalPosition: { context.positions.last?.key ?? PositionKey(rawValue: 0) })
    }

    static func key(for game: AnnotatedPGNGame, criterion: DuplicateCriterion,
                    finalPosition: () -> PositionKey) -> String {
        switch criterion {
        case .sameMoves:
            return "m" + game.contentHash(includeTags: false)
        case .sameFinalPosition:
            return "p" + finalPosition().description
        case .sameTagsAndMoves(let tags):
            var fields = tags.map { tag -> String in
                let value = tag == .result ? (game.tags[tag] ?? game.result.rawValue) : game.tags[tag]
                return normalizedTagValue(value)
            }
            fields.append(game.contentHash(includeTags: false))
            return "t" + PGNHash.fnv1a64Hex(fields.joined(separator: "\u{1F}"))
        }
    }

    static func normalizedTagValue(_ value: String?) -> String {
        guard let value else { return "" }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return collapsed == "?" || collapsed == "????.??.??" ? "" : collapsed
    }
}
