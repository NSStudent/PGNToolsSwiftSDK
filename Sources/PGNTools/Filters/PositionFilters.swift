import FischerCore

/// Passes games whose main line reaches some material.
public struct MaterialFilter: GameFilter {
    public enum Condition: Sendable, Equatable {
        /// The material fits a pattern, such as `KRP v KR`.
        case pattern(MaterialPattern)
        /// White's material minus Black's, in pawns (minor pieces 3, rook 5,
        /// queen 9), is in the range.
        case balance(ClosedRange<Int>)
    }

    /// Which positions are checked.
    public enum Scope: Sendable, Equatable {
        /// Some run of at least `minPlies` consecutive positions.
        case anyPosition(minPlies: Int)
        /// The final position of the main line.
        case finalPosition
    }

    public var condition: Condition
    public var scope: Scope
    /// Also pass when the condition holds with the colours exchanged.
    public var eitherColor: Bool

    public init(_ condition: Condition, scope: Scope = .anyPosition(minPlies: 1), eitherColor: Bool = false) {
        self.condition = condition
        self.scope = scope
        self.eitherColor = eitherColor
    }

    /// Whether `material` meets the condition.
    public func accepts(_ material: Material) -> Bool {
        func check(_ material: Material) -> Bool {
            switch condition {
            case .pattern(let pattern): return pattern.matches(material)
            case .balance(let range): return range.contains(material.balance)
            }
        }
        return check(material) || (eitherColor && check(material.swapped))
    }

    public func matches(_ context: GameContext) -> Bool {
        switch scope {
        case .finalPosition:
            guard let last = context.positions.last else { return false }
            return accepts(Material(board: last.position.board))
        case .anyPosition(let minPlies):
            var run = 0
            for position in context.positions {
                if accepts(Material(board: position.position.board)) {
                    run += 1
                    if run >= max(1, minPlies) { return true }
                } else {
                    run = 0
                }
            }
            return false
        }
    }
}

/// Passes games whose main line reaches a position.
///
/// A FEN or EPD with at least placement, side to move and castling rights
/// matches the position key: placement, side to move, castling rights and
/// en passant square must agree (a missing en passant field means none);
/// move counters are ignored. A placement and side to move match any
/// castling and en passant rights. A placement alone matches any position
/// with that placement. A placement may use wildcards, one
/// per square: `?` any square, `!` any piece, `A` any white piece, `a` any
/// black piece and `-` an empty square.
public struct PositionFilter: GameFilter {
    enum Target: Sendable {
        case key(PositionKey)
        case placement([SquarePattern], sideToMove: PlayerColor?)
    }

    enum SquarePattern: Sendable, Equatable {
        case exactly(Character?)
        case any
        case anyPiece
        case anyWhite
        case anyBlack
    }

    private let targets: [Target]
    /// Which positions are checked: every main line position, or only the
    /// final one.
    public var finalPositionOnly: Bool

    /// Creates a filter that passes games reaching any of the positions.
    public init(fens: [String], finalPositionOnly: Bool = false) throws(PGNToolsError) {
        var targets: [Target] = []
        for fen in fens {
            let fields = fen.split(whereSeparator: \.isWhitespace)
            if fields.count >= 3 {
                var full = fields.map(String.init)
                if full.count == 3 { full.append("-") }
                guard let key = PositionKey(fen: full.joined(separator: " ")) else {
                    throw PGNToolsError(.invalidArgument, "invalid FEN \"\(fen)\"")
                }
                targets.append(.key(key))
            } else if let placement = fields.first {
                var side: PlayerColor?
                if fields.count == 2 {
                    guard let color = PlayerColor(string: String(fields[1])) else {
                        throw PGNToolsError(.invalidArgument, "invalid side to move in \"\(fen)\"")
                    }
                    side = color
                }
                targets.append(.placement(try Self.parsePlacement(String(placement)), sideToMove: side))
            } else {
                throw PGNToolsError(.invalidArgument, "empty FEN")
            }
        }
        self.targets = targets
        self.finalPositionOnly = finalPositionOnly
    }

    public init(fen: String, finalPositionOnly: Bool = false) throws(PGNToolsError) {
        try self.init(fens: [fen], finalPositionOnly: finalPositionOnly)
    }

    public func matches(_ context: GameContext) -> Bool {
        let positions = finalPositionOnly ? Array(context.positions.suffix(1)) : context.positions
        return positions.contains { position in targets.contains { Self.matches($0, position) } }
    }

    static func matches(_ target: Target, _ position: ReplayedPosition) -> Bool {
        switch target {
        case .key(let key):
            return position.key == key
        case .placement(let squares, let side):
            if let side, position.position.playerTurn != side { return false }
            for space in position.position.board {
                // Patterns are stored from a8 to h1, as FEN lists them.
                let index = (8 - space.rank.rawValue) * 8 + space.file.index
                let piece = space.piece
                switch squares[index] {
                case .any: continue
                case .anyPiece: if piece == nil { return false }
                case .anyWhite: if piece?.color != .white { return false }
                case .anyBlack: if piece?.color != .black { return false }
                case .exactly(let letter):
                    if piece.map({ Character($0.fenName) }) != letter { return false }
                }
            }
            return true
        }
    }

    static func parsePlacement(_ text: String) throws(PGNToolsError) -> [SquarePattern] {
        let ranks = text.split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else {
            throw PGNToolsError(.invalidArgument, "placement \"\(text)\" must have 8 ranks")
        }
        var squares: [SquarePattern] = []
        for rank in ranks {
            var count = 0
            for character in rank {
                if let empty = character.wholeNumberValue, (1...8).contains(empty) {
                    squares += Array(repeating: .exactly(nil), count: empty)
                    count += empty
                    continue
                }
                switch character {
                case "?": squares.append(.any)
                case "!": squares.append(.anyPiece)
                case "A": squares.append(.anyWhite)
                case "a": squares.append(.anyBlack)
                case "-": squares.append(.exactly(nil))
                case _ where "KQRBNPkqrbnp".contains(character): squares.append(.exactly(character))
                default:
                    throw PGNToolsError(.invalidArgument, "unexpected '\(character)' in placement \"\(text)\"")
                }
                count += 1
            }
            guard count == 8 else {
                throw PGNToolsError(.invalidArgument, "rank \"\(rank)\" of placement \"\(text)\" does not have 8 squares")
            }
        }
        return squares
    }
}
