import FischerCore

/// A 64-bit Zobrist key that identifies a chess position.
///
/// The key covers the piece placement, the side to move, the castling rights
/// and the en passant square, the latter only when an en passant capture is
/// legal. Move counters are ignored, so two move orders that reach the same
/// position (a transposition) get the same key.
///
/// The random numbers come from a fixed SplitMix64 sequence, so keys are
/// stable across runs and platforms and can be stored. They are not Polyglot
/// keys.
public struct PositionKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The key of the current position of `game`.
    public init(game: Game) {
        self.init(position: game.position, enPassantIsLegal: Self.enPassantIsLegal(in: game))
    }

    /// The key of a position read from FEN or EPD text (the move counters
    /// may be omitted). Returns `nil` when the text is not a valid position.
    public init?(fen: String) {
        guard let game = PositionKey.game(fromFEN: fen) else { return nil }
        self.init(game: game)
    }

    /// The key of `position`. The en passant square counts only when
    /// `enPassantIsLegal` is `true`; ``init(game:)`` works it out.
    public init(position: Position, enPassantIsLegal: Bool) {
        let table = ZobristTable.shared
        var key: UInt64 = 0
        for space in position.board {
            guard let piece = space.piece else { continue }
            let square = Square(file: space.file, rank: space.rank)
            key ^= table.pieces[ZobristTable.pieceIndex(piece) * 64 + square.rawValue]
        }
        if position.playerTurn == .black { key ^= table.blackToMove }
        for (index, right) in CastlingRights.Right.allCases.enumerated() where position.castlingRights.contains(right) {
            key ^= table.castling[index]
        }
        if enPassantIsLegal, let target = position.enPassantTarget {
            key ^= table.enPassantFile[target.file.index]
        }
        self.rawValue = key
    }

    public var description: String {
        let hex = String(rawValue, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    public static func < (lhs: PositionKey, rhs: PositionKey) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether the side to move can capture en passant in `game`.
    public static func enPassantIsLegal(in game: Game) -> Bool {
        guard let target = game.enPassantTarget else { return false }
        let mover = game.playerTurn
        let pawn = Piece(pawn: mover)
        // The capturing pawn stands beside the target, one rank behind it.
        let rankOffset = mover == .white ? -1 : 1
        guard let fromRank = Rank(rawValue: target.rank.rawValue + rankOffset) else { return false }
        for fileOffset in [-1, 1] {
            guard let file = File(rawValue: target.file.rawValue + fileOffset) else { continue }
            let from = Square(file: file, rank: fromRank)
            guard game.board[from] == pawn else { continue }
            if game.isLegal(move: Move(start: from.location, end: target.location), considerHalfmoves: false) {
                return true
            }
        }
        return false
    }

    /// A game set up at the position described by FEN or EPD text.
    static func game(fromFEN text: String) -> Game? {
        var fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 4 else { return nil }
        // EPD: keep the four position fields and add move counters.
        let counters = fields.count >= 6 && UInt(fields[4]) != nil && UInt(fields[5]) != nil
            ? [fields[4], fields[5]] : ["0", "1"]
        fields = Array(fields.prefix(4)) + counters
        guard let position = Position(fen: fields.joined(separator: " ")) else { return nil }
        return try? Game(position: position)
    }
}

/// The random numbers used by ``PositionKey``.
struct ZobristTable: Sendable {
    /// 12 piece types × 64 squares.
    let pieces: [UInt64]
    let blackToMove: UInt64
    /// One number per castling right, in `CastlingRights.Right.allCases` order.
    let castling: [UInt64]
    let enPassantFile: [UInt64]

    static let shared = ZobristTable()

    private init() {
        // SplitMix64 with a fixed seed: the same numbers on every platform.
        var state: UInt64 = 0x5047_4E54_6F6F_6C73 // "PGNTools"
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        pieces = (0..<(12 * 64)).map { _ in next() }
        blackToMove = next()
        castling = (0..<4).map { _ in next() }
        enPassantFile = (0..<8).map { _ in next() }
    }

    static func pieceIndex(_ piece: Piece) -> Int {
        let kind: Int
        switch piece.kind {
        case .pawn: kind = 0
        case .knight: kind = 1
        case .bishop: kind = 2
        case .rook: kind = 3
        case .queen: kind = 4
        case .king: kind = 5
        }
        return kind * 2 + (piece.color == .white ? 0 : 1)
    }
}
