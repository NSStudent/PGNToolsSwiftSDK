import FischerCore

/// One position of a game's main line.
public struct ReplayedPosition: Sendable {
    /// Number of half-moves played to reach the position; 0 is the initial
    /// position.
    public let ply: Int
    /// The position, including move counters.
    public let position: Position
    /// The Zobrist key of the position.
    public let key: PositionKey
    /// The move that led to the position, or `nil` for the initial position.
    public let move: AnnotatedMoveNode?

    /// The position in Forsyth-Edwards Notation.
    public var fen: String { position.fen() }

    /// The four position fields of the FEN (placement, side to move,
    /// castling and en passant), as used by EPD.
    public var epd: String {
        position.fen().split(separator: " ").prefix(4).joined(separator: " ")
    }
}

public extension AnnotatedPGNGame {
    /// The positions of the main line, starting with the initial position.
    ///
    /// - Parameter maxPly: Stop after this many half-moves; `nil` replays the
    ///   whole main line.
    func mainlinePositions(maxPly: Int? = nil) -> [ReplayedPosition] {
        var result: [ReplayedPosition] = []
        forEachMainlinePosition(maxPly: maxPly) { result.append($0) }
        return result
    }

    /// Calls `body` with each position of the main line, starting with the
    /// initial position, while `body` returns `true`.
    func walkMainline(maxPly: Int? = nil, while body: (ReplayedPosition) -> Bool) {
        var game = tree.initialGame
        guard body(ReplayedPosition(ply: 0, position: game.position, key: PositionKey(game: game), move: nil)) else {
            return
        }
        var ply = 0
        for reference in tree.mainline {
            if let maxPly, ply >= maxPly { return }
            let node = reference.node
            do {
                try game.execute(move: node.move.move, considerHalfmoves: false, promotion: node.move.promotion ?? .queen)
            } catch {
                // The tree only holds resolved legal moves; stop if one fails.
                return
            }
            ply += 1
            guard body(ReplayedPosition(ply: ply, position: game.position, key: PositionKey(game: game), move: node)) else {
                return
            }
        }
    }

    /// Calls `body` with each position of the main line, starting with the
    /// initial position.
    func forEachMainlinePosition(maxPly: Int? = nil, _ body: (ReplayedPosition) -> Void) {
        walkMainline(maxPly: maxPly) { position in
            body(position)
            return true
        }
    }

    /// The last position of the main line.
    var finalPosition: ReplayedPosition {
        var last: ReplayedPosition?
        forEachMainlinePosition { last = $0 }
        // The initial position is always visited.
        return last!
    }
}
