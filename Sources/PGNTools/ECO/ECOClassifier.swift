import FischerCore

/// The opening found for a game.
public struct ECOClassification: Sendable, Equatable {
    /// The named opening.
    public let opening: Opening
    /// The half-move of the game at which the named position was reached.
    public let ply: Int

    public init(opening: Opening, ply: Int) {
        self.opening = opening
        self.ply = ply
    }

    /// The tags that describe the opening: `ECO`, `Opening`, `Variation` and
    /// `SubVariation` (`nil` removes a tag the opening does not have).
    public var tags: [(tag: PGNTag, value: String?)] {
        [
            (.eco, opening.eco),
            (.opening, opening.family),
            (.variation, opening.variation),
            (.subVariation, opening.subVariation),
        ]
    }
}

/// Classifies games by opening from the positions they reach.
///
/// The classifier replays the main line and looks up every position by its
/// Zobrist key. The game gets the opening of the last (deepest) named
/// position it reaches, so move order does not matter: a game that
/// transposes into a named position is classified like the main line.
///
/// ```swift
/// let classifier = ECOClassifier()
/// if let found = classifier.classify(game) {
///     print(found.opening.eco, found.opening.name)
/// }
/// ```
public struct ECOClassifier: Sendable {
    public let database: ECODatabase
    /// Positions after this ply are not looked up. Named positions deeper
    /// than the longest line of the table are only reachable by wasting
    /// tempi, so by default the search stops 10 plies after it.
    public var maxPly: Int?

    /// Creates a classifier.
    ///
    /// - Parameters:
    ///   - database: The opening table; the bundled lichess table by default.
    ///   - maxPly: Last ply searched. Pass `nil` for the table's longest
    ///     line plus 10, or `Int.max` to search the whole game.
    public init(database: ECODatabase = .lichess, maxPly: Int? = nil) {
        self.database = database
        self.maxPly = maxPly ?? database.maxPly + 10
    }

    /// Classifies the main line of `game`.
    public func classify(_ game: AnnotatedPGNGame) -> ECOClassification? {
        var best: ECOClassification?
        game.forEachMainlinePosition(maxPly: maxPly) { position in
            if let opening = database.opening(for: position.key) {
                best = ECOClassification(opening: opening, ply: position.ply)
            }
        }
        return best
    }

    /// Classifies the moves played in `game` (its move history).
    public func classify(_ game: Game) -> ECOClassification? {
        classify(AnnotatedPGNGame(game: game))
    }

    /// Classifies a sequence of position keys; the index of each key is its ply.
    public func classify<Keys: Sequence>(keys: Keys) -> ECOClassification? where Keys.Element == PositionKey {
        var best: ECOClassification?
        for (ply, key) in keys.enumerated() {
            if let maxPly, ply > maxPly { break }
            if let opening = database.opening(for: key) {
                best = ECOClassification(opening: opening, ply: ply)
            }
        }
        return best
    }

    /// Classifies UCI moves played from the standard starting position or
    /// from `fen`. Returns `nil` when a move is illegal or nothing matches.
    public func classify(uciMoves: [String], fen: String? = nil) -> ECOClassification? {
        var game: Game
        if let fen {
            guard let start = PositionKey.game(fromFEN: fen) else { return nil }
            game = start
        } else {
            game = Game()
        }
        var keys = [PositionKey(game: game)]
        for uci in uciMoves {
            guard let move = ResolvedMove(uci: uci),
                  (try? game.execute(move: move.move, considerHalfmoves: false, promotion: move.promotion ?? .queen)) != nil else {
                return nil
            }
            keys.append(PositionKey(game: game))
        }
        return classify(keys: keys)
    }

    /// Returns `game` with the `ECO`, `Opening`, `Variation` and
    /// `SubVariation` tags set from its classification.
    ///
    /// - Parameter overwrite: Replace tags the game already has. When
    ///   `false`, a game with an `ECO` tag is returned unchanged.
    public func tagging(_ game: AnnotatedPGNGame, overwrite: Bool = true) -> AnnotatedPGNGame {
        guard overwrite || game.tags[.eco] == nil, let found = classify(game) else { return game }
        var result = game
        for (tag, value) in found.tags {
            if value != nil, result.tags[tag] == nil, !result.tagOrder.contains(tag) { result.tagOrder.append(tag) }
            result.tags[tag] = value
        }
        return result
    }

    /// Returns the text of `record` with the opening tags set, keeping its
    /// movetext, comments and formatting unchanged.
    ///
    /// - Parameter overwrite: Replace tags the game already has. When
    ///   `false`, a game with an `ECO` tag is returned unchanged.
    public func taggedText(_ record: GameRecord, overwrite: Bool = true) -> String {
        guard overwrite || record.game.tags[.eco] == nil, let found = classify(record.game) else { return record.text }
        return PGNTextEditing.settingTags(found.tags, in: record.text)
    }
}
